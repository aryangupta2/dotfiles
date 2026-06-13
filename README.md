# dotfiles

Personal macOS dotfiles managed with [GNU Stow](https://www.gnu.org/software/stow/) and [Homebrew Bundle](https://github.com/Homebrew/homebrew-bundle).

## Quick start (fresh Mac)

```bash
xcode-select --install   # if not already installed
git clone https://github.com/aryangupta2/dotfiles.git ~/.dotfiles
cd ~/.dotfiles
chmod +x bootstrap.sh
./bootstrap.sh
```

Re-running `./bootstrap.sh` is safe: it restows packages and reconciles the Brewfile.

## Layout

```
.dotfiles/
├── bootstrap.sh      # installer + stow
├── Brewfile          # Homebrew formulae, casks, MAS apps
├── zsh/              # ~/.zshrc, ~/.zprofile, ~/.p10k.zsh, ~/.bash_profile
├── git/              # ~/.gitconfig
├── config/           # ~/.config/{alacritty,aerospace,thefuck,gh}
├── cursor/           # ~/.cursor/rules/* and ~/Library/Application Support/Cursor/User/*
└── agents/           # ~/.agents/skills/* and .skill-lock.json
```

Stow creates symlinks from `$HOME` into this repo. Oh My Zsh and its plugins are installed by `bootstrap.sh` into `~/.oh-my-zsh/custom/` (not stowed).

## Phased setup (this machine)

Apply and test one package at a time instead of everything at once:

```bash
cd ~/.dotfiles

# 1. Preview a single package (no changes)
./bootstrap.sh --dry-run --skip-brew zsh

# 2. Apply it
./bootstrap.sh --skip-brew zsh

# 3. Verify symlinks, then move to the next package
readlink ~/.zshrc   # should point into ~/.dotfiles/zsh/
```

Suggested order:

| Step | Command | Verify |
|------|---------|--------|
| 1 | `./bootstrap.sh --skip-brew zsh` | New terminal loads; prompt works |
| 2 | `./bootstrap.sh --skip-brew git` | `git config --global -l` |
| 3 | `./bootstrap.sh --skip-brew config` | Alacritty / AeroSpace configs load |
| 4 | `./bootstrap.sh --skip-brew cursor` | Cursor settings, keybindings, rules |
| 5 | `./bootstrap.sh --skip-brew agents` | `readlink ~/.agents/.skill-lock.json` |

List package names:

```bash
./bootstrap.sh --list-packages
```

Stow multiple selected packages:

```bash
./bootstrap.sh --skip-brew zsh git
```

Each run backs up only the files for the package(s) you pass. Already-symlinked paths are skipped.

## Options

```bash
./bootstrap.sh                          # full install (brew + OMZ + all packages)
./bootstrap.sh --skip-brew              # stow all packages
./bootstrap.sh --skip-brew <package>    # stow one or more packages
./bootstrap.sh --dry-run --skip-brew zsh
./bootstrap.sh --list-packages
./bootstrap.sh --help
```
