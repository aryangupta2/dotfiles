#!/usr/bin/env bash
#
# bootstrap.sh — install Homebrew packages and symlink dotfiles on a fresh Mac.
#
# Usage:
#   ./bootstrap.sh                          # interactive menus (in a terminal)
#   ./bootstrap.sh --yes                    # full install, no prompts
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
RUN_BREW=1
RUN_OMZ=1
RUN_SHELL=1
RUN_STOW=1
INSTALL_STOW=0
BREWFILE="${DOTFILES_DIR}/Brewfile"
BREWFILE_TO_INSTALL="$BREWFILE"
BREW_TAPS=()
BREW_LINES=()
BREW_KINDS=()
BREW_NAMES=()
BREW_DESCS=()
BREW_SELECTED=()
BREW_PICK_COUNT=-1
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
  local width=0 count=$# drawn=0 rows=0 cols=80 redraw=0 desc_max

  for item in "$@"; do
    name="${item%%$'\t'*}"
    names+=("$name")
    if [[ "$item" == *$'\t'* ]]; then descs+=("${item#*$'\t'}"); else descs+=(""); fi
    state+=(1)
    if (( ${#name} > width )); then width=${#name}; fi
  done

  read -r rows cols < <(stty size 2>/dev/null </dev/tty || echo "0 80")
  if (( cols <= 0 )); then cols=80; fi
  desc_max=$((cols - width - 14))
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
      desc="${descs[i]}"
      if (( desc_max <= 1 )); then
        desc=""
      elif (( ${#desc} > desc_max )); then
        desc="${desc:0:$((desc_max - 1))}…"
      fi
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
With no arguments in a terminal, menus let you pick what to run.

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
  $(basename "$0")                              # interactive setup
  $(basename "$0") --yes                        # full fresh-Mac install, no prompts
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
  if (( BREW_PICK_COUNT == 0 )); then
    ok "No Brewfile entries selected"
    return
  fi

  log "Installing packages from Brewfile"
  run brew bundle install --file="$BREWFILE_TO_INSTALL"
  ok "Brewfile installed"
  if (( BREW_PICK_COUNT > 0 )); then
    DONE_ITEMS+=("Homebrew packages: ${BREW_PICK_COUNT} of ${#BREW_LINES[@]} Brewfile entries")
  else
    DONE_ITEMS+=("Homebrew packages from Brewfile")
  fi
}

# Splits the Brewfile into taps and installable entries; the comment line above
# an entry becomes its description.
parse_brewfile() {
  local line comment="" name

  BREW_TAPS=() BREW_LINES=() BREW_KINDS=() BREW_NAMES=() BREW_DESCS=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      '#'*)
        comment="${line#\#}"
        comment="${comment# }"
        continue
        ;;
      tap\ *)
        BREW_TAPS+=("$line")
        ;;
      brew\ *|cask\ *|vscode\ *)
        name="${line#*\"}"
        BREW_LINES+=("$line")
        BREW_KINDS+=("${line%% *}")
        BREW_NAMES+=("${name%%\"*}")
        BREW_DESCS+=("$comment")
        ;;
    esac
    comment=""
  done < "$BREWFILE"
}

pick_brewfile_entries() {
  local kind title i name
  local -a items

  parse_brewfile
  BREW_SELECTED=()
  for i in "${!BREW_LINES[@]}"; do BREW_SELECTED+=(0); done

  for kind in brew cask vscode; do
    case "$kind" in
      brew)   title="Command-line tools (brew)" ;;
      cask)   title="Apps (cask)" ;;
      vscode) title="Editor extensions (vscode)" ;;
    esac

    items=()
    for i in "${!BREW_LINES[@]}"; do
      if [[ "${BREW_KINDS[i]}" == "$kind" ]]; then
        items+=("${BREW_NAMES[i]}"$'\t'"${BREW_DESCS[i]}")
      fi
    done
    if (( ${#items[@]} == 0 )); then continue; fi

    pick_many "$title" "${items[@]}"
    for i in "${!BREW_LINES[@]}"; do
      if [[ "${BREW_KINDS[i]}" != "$kind" ]]; then continue; fi
      for name in ${PICKED[@]+"${PICKED[@]}"}; do
        if [[ "$name" == "${BREW_NAMES[i]}" ]]; then
          BREW_SELECTED[i]=1
          break
        fi
      done
    done
  done
}

# Stowing needs GNU stow, so keep it selected when it isn't installed yet.
require_stow_formula() {
  local i

  for i in "${!BREW_LINES[@]}"; do
    if [[ "${BREW_KINDS[i]}" == brew && "${BREW_NAMES[i]}" == stow ]] && (( !BREW_SELECTED[i] )); then
      warn "Keeping stow selected: it is needed for the stow step"
      BREW_SELECTED[i]=1
    fi
  done
}

write_selected_brewfile() {
  local i

  BREW_PICK_COUNT=0
  for i in "${!BREW_SELECTED[@]}"; do
    BREW_PICK_COUNT=$((BREW_PICK_COUNT + BREW_SELECTED[i]))
  done

  if (( BREW_PICK_COUNT == ${#BREW_LINES[@]} )); then
    BREWFILE_TO_INSTALL="$BREWFILE"
    return
  fi

  BREWFILE_TO_INSTALL="$(mktemp -t dotfiles-Brewfile)"
  trap 'rm -f "$BREWFILE_TO_INSTALL"' EXIT
  {
    if (( ${#BREW_TAPS[@]} )); then printf '%s\n' "${BREW_TAPS[@]}"; fi
    for i in "${!BREW_LINES[@]}"; do
      if (( BREW_SELECTED[i] )); then printf '%s\n' "${BREW_LINES[i]}"; fi
    done
  } > "$BREWFILE_TO_INSTALL"
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

# Keep in sync with the --ignore patterns passed to stow.
is_stow_ignored() {
  case "$(basename "$1")" in
    .DS_Store|extensions.txt) return 0 ;;
    *) return 1 ;;
  esac
}

backup_stow_conflicts() {
  local pkg="$1"
  local pkg_root="${DOTFILES_DIR}/${pkg}"

  [[ -d "$pkg_root" ]] || die "Missing stow package directory: ${pkg_root}"

  while IFS= read -r -d '' path; do
    [[ -f "$path" ]] || continue
    is_stow_ignored "$path" && continue
    backup_conflicting_path "${HOME_DIR}/${path#${pkg_root}/}"
  done < <(find "$pkg_root" -type f -print0)
}

stow_packages() {
  if (( INSTALL_STOW )) && ! command -v stow &>/dev/null; then
    log "Installing GNU stow"
    run brew install stow
  fi

  if ! command -v stow &>/dev/null; then
    (( DRY_RUN )) || die "GNU stow not found. Run without --skip-brew or: brew install stow"
    warn "GNU stow is not installed yet; it would be installed by the Homebrew step"
  fi

  for pkg in "${SELECTED_PACKAGES[@]}"; do
    log "Checking ${pkg} for conflicts"
    backup_stow_conflicts "$pkg"
  done

  # --no-folding: never replace a home directory with a symlink into the package
  # (e.g. ~/.config -> config/.config), which makes backup/mv mutate the repo.
  log "Stowing into $(tilde "$HOME_DIR")"
  run stow -v -R --no-folding --ignore='\.DS_Store' --ignore='extensions\.txt' \
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

  if (( DRY_RUN )); then
    return
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

has_brew() { command -v brew &>/dev/null; }

# Prints "<linked> <total>": how many of a package's files are already symlinked into $HOME.
package_link_count() {
  local pkg_root="${DOTFILES_DIR}/$1" path resolved linked=0 total=0

  while IFS= read -r -d '' path; do
    if is_stow_ignored "$path"; then continue; fi
    total=$((total + 1))
    resolved="$(realpath "${HOME_DIR}/${path#${pkg_root}/}" 2>/dev/null || true)"
    if [[ "$resolved" == "$path" ]]; then linked=$((linked + 1)); fi
  done < <(find "$pkg_root" -type f -print0)
  printf '%d %d\n' "$linked" "$total"
}

missing() { printf '  %s✗ %s%s\n' "$DIM" "$*" "$RESET"; }

show_detected_state() {
  local pkg linked total

  printf '  %sThis Mac%s\n' "$BOLD" "$RESET"
  if has_brew; then ok "Homebrew"; else missing "Homebrew not installed"; fi
  if command -v stow &>/dev/null; then ok "GNU stow"; else missing "GNU stow not installed"; fi
  if [[ -d "${HOME_DIR}/.oh-my-zsh" ]]; then ok "Oh My Zsh"; else missing "Oh My Zsh not installed"; fi
  if [[ "${SHELL:-}" == /bin/zsh ]]; then ok "Default shell is zsh"; else missing "Default shell is ${SHELL:-unknown}"; fi

  printf '\n  %sDotfiles%s\n' "$BOLD" "$RESET"
  for pkg in "${STOW_PACKAGES[@]}"; do
    read -r linked total < <(package_link_count "$pkg")
    if (( total > 0 && linked == total )); then
      ok "${pkg} linked"
    elif (( linked > 0 )); then
      warn "${pkg}: ${linked} of ${total} files linked"
    else
      missing "${pkg} not linked"
    fi
  done
}

pkg_desc() {
  case "$1" in
    zsh)    printf '%s' "~/.zshrc, ~/.p10k.zsh" ;;
    git)    printf '%s' "~/.gitconfig" ;;
    config) printf '%s' "~/.config/{alacritty,gh}" ;;
    cursor) printf '%s' "~/.cursor/rules/* and Cursor User settings" ;;
    agents) printf '%s' "~/.agents/skills/* and .skill-lock.json" ;;
  esac
}

print_plan() {
  printf '\n  %sPlan%s\n' "$BOLD" "$RESET"
  local i
  local -a names=()

  if (( RUN_BREW )); then
    log "Install Homebrew, plus ${BREW_PICK_COUNT} of ${#BREW_LINES[@]} Brewfile entries"
    if (( BREW_PICK_COUNT > 0 && BREW_PICK_COUNT < ${#BREW_LINES[@]} )); then
      for i in "${!BREW_LINES[@]}"; do
        if (( BREW_SELECTED[i] )); then names+=("${BREW_NAMES[i]}"); fi
      done
      printf '    %s%s%s\n' "$DIM" "${names[*]}" "$RESET"
    fi
  fi
  if (( RUN_OMZ )); then log "Install Oh My Zsh, powerlevel10k and plugins"; fi
  if (( RUN_SHELL )); then log "Make zsh the default shell"; fi
  if (( RUN_STOW )); then
    if (( INSTALL_STOW )); then log "Install GNU stow with Homebrew"; fi
    log "Stow dotfiles: ${SELECTED_PACKAGES[*]}"
  fi
}

interactive_setup() {
  local step pkg
  local -a items=()

  show_detected_state

  pick_many "Steps" \
    $'homebrew\tInstall Homebrew and Brewfile packages' \
    $'ohmyzsh\tOh My Zsh, powerlevel10k and plugins' \
    $'shell\tMake zsh the default shell' \
    $'stow\tSymlink dotfiles into your home folder'
  RUN_BREW=0 RUN_OMZ=0 RUN_SHELL=0 RUN_STOW=0
  for step in ${PICKED[@]+"${PICKED[@]}"}; do
    case "$step" in
      homebrew) RUN_BREW=1 ;;
      ohmyzsh)  RUN_OMZ=1 ;;
      shell)    RUN_SHELL=1 ;;
      stow)     RUN_STOW=1 ;;
    esac
  done

  if (( RUN_BREW )); then
    pick_brewfile_entries
  fi

  if (( RUN_STOW )); then
    for pkg in "${STOW_PACKAGES[@]}"; do
      items+=("${pkg}"$'\t'"$(pkg_desc "$pkg")")
    done
    pick_many "Dotfile packages" "${items[@]}"
    SELECTED_PACKAGES=(${PICKED[@]+"${PICKED[@]}"})
    if (( ${#SELECTED_PACKAGES[@]} == 0 )); then
      warn "No packages selected; skipping the stow step"
      RUN_STOW=0
    fi
  fi

  if (( RUN_STOW && !RUN_BREW )) && ! command -v stow &>/dev/null; then
    printf '\n'
    if ! has_brew; then
      warn "GNU stow needs Homebrew, which isn't installed. Select the Homebrew step to stow dotfiles."
      RUN_STOW=0
    elif ask_yn "GNU stow is not installed. Install it with Homebrew?" Y; then
      INSTALL_STOW=1
    else
      warn "Skipping the stow step"
      RUN_STOW=0
    fi
  fi

  if (( RUN_BREW )); then
    if (( RUN_STOW )) && ! command -v stow &>/dev/null; then
      require_stow_formula
    fi
    write_selected_brewfile
  fi

  if (( RUN_BREW + RUN_OMZ + RUN_SHELL + RUN_STOW == 0 )); then
    printf '\n'
    ok "Nothing selected. Bye."
    exit 0
  fi

  print_plan
  choose_one "Ready?" "Proceed" "Dry run (preview only)" "Cancel"
  case "$CHOICE" in
    2) DRY_RUN=1 ;;
    3) printf '\n'; ok "Cancelled. Nothing was changed."; exit 0 ;;
  esac
}

run_steps() {
  STEP_INDEX=0
  STEP_TOTAL=$((RUN_BREW + RUN_OMZ + RUN_SHELL + RUN_STOW))
  DONE_ITEMS=()

  if (( RUN_BREW )); then
    section "Homebrew packages"
    ensure_homebrew
    install_brewfile
  fi

  if (( RUN_OMZ )); then
    section "Oh My Zsh"
    install_omz_customizations
  fi

  if (( RUN_SHELL )); then
    section "Default shell"
    ensure_default_shell_zsh
  fi

  if (( RUN_STOW )); then
    section "Stow dotfiles"
    stow_packages
  fi

  print_summary
}

main() {
  local interactive=0

  if (( $# == 0 && !ASSUME_YES )) && [[ -t 0 && -t 1 ]]; then
    interactive=1
  fi

  # Homebrew may be installed but not yet on PATH in a fresh shell.
  if ! has_brew && [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi

  banner
  ensure_xcode_clt

  if (( interactive )); then
    printf '\n'
    interactive_setup
  elif (( SKIP_BREW )); then
    RUN_BREW=0 RUN_OMZ=0 RUN_SHELL=0
    warn "Skipping Homebrew, Brewfile, Oh My Zsh and shell steps (--skip-brew)"
  fi

  run_steps

  if (( interactive && DRY_RUN )); then
    printf '\n'
    if ask_yn "Run it for real now?" N; then
      DRY_RUN=0
      run_steps
    fi
  fi
}

main "$@"
