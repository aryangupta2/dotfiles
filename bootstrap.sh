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
ASSUME_YES=0
[[ -n "${NONINTERACTIVE:-}" ]] && ASSUME_YES=1
REQUESTED_PACKAGES=()
SELECTED_PACKAGES=()
DONE_ITEMS=()
PICKED=()
CHOICE=0
STEP_INDEX=0
STEP_TOTAL=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\033[1m' DIM=$'\033[2m' RED=$'\033[31m' GREEN=$'\033[32m'
  YELLOW=$'\033[33m' BLUE=$'\033[34m' CYAN=$'\033[36m' RESET=$'\033[0m'
else
  BOLD='' DIM='' RED='' GREEN='' YELLOW='' BLUE='' CYAN='' RESET=''
fi

log()  { printf '  %s›%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '  %s✗%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

section() {
  STEP_INDEX=$((STEP_INDEX + 1))
  printf '\n%s%s[%d/%d]%s %s%s%s\n' "$BOLD" "$CYAN" "$STEP_INDEX" "$STEP_TOTAL" "$RESET" "$BOLD" "$*" "$RESET"
}

tilde() {
  case "$1" in
    "$HOME_DIR"*) printf '~%s' "${1#"$HOME_DIR"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

banner() {
  printf '\n  %s%sdotfiles bootstrap%s\n' "$BOLD" "$CYAN" "$RESET"
  printf '  %s%s · macOS %s%s\n' "$DIM" "$(tilde "$DOTFILES_DIR")" "$(sw_vers -productVersion)" "$RESET"
  if (( DRY_RUN )); then
    printf '  %sdry run: nothing will be changed%s\n' "$YELLOW" "$RESET"
  fi
  printf '\n'
}

ask() { printf '  %s?%s %s ' "$CYAN" "$RESET" "$*"; }

ask_yn() {
  local question="$1" default="${2:-Y}" hint reply

  if [[ "$default" == Y ]]; then hint="Y/n"; else hint="y/N"; fi
  while true; do
    ask "${question} ${DIM}[${hint}]${RESET}"
    IFS= read -r reply || reply=""
    case "${reply:-$default}" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo]) return 1 ;;
    esac
    warn "Please answer y or n."
  done
}

# Leaves the 1-based index of the chosen option in CHOICE.
choose_one() {
  local question="$1"
  shift
  local -a options=("$@")
  local i reply

  printf '\n  %s%s%s\n' "$BOLD" "$question" "$RESET"
  for i in "${!options[@]}"; do
    printf '  %s%d)%s %s\n' "$CYAN" $((i + 1)) "$RESET" "${options[i]}"
  done
  while true; do
    ask "Choose 1-${#options[@]} ${DIM}[1]${RESET}"
    IFS= read -r reply || reply=""
    reply="${reply:-1}"
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#options[@]} )); then
      CHOICE="$reply"
      return
    fi
    warn "Enter a number between 1 and ${#options[@]}."
  done
}

# Items are "name<TAB>description" and all start selected. Leaves the selected
# names in PICKED (bash 3.2 functions cannot return arrays).
pick_many() {
  local title="$1"
  shift
  local -a names=() descs=() state=() tokens=()
  local item name i n lo hi token reply mark desc selected
  local width=0 count=$# drawn=0 rows=0 cols=80 redraw=0

  for item in "$@"; do
    name="${item%%$'\t'*}"
    names+=("$name")
    if [[ "$item" == *$'\t'* ]]; then descs+=("${item#*$'\t'}"); else descs+=(""); fi
    state+=(1)
    if (( ${#name} > width )); then width=${#name}; fi
  done

  read -r rows cols < <(stty size 2>/dev/null </dev/tty || echo "0 80")
  # Redraw in place only when colors (and so a terminal) are on and the list fits on screen.
  if [[ -n "$RESET" ]] && (( count + 6 < rows )); then
    redraw=1
  fi

  while true; do
    if (( redraw && drawn )); then
      printf '\033[%dA\033[J' "$drawn"
    fi

    selected=0
    for i in "${!state[@]}"; do
      if (( state[i] )); then selected=$((selected + 1)); fi
    done
    printf '\n  %s%s%s %s(%d of %d selected)%s\n' "$BOLD" "$title" "$RESET" "$DIM" "$selected" "$count" "$RESET"
    for i in "${!names[@]}"; do
      if (( state[i] )); then mark="${GREEN}[x]${RESET}"; else mark="${DIM}[ ]${RESET}"; fi
      desc="${descs[i]:0:$((cols - width - 14 > 0 ? cols - width - 14 : 0))}"
      printf '  %s %s%2d%s  %-*s  %s%s%s\n' "$mark" "$DIM" $((i + 1)) "$RESET" "$width" "${names[i]}" "$DIM" "$desc" "$RESET"
    done
    ask "Toggle numbers (e.g. 2 5-7), a = all, n = none, Enter = done:"
    drawn=$((count + 3))

    IFS= read -r reply || reply=""
    read -r -a tokens <<< "${reply//,/ }" || true
    (( ${#tokens[@]} )) || break

    for token in "${tokens[@]}"; do
      case "$token" in
        a|A) for i in "${!state[@]}"; do state[i]=1; done; continue ;;
        n|N) for i in "${!state[@]}"; do state[i]=0; done; continue ;;
        *-*) lo="${token%-*}" hi="${token#*-}" ;;
        *) lo="$token" hi="$token" ;;
      esac
      if [[ ! "$lo" =~ ^[0-9]+$ || ! "$hi" =~ ^[0-9]+$ ]] || (( lo < 1 || hi > count || lo > hi )); then
        warn "Ignoring '${token}' (use numbers 1-${count})"
        drawn=$((drawn + 1))
        continue
      fi
      for (( n = lo; n <= hi; n++ )); do
        state[n - 1]=$(( 1 - state[n - 1] ))
      done
    done
  done

  PICKED=()
  for i in "${!names[@]}"; do
    if (( state[i] )); then PICKED+=("${names[i]}"); fi
  done
}

run() {
  if (( DRY_RUN )); then
    printf '  %s[dry-run] %s%s\n' "$DIM" "$*" "$RESET"
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
  -y, --yes         Skip prompts and use defaults (same as NONINTERACTIVE=1)
  --list-packages   List available stow packages and exit
  -h, --help        Show this help

Packages (default: all):
  zsh     ~/.zshrc, ~/.p10k.zsh
  git     ~/.gitconfig
  config  ~/.config/{alacritty,gh}
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
      -y|--yes)    ASSUME_YES=1 ;;
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
    ok "Xcode Command Line Tools"
    return
  fi

  warn "Xcode Command Line Tools are required."
  warn "Run: xcode-select --install"
  die "Install CLT, then re-run bootstrap.sh"
}

ensure_homebrew() {
  if command -v brew &>/dev/null; then
    ok "Homebrew: $(brew --prefix)"
    return
  fi

  log "Installing Homebrew"
  if (( DRY_RUN )); then
    run /bin/bash -c '$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)'
    return
  fi
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Apple Silicon default path; harmless if already on PATH.
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi

  command -v brew &>/dev/null || die "Homebrew install finished but brew is not on PATH."
}

install_brewfile() {
  log "Installing packages from Brewfile"
  run brew bundle install --file="${DOTFILES_DIR}/Brewfile"
  ok "Brewfile installed"
  DONE_ITEMS+=("Homebrew packages from Brewfile")
}

ensure_default_shell_zsh() {
  local zsh_path="/bin/zsh"

  [[ -x "$zsh_path" ]] || return 0

  if [[ "${SHELL:-}" == "$zsh_path" ]]; then
    ok "Default shell is already ${zsh_path}"
    return
  fi

  if (( DRY_RUN )); then
    run chsh -s "$zsh_path"
    return
  fi

  log "Setting default shell to ${zsh_path} (may prompt for password)"
  if chsh -s "$zsh_path"; then
    ok "Default shell set to zsh (takes effect in new terminal sessions)"
    DONE_ITEMS+=("Default shell set to zsh")
  else
    warn "Could not change default shell. Run: chsh -s ${zsh_path}"
  fi
}

install_oh_my_zsh() {
  if [[ -d "${HOME_DIR}/.oh-my-zsh" ]]; then
    ok "Oh My Zsh"
  else
    log "Installing Oh My Zsh"
    if (( DRY_RUN )); then
      run env RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
        sh -c '$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)'
      return
    fi
    env RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
      sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  fi
}

clone_omz_plugin() {
  local name="$1"
  local repo="$2"
  local dest="${HOME_DIR}/.oh-my-zsh/custom/plugins/${name}"

  if [[ -d "${dest}/.git" ]]; then
    ok "Plugin ${name}"
  else
    log "Installing plugin ${name}"
    run git clone --depth=1 "${repo}" "${dest}"
  fi
}

clone_omz_theme() {
  local name="$1"
  local repo="$2"
  local dest="${HOME_DIR}/.oh-my-zsh/custom/themes/${name}"

  if [[ -d "${dest}/.git" ]]; then
    ok "Theme ${name}"
  else
    log "Installing theme ${name}"
    run git clone --depth=1 "${repo}" "${dest}"
  fi
}

install_omz_customizations() {
  install_oh_my_zsh
  clone_omz_theme powerlevel10k https://github.com/romkatv/powerlevel10k.git
  clone_omz_plugin zsh-autosuggestions https://github.com/zsh-users/zsh-autosuggestions.git
  clone_omz_plugin zsh-syntax-highlighting https://github.com/zsh-users/zsh-syntax-highlighting.git
  clone_omz_plugin you-should-use https://github.com/MichaelAquilina/zsh-you-should-use.git
  DONE_ITEMS+=("Oh My Zsh with powerlevel10k and plugins")
}

# Move an existing regular file/dir out of the way so stow can create a symlink.
backup_conflicting_path() {
  local target="$1"
  local resolved

  [[ -e "$target" || -L "$target" ]] || return 0

  # Skip anything that resolves inside the repo. Covers file symlinks and
  # paths reached via a tree-folded directory symlink (stow without --no-folding).
  resolved="$(realpath "$target" 2>/dev/null || true)"
  if [[ -n "$resolved" && ( "$resolved" == "${DOTFILES_DIR}" || "$resolved" == "${DOTFILES_DIR}"/* ) ]]; then
    return 0
  fi

  if [[ -L "$target" ]]; then
    warn "Replacing existing symlink: ${target} -> $(readlink "$target")"
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
    [[ "$(basename "$path")" == .DS_Store ]] && continue
    backup_conflicting_path "${HOME_DIR}/${path#${pkg_root}/}"
  done < <(find "$pkg_root" -type f -print0)
}

stow_packages() {
  command -v stow &>/dev/null || die "GNU stow not found. Run without --skip-brew or: brew install stow"

  for pkg in "${SELECTED_PACKAGES[@]}"; do
    log "Checking ${pkg} for conflicts"
    backup_stow_conflicts "$pkg"
  done

  # --no-folding: never replace a home directory with a symlink into the package
  # (e.g. ~/.config -> config/.config), which makes backup/mv mutate the repo.
  log "Stowing into $(tilde "$HOME_DIR")"
  run stow -v -R --no-folding --ignore='\.DS_Store' \
    -d "${DOTFILES_DIR}" -t "${HOME_DIR}" "${SELECTED_PACKAGES[@]}"
  ok "Stowed: ${SELECTED_PACKAGES[*]}"
  DONE_ITEMS+=("Stowed packages: ${SELECTED_PACKAGES[*]}")
}

print_summary() {
  local item

  printf '\n'
  if (( DRY_RUN )); then
    printf '  %s%sDry run complete.%s Nothing was changed.\n' "$BOLD" "$YELLOW" "$RESET"
  else
    printf '  %s%sBootstrap complete.%s Open a new terminal to load the stowed shell config.\n' "$BOLD" "$GREEN" "$RESET"
  fi

  if (( ${#DONE_ITEMS[@]} )); then
    if (( DRY_RUN )); then
      printf '\n  %sWould have done%s\n' "$BOLD" "$RESET"
    else
      printf '\n  %sDone%s\n' "$BOLD" "$RESET"
    fi
    for item in "${DONE_ITEMS[@]}"; do
      ok "$item"
    done
  fi

  printf '\n  %sBackups of replaced files%s\n' "$BOLD" "$RESET"
  if [[ -d "$BACKUP_DIR" ]]; then
    printf '  %s\n' "$(tilde "$BACKUP_DIR")"
  else
    printf '  %snone (existing dotfiles were already symlinked)%s\n' "$DIM" "$RESET"
  fi

  printf '\n  %sManual steps%s\n' "$BOLD" "$RESET"
  printf '%s' "$DIM"
  cat <<'EOF'
  1. SSH keys: generate with `ssh-keygen` and add the public key to GitHub.
     Do NOT commit private keys to this repo.
  2. GitHub CLI auth: run `gh auth login` (creates ~/.config/gh/hosts.yml locally).
  3. Optional: uv (shell sources ~/.local/bin/env only if present):
       curl -LsSf https://astral.sh/uv/install.sh | sh
  4. Install apps not managed by Homebrew:
     - Cursor — download from https://cursor.com; sign in and install extensions
     - DaVinci Resolve
     - LockDown Browser
  5. App licenses / sign-in for installed apps as needed.
  6. Powerlevel10k: run `p10k configure` only if you want to regenerate the prompt
     (a committed ~/.p10k.zsh is already stowed).

  Re-run safely:
    ./bootstrap.sh --skip-brew              # restow all packages
    ./bootstrap.sh --skip-brew zsh          # restow one package
    ./bootstrap.sh --list-packages          # show package names
EOF
  printf '%s\n' "$RESET"
}

main() {
  banner
  ensure_xcode_clt

  if (( SKIP_BREW )); then
    STEP_TOTAL=1
    warn "Skipping Homebrew, Brewfile, Oh My Zsh and shell steps (--skip-brew)"
  else
    STEP_TOTAL=4
    section "Homebrew packages"
    ensure_homebrew
    install_brewfile

    section "Oh My Zsh"
    install_omz_customizations

    section "Default shell"
    ensure_default_shell_zsh
  fi

  section "Stow dotfiles"
  stow_packages
  print_summary
}

main "$@"
