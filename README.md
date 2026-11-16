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

Run with no arguments, `bootstrap.sh` is interactive:

1. Shows what's already set up on this Mac (Homebrew, stow, Oh My Zsh, default shell, which packages are linked).
2. Lets you pick steps: Homebrew + Brewfile, Oh My Zsh, default shell, stow.
3. Lets you pick individual Brewfile entries (CLI tools, apps, editor extensions). Only the chosen ones are installed, via a temporary Brewfile; the committed `Brewfile` is never edited.
4. Lets you pick which stow packages to link.
5. Shows the plan and asks: proceed, dry run, or cancel. After a dry run it offers to run for real.

Menus are checkbox lists: `↑`/`↓` (or `j`/`k`) to move, space to toggle, `a` for all, `n` for none, Enter to confirm. Long lists scroll. If there's no keyboard (input piped in), they fall back to typing numbers or ranges (`2 5-7`).

To skip the menus and install everything, run `./bootstrap.sh --yes` (or set `NONINTERACTIVE=1`). Passing any flag or package name also skips the menus.

Re-running `./bootstrap.sh` is safe: it restows packages and reconciles the Brewfile.

## Layout

```
.dotfiles/
├── bootstrap.sh      # installer + stow
├── Brewfile          # Homebrew formulae and casks
├── zsh/              # ~/.zshrc, ~/.p10k.zsh
├── git/              # ~/.gitconfig
├── config/           # ~/.config/{alacritty,gh}
├── cursor/           # ~/.cursor/* and ~/Library/Application Support/Cursor/User/*
└── agents/           # ~/.agents/skills/* and .skill-lock.json
```

Stow creates symlinks from `$HOME` into this repo. Oh My Zsh and its plugins are installed by `bootstrap.sh` into `~/.oh-my-zsh/custom/` (not stowed).

## Stowing new files

### How paths map

Each top-level folder in the repo is a **stow package**. Everything after the package name becomes the path under `$HOME`:

| Repo path | Symlink at |
|-----------|------------|
| `zsh/.zshrc` | `~/.zshrc` |
| `config/.config/gh/config.yml` | `~/.config/gh/config.yml` |
| `cursor/.cursor/rules/foo.mdc` | `~/.cursor/rules/foo.mdc` |
| `cursor/.cursor/mcp.json` | `~/.cursor/mcp.json` |
| `cursor/Library/Application Support/Cursor/User/settings.json` | `~/Library/Application Support/Cursor/User/settings.json` |

For dot-directories, include the leading dot in the package tree. For example, use `cursor/.cursor/mcp.json` (→ `~/.cursor/mcp.json`), not `cursor/mcp.json` (→ `~/mcp.json`).

### Add a file to an existing package

1. Create the file at the mirrored path inside the package directory.
2. Preview what stow will do:

   ```bash
   ./bootstrap.sh --dry-run --skip-brew <package>
   ```

3. Apply:

   ```bash
   ./bootstrap.sh --skip-brew <package>
   ```

If a real file already exists at the target path, `bootstrap.sh` moves it to `~/.dotfiles-backup/<timestamp>/` before creating the symlink.

### Add a new package

1. Create a new directory at the repo root (e.g. `vim/`) with files laid out as they should appear under `$HOME`.
2. Add the package name to `STOW_PACKAGES` in `bootstrap.sh`.
3. Update the layout section in this README.
4. Stow it:

   ```bash
   ./bootstrap.sh --skip-brew vim
   ```

### Cursor package

```
cursor/
├── .cursor/
│   ├── mcp.json              → ~/.cursor/mcp.json
│   └── rules/*.mdc           → ~/.cursor/rules/
├── extensions.txt            (not stowed — extension ID list for reference)
└── Library/Application Support/Cursor/User/
    ├── settings.json         → ~/Library/Application Support/Cursor/User/
    └── keybindings.json
```

### Files that should stay local (not stowed)

Some paths are machine-specific or too volatile to symlink. Keep them in the repo for reference, but exclude them from stow.

Currently ignored (see `--ignore` in `stow_packages()` in `bootstrap.sh`):

- `cursor/extensions/` — full extension bundles; install locally under `~/.cursor/extensions/`
- `cursor/extensions.txt` — extension ID list (would otherwise land at `~/extensions.txt`)

To exclude more paths, add a `--ignore='^dirname$'` pattern in `bootstrap.sh` and the matching name in `is_stow_ignored()` (used for conflict backups and the "linked" status screen).

### Tips

- Always dry-run before stowing a new path, especially nested ones like `Library/Application Support/...`.
- Do not stow secrets or machine-local state (SSH keys, `~/.config/gh/hosts.yml`, etc.).
- `bootstrap.sh` uses `--no-folding` so stow never replaces an entire home directory (e.g. `~/.config`) with a single symlink into the repo.

## Options

```bash
./bootstrap.sh                          # interactive menus
./bootstrap.sh --yes                    # full install (brew + OMZ + all packages), no prompts
./bootstrap.sh --skip-brew              # stow all packages
./bootstrap.sh --skip-brew <package>    # stow one or more packages
./bootstrap.sh --dry-run --skip-brew zsh
./bootstrap.sh --list-packages
./bootstrap.sh --help
```
