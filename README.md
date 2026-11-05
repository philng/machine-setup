# machine-setup

Ansible playbook that installs my apps on a fresh machine. Built for Fedora,
also works on Debian/Ubuntu and macOS. Safe to re-run: a second run changes nothing.

| | Linux (Fedora, Debian/Ubuntu) | macOS |
|---|---|---|
| CLI tools | dnf / apt | Homebrew formulae |
| GUI apps | Flatpak from Flathub | Homebrew casks |
| Extra sources | RPM Fusion, VS Code, Docker repos | Homebrew taps |

## Fresh machine

The repo is public, so a fresh machine needs nothing signed in first:

```sh
git clone https://github.com/<you>/machine-setup.git ~/machine-setup   # your fork
~/machine-setup/bootstrap.sh
```

`bootstrap.sh` installs git and Ansible (installing Homebrew first on macOS),
installs the Ansible collections, and runs the playbook. Along the way it:

- asks for your sudo password once;
- on the first run, asks for your GitHub username (and, on a desktop, your git
  name and email) and saves them in `vars/local.yml`;
- afterwards, signs you in to GitHub with `gh` and uploads the machine's new SSH
  key (or just uploads the key if you're already signed in);
- ends with the few things left to do by hand: log out and back in, sign in to
  your apps, install IntelliJ from JetBrains Toolbox, and run `claude` once.

Without a terminal (CI, `ssh` with no tty) the questions and sign-in are skipped.

To preview what a run would change on a machine that's already set up:

```sh
~/machine-setup/bootstrap.sh --dry-run
```

## Dotfiles

Your shell, editor and terminal config live in a separate `dotfiles` repo
(`https://github.com/<github_user>/dotfiles` by default). It's cloned to
`~/.dotfiles`, and every file under its `home/` folder is linked into your home
directory, e.g. `home/.zshrc` → `~/.zshrc`. A file that's already there is kept
as `<file>.pre-dotfiles`. Edit the files in `~/.dotfiles`, commit and push, and
every machine picks them up on its next run. Without a dotfiles repo, the zsh,
vim and Ghostty roles write starter configs instead.

## Update snapshots (Fedora)

On a btrfs system (Fedora's default), snapper takes a snapshot of `/` before and
after every `dnf` transaction, including the automatic updates, keeping the last
10 pairs. To undo a bad update:

```sh
sudo snapper -c root list                    # find the pre/post pair
sudo snapper -c root undochange 42..43       # put files back as they were at 42
```

## Making it yours

Nothing in the playbook is tied to one person. Fork the repo, then either edit
`vars/apps.yml` (and `vars/server.yml`) in your fork, or keep per-machine
settings in `vars/local.yml`. That file is gitignored, is created on the first
run of `bootstrap.sh`, and is loaded last, so any variable in it (`github_user`,
`git_user_name`, `flatpaks`, `casks`, `ghostty_theme`, ...) wins over the
defaults.

## Fedora Server

```sh
~/machine-setup/bootstrap.sh --profile server            # GUI auto-detected
~/machine-setup/bootstrap.sh --profile server --headless # or --gui to force it
```

The server profile ([`vars/server.yml`](vars/server.yml)) is a leaner variant
without the personal bits (no Spotify/VLC/Steam, no git name/email prompt, no GitHub
sign-in):

- **Every server:** git, gh, vim, tmux, btop, curl, fzf, bat, eza, delta,
  zsh + antidote, Claude Code, mise + uv, codecs, dotfiles, Docker and Podman,
  and full automatic updates that reboot when an update needs it.
- **GUI server** adds VS Code, JetBrains Toolbox, Ghostty, the Nerd Font,
  NoMachine, Chrome (Firefox removed), and the GNOME clean-up and dark mode.
- **Hardening** ([`roles/server`](roles/server)): your public keys from
  `https://github.com/<github_user>.keys` go into `~/.ssh/authorized_keys`, SSH root
  and password logins are turned off, so only keys work. If no key is
  authorised the run warns you: add one before you close your session, or
  you'll only be able to log in at the console. fail2ban bans
  repeated failed SSH logins, and firewalld leaves only SSH (plus NoMachine's
  port on a GUI server) open.

Before closing the session that ran it, check you can still SSH in with your key.

## Windows

Ansible can't run on Windows, so Windows has its own script,
[`windows/bootstrap.ps1`](windows/bootstrap.ps1). It installs the same apps with
winget (Windows Terminal in place of Ghostty), removes preinstalled Store apps
(News, Weather, Maps, People, Tips, Clipchamp, Solitaire and so on), turns on dark
mode, installs Claude Code and mise + uv, sets up git the same way, and creates an
SSH key. On the first run it asks for your git name and email (unless you pass
them), then signs you in to GitHub with `gh`. It's safe to re-run.

```powershell
git clone https://github.com/<you>/machine-setup.git
cd machine-setup
powershell -ExecutionPolicy Bypass -File windows\bootstrap.ps1
# optional: -GitUserName "..." -GitUserEmail "..." -WithWsl
```

`-WithWsl` also installs WSL with Fedora; run `./bootstrap.sh` inside it to get the
Linux shell setup (zsh, antidote, vim, fzf and so on). The app lists live at the top
of the script, so keep them in step with `vars/apps.yml` by hand. CI lints the
script and checks every winget ID exists on a Windows runner.

## Adding or removing apps

Edit **`vars/apps.yml`**. That's the only file you normally touch.

- `packages` – CLI tools. Use a generic name; if a distro calls it something
  else, add it to `package_name_map` (map to `""` to skip it on that OS).
- `flatpaks` – Flathub app IDs (Linux GUI apps).
- `casks` – Homebrew casks (macOS GUI apps).
- `extra_repos` – `rpmfusion`, `vscode`, `docker` (Linux). `homebrew_taps` on macOS.
- `mac_apps_remove` – paths of preinstalled Apple apps to delete on macOS (GarageBand, iMovie, iWork).
  If macOS says "Operation not permitted", give your terminal App Management access in
  System Settings → Privacy & Security, then re-run.
- `packages_remove`, `flatpaks_remove`, `casks_remove` – make sure these are gone. `packages_remove` accepts globs such as `libreoffice*` and only touches what is installed.
- `nomachine_enabled` – NoMachine server + client from nomachine.com (Linux; a cask on macOS).
  Set `nomachine_url` to pin a specific package.
- `jetbrains_toolbox_enabled` – JetBrains Toolbox in your home directory (Linux; a cask on macOS).
  Install IntelliJ IDEA from Toolbox's window on first launch.
- `mise_enabled`, `mise_global_tools` – mise for per-project language versions (official
  installer, `~/.local/bin/mise`), with uv installed through it. The starter `~/.zshrc`
  activates mise; with your own `.zshrc`, add `eval "$(mise activate zsh)"`.
- `claude_code_enabled` – Claude Code via Anthropic's native installer (`~/.local/bin/claude`,
  updates itself). The Claude desktop app is the `claude` cask on macOS.
- `ghostty_theme` – theme for a starter `~/.config/ghostty/config` (only created if missing).
- `vim_enabled` – vim-plug for vim; a starter `~/.vimrc` is created only if missing.
- `nerd_fonts` – Nerd Fonts installed into `~/.local/share/fonts` on Linux (casks on macOS).
- `zsh_enabled` – zsh as your login shell plus the antidote plugin manager. A starter
  `~/.zshrc` and `~/.zsh_plugins.txt` are created only if missing; add plugins to the latter.
- `gnome_settings` – GNOME settings as dconf `key: value` pairs (dark mode by default).
- `git_user_name`, `git_user_email` – your git identity. The git role also sets delta as the
  diff pager, `gh` for GitHub https logins, and creates `~/.ssh/id_ed25519` if missing
  (add it to GitHub with `gh ssh-key add ~/.ssh/id_ed25519.pub`).
- `auto_updates_enabled`, `auto_updates_type` – dnf-automatic (security updates by default) or
  unattended-upgrades, plus a weekly Flatpak update timer.
- `multimedia_enabled` – full ffmpeg/GStreamer codecs from RPM Fusion and GPU drivers (Intel/AMD
  video decoding, NVIDIA driver). With Secure Boot, NVIDIA needs a one-time key enrollment.
- `services_enabled`, `user_groups` – e.g. `docker` (Linux).
- `dotfiles_enabled`, `dotfiles_repo`, `dotfiles_version` – clone your dotfiles and link
  `home/` into `~` (see Dotfiles above).
- `snapshots_enabled` – snapper snapshots before/after every dnf transaction (Fedora, btrfs).
- `macos_defaults` – macOS settings: dark mode, Dock auto-hide, fast key repeat, Finder
  showing extensions and hidden files (`roles/macos/defaults/main.yml`).

Then re-run:

```sh
ansible-playbook site.yml -K                      # everything (Linux)
ansible-playbook site.yml                         # everything (macOS, no -K)
ansible-playbook site.yml -K --tags flatpak       # just one part
ansible-playbook site.yml -K --check --diff       # dry run (or ./bootstrap.sh --dry-run)
```

Tags: `repos`, `snapshots`, `packages`, `multimedia`, `flatpak`, `updates`, `gnome`, `git`, `nomachine`, `jetbrains`, `casks`, `dotfiles`, `zsh`, `ghostty`, `vim`, `fonts`, `mise`, `claude`, `macos`, `server`.

## Layout

```
site.yml              the playbook (localhost)
vars/apps.yml         your app lists (desktop profile)
vars/server.yml       server profile overrides
vars/local.yml        per-machine settings (not committed)
roles/repos           Linux repos (per-distro task files) / Homebrew taps
roles/snapshots       snapper snapshots around dnf transactions (Fedora)
roles/packages        dnf/apt via the generic package module, Homebrew on macOS
roles/flatpak         Flathub remote + apps (Linux)
roles/casks           Homebrew casks (macOS)
roles/nomachine       NoMachine from nomachine.com (Linux)
roles/jetbrains_toolbox  JetBrains Toolbox from jetbrains.com (Linux)
roles/multimedia      codecs + GPU drivers (Fedora)
roles/auto_updates    unattended updates + weekly Flatpak updates
roles/gnome           GNOME settings via dconf
roles/git_setup       ~/.gitconfig, delta, gh logins, SSH key
roles/dotfiles        your dotfiles repo, linked into ~
roles/macos           macOS settings (defaults write)
roles/server          SSH keys, key-only SSH, fail2ban, firewall (server profile)
roles/zsh             antidote + zsh login shell
roles/vim             vim-plug + starter ~/.vimrc
roles/ghostty         starter Ghostty config
roles/fonts           Nerd Fonts (Linux)
roles/mise            mise + uv
roles/claude_code     Claude Code CLI (native installer)
bootstrap.sh          first-run installer
tests/vm-test.sh      end-to-end test in a throwaway Fedora VM
tests/mac-test.sh     the macOS checks (CI runner or tests/mac-vm-test.sh)
```

On macOS, some cask installers need sudo; when run through `bootstrap.sh` the
password is passed in the `MACHINE_SETUP_SUDO_PASS` environment variable. When
running the playbook by hand on a Mac, export that variable first if a cask asks
for a password.

## Testing in a throwaway VM

```sh
sudo dnf install -y qemu-kvm qemu-img xorriso openssh-clients curl   # once
tests/vm-test.sh            # add --keep to poke around afterwards
```

It boots a fresh Fedora Cloud VM, pre-installs Firefox, Chromium and LibreOffice,
copies this working tree in (uncommitted changes included), runs `./bootstrap.sh`,
runs the playbook again expecting `changed=0`, then checks the Flatpaks, the
removals, podman and docker, and prints PASS/FAIL. The VM is deleted afterwards.
Needs a Linux x86_64 host with KVM.

### On a Mac (Apple Silicon)

```sh
brew install cirruslabs/cli/tart   # once
tests/mac-vm-test.sh               # add --keep to poke around afterwards
```

It clones a [Tart](https://tart.run) macOS VM (the first run downloads a ~25 GB
image; later clones are instant), copies this working tree in, and runs
`tests/mac-test.sh` inside it: `./bootstrap.sh`, a second run expecting
`changed=0`, then checks every cask and tool. The VM is deleted afterwards and
nothing is installed on your own Mac. Logs land in
`~/Library/Caches/machine-setup-vm/logs`. Don't run `tests/mac-test.sh` directly
on your Mac: it installs and removes apps for real.

### In CI

GitHub Actions (`.github/workflows/test.yml`) runs on every push to `main`, on
the 1st of every month (to catch upstream breakage), and by hand from the
Actions tab for any branch (optionally with a dotfiles branch to test). After
`ansible-lint` and `shellcheck` it runs, in parallel:

- the Fedora VM test for the desktop and the headless server profile, each with
  the repo owner's dotfiles;
- `tests/mac-test.sh` on a macOS runner;
- a Windows job that lints `windows/bootstrap.ps1` and checks every winget ID.

Each Fedora and Mac test does a setup run, a second run that must change
nothing, and a `--dry-run` that must report no changes. NoMachine is left out
of the Fedora and macOS jobs because nomachine.com refuses downloads from
GitHub's servers. If a Fedora job fails, its logs are attached to the run.
