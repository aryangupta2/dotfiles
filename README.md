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
├── Brewfile          # Homebrew formulae and casks
├── zsh/              # ~/.zshrc, ~/.p10k.zsh
├── git/              # ~/.gitconfig
├── config/           # ~/.config/{alacritty,gh}
├── cursor/           # ~/.cursor/rules/* and ~/Library/Application Support/Cursor/User/*
└── agents/           # ~/.agents/skills/* and .skill-lock.json
```

Stow creates symlinks from `$HOME` into this repo. Oh My Zsh and its plugins are installed by `bootstrap.sh` into `~/.oh-my-zsh/custom/` (not stowed).

## Options

```bash
./bootstrap.sh                          # full install (brew + OMZ + all packages)
./bootstrap.sh --skip-brew              # stow all packages
./bootstrap.sh --skip-brew <package>    # stow one or more packages
./bootstrap.sh --dry-run --skip-brew zsh
./bootstrap.sh --list-packages
./bootstrap.sh --help
```
