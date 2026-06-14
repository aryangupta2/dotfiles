#!/usr/bin/env bash
#
# bootstrap.sh — install Homebrew packages and symlink dotfiles on a fresh Mac.
#
# Usage:
#   ./bootstrap.sh                          # full install (all packages)
#   ./bootstrap.sh --skip-brew              # stow all packages only
#   ./bootstrap.sh --skip-brew zsh          # stow one package (phased testing)
#   ./bootstrap.sh --skip-brew zsh git      # stow selected packages
#   ./bootstrap.sh --dry-run --skip-brew zsh
#   ./bootstrap.sh --list-packages
#
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="${HOME:?HOME is not set}"
BACKUP_DIR="${HOME_DIR}/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"
STOW_PACKAGES=(zsh git config cursor agents)

SKIP_BREW=0
DRY_RUN=0
REQUESTED_PACKAGES=()
SELECTED_PACKAGES=()

log()  { printf '==> %s\n' "$*"; }
warn() { printf '!!> %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

run() {
  if (( DRY_RUN )); then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [package ...]

Install Homebrew packages and symlink dotfiles with GNU Stow.

Options:
  --skip-brew       Skip Homebrew, Brewfile, and Oh My Zsh setup
  --dry-run         Print actions without changing anything
  --list-packages   List available stow packages and exit
  -h, --help        Show this help

Packages (default: all):
  zsh     ~/.zshrc
  git     ~/.gitconfig
  config  ~/.config/{alacritty,aerospace,thefuck,gh}
  cursor  ~/.cursor/rules/* and Cursor User settings
  agents  ~/.agents/skills/* and .skill-lock.json

Examples:
  $(basename "$0") --skip-brew zsh              # phased: shell only
  $(basename "$0") --dry-run --skip-brew cursor # preview cursor symlinks
  $(basename "$0")                              # full fresh-Mac install
EOF
  exit "${1:-0}"
}

list_packages() {
  printf 'Available stow packages:\n'
  for pkg in "${STOW_PACKAGES[@]}"; do
    printf '  %s\n' "$pkg"
  done
}

parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --skip-brew) SKIP_BREW=1 ;;
      --dry-run)   DRY_RUN=1 ;;
      --list-packages) list_packages; exit 0 ;;
      -h|--help)   usage 0 ;;
      -*) die "Unknown option: $arg (try --help)" ;;
      *) REQUESTED_PACKAGES+=("$arg") ;;
    esac
  done
}

resolve_packages() {
  local pkg

  if ((${#REQUESTED_PACKAGES[@]} == 0)); then
    SELECTED_PACKAGES=("${STOW_PACKAGES[@]}")
    return
  fi

  SELECTED_PACKAGES=()
  for pkg in "${REQUESTED_PACKAGES[@]}"; do
    local found=0
    for known in "${STOW_PACKAGES[@]}"; do
      if [[ "$pkg" == "$known" ]]; then
        found=1
        SELECTED_PACKAGES+=("$pkg")
        break
      fi
    done
    (( found )) || die "Unknown package: ${pkg} (try --list-packages)"
  done
}

parse_args "$@"
resolve_packages

[[ "$(uname -s)" == "Darwin" ]] || die "This script is intended for macOS only."

ensure_xcode_clt() {
  if xcode-select -p &>/dev/null; then
    log "Xcode Command Line Tools: already installed"
    return
  fi

  warn "Xcode Command Line Tools are required."
  warn "Run: xcode-select --install"
  die "Install CLT, then re-run bootstrap.sh"
}

ensure_homebrew() {
  if command -v brew &>/dev/null; then
    log "Homebrew: $(brew --prefix)"
    return
  fi

  log "Installing Homebrew..."
  run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Apple Silicon default path; harmless if already on PATH.
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi

  command -v brew &>/dev/null || die "Homebrew install finished but brew is not on PATH."
}

install_brewfile() {
  log "Installing packages from Brewfile..."
  run brew bundle install --file="${DOTFILES_DIR}/Brewfile"
}

install_oh_my_zsh() {
  if [[ -d "${HOME_DIR}/.oh-my-zsh" ]]; then
    log "Oh My Zsh: already installed"
  else
    log "Installing Oh My Zsh..."
    run env RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
      sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  fi
}

clone_omz_plugin() {
  local name="$1"
  local repo="$2"
  local dest="${HOME_DIR}/.oh-my-zsh/custom/plugins/${name}"

  if [[ -d "${dest}/.git" ]]; then
    log "OMZ plugin ${name}: already installed"
  else
    log "Installing OMZ plugin ${name}..."
    run git clone --depth=1 "${repo}" "${dest}"
  fi
}

clone_omz_theme() {
  local name="$1"
  local repo="$2"
  local dest="${HOME_DIR}/.oh-my-zsh/custom/themes/${name}"

  if [[ -d "${dest}/.git" ]]; then
    log "OMZ theme ${name}: already installed"
  else
    log "Installing OMZ theme ${name}..."
    run git clone --depth=1 "${repo}" "${dest}"
  fi
}

install_omz_customizations() {
  install_oh_my_zsh
  clone_omz_theme powerlevel10k https://github.com/romkatv/powerlevel10k.git
  clone_omz_plugin zsh-autosuggestions https://github.com/zsh-users/zsh-autosuggestions.git
  clone_omz_plugin zsh-syntax-highlighting https://github.com/zsh-users/zsh-syntax-highlighting.git
}

# Move an existing regular file/dir out of the way so stow can create a symlink.
backup_conflicting_path() {
  local target="$1"

  [[ -e "$target" || -L "$target" ]] || return 0

  if [[ -L "$target" ]]; then
    local link_dest
    link_dest="$(readlink "$target")"
    if [[ "$link_dest" == "${DOTFILES_DIR}"/* ]]; then
      return 0
    fi
    warn "Replacing existing symlink: ${target} -> ${link_dest}"
  else
    warn "Backing up existing path: ${target}"
  fi

  run mkdir -p "${BACKUP_DIR}/$(dirname "${target#${HOME_DIR}/}")"
  run mv "$target" "${BACKUP_DIR}/${target#${HOME_DIR}/}"
}

backup_stow_conflicts() {
  local pkg="$1"
  local pkg_root="${DOTFILES_DIR}/${pkg}"

  [[ -d "$pkg_root" ]] || die "Missing stow package directory: ${pkg_root}"

  while IFS= read -r -d '' path; do
    [[ -f "$path" ]] || continue
    backup_conflicting_path "${HOME_DIR}/${path#${pkg_root}/}"
  done < <(find "$pkg_root" -type f -print0)
}

stow_packages() {
  command -v stow &>/dev/null || die "GNU stow not found. Run without --skip-brew or: brew install stow"

  log "Stow packages: ${SELECTED_PACKAGES[*]}"

  for pkg in "${SELECTED_PACKAGES[@]}"; do
    log "Preparing stow package: ${pkg}"
    backup_stow_conflicts "$pkg"
  done

  log "Stowing into ${HOME_DIR}..."
  run stow -v -R -d "${DOTFILES_DIR}" -t "${HOME_DIR}" "${SELECTED_PACKAGES[@]}"
}

print_manual_steps() {
  cat <<'EOF'

Bootstrap complete.

Manual steps that cannot be fully automated:
  1. SSH keys: generate with `ssh-keygen` and add the public key to GitHub.
     Do NOT commit private keys to this repo.
  2. GitHub CLI auth: run `gh auth login` (creates ~/.config/gh/hosts.yml locally).
  3. Bun (optional): curl -fsSL https://bun.sh/install | bash
  4. Install apps not managed by Homebrew:
     - Cursor — download from https://cursor.com; sign in and install extensions
     - DaVinci Resolve
     - LockDown Browser
  5. App licenses and MAS apps: install/sign in to Outlook, The Camelizer, etc.
  6. Secrets/passwords: use 1Password or another secret manager as needed.
  7. AeroSpace: grant Accessibility permissions in System Settings if prompted.
  8. Powerlevel10k: run `p10k configure` if you want to regenerate the prompt.

Re-run safely:
  ./bootstrap.sh --skip-brew              # restow all packages
  ./bootstrap.sh --skip-brew zsh          # restow one package
  ./bootstrap.sh --list-packages          # show package names

Backups of replaced files (if any):
EOF
  if [[ -d "$BACKUP_DIR" ]]; then
    printf '  %s\n' "$BACKUP_DIR"
  else
    printf '  (none — existing dotfiles were already symlinked)\n'
  fi
}

main() {
  log "Dotfiles directory: ${DOTFILES_DIR}"
  log "Home directory:     ${HOME_DIR}"

  ensure_xcode_clt

  if (( SKIP_BREW )); then
    warn "Skipping Homebrew/Brewfile/OMZ install steps (--skip-brew)"
  else
    ensure_homebrew
    install_brewfile
    install_omz_customizations
  fi

  stow_packages
  print_manual_steps
}

main "$@"
