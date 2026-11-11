# machine-setup

Ansible playbook that installs my apps on a fresh machine. Built for Fedora
(including Fedora Atomic, such as Sway Atomic), also works on Debian/Ubuntu and macOS. Safe to re-run: a second run changes nothing.

| | Linux (Fedora, Debian/Ubuntu) | macOS |
|---|---|---|
| CLI tools | dnf / apt | Homebrew formulae |
| GUI apps | Flatpak from Flathub | Homebrew casks |
| Extra sources | RPM Fusion, VS Code, Ghostty repos | Homebrew taps |

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
  key (or just uploads the key if you're already signed in). gh only gets
  permission to add SSH keys while it uploads the key, then gives it up again,
  so you approve two short prompts in the browser (skipped when the key is
  already on GitHub);
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

## Fedora Atomic (Sway Atomic, Silverblue, ...)

`bootstrap.sh` works the same way. Because `/usr` is read-only, the packages
are layered with `rpm-ostree` instead of installed with dnf, and applied live, so
they work straight away. What's different:

- **Removing preinstalled apps** (`packages_remove`, such as LibreOffice) uses
  `rpm-ostree override remove` and takes effect after a restart. The run ends
  with a reminder to restart.
- **If an update is already waiting for a restart**, new packages can't be
  applied live. They're queued for the next boot, and the run stops with a note
  to restart and run `./bootstrap.sh` again.
- **Updates:** the whole image updates at once, downloaded in the background
  and used from the next boot (`rpm-ostreed-automatic`). There's no
  security-only option.
- **Snapshots** are skipped: Atomic keeps the previous version, so
  `rpm-ostree rollback` undoes a bad update.
- **Codecs:** the image's ffmpeg is left alone, since the media apps are
  Flatpaks with their own codecs. Intel and NVIDIA drivers are layered from RPM
  Fusion; AMD hardware decoding is a printed command to run by hand.
- **Sway and other non-GNOME desktops** skip the GNOME parts: settings, tray
  icon extension and Google Drive in Files. Remote desktop on Sway is wayvnc
  (VNC) instead of GNOME Remote Login (RDP).
- The server profile works here too (see below).

To undo a layered package: `sudo rpm-ostree uninstall <name>`. To put back a
removed one: `sudo rpm-ostree override reset <name>`.

### The Sway Atomic image (recommended)

Instead of layering packages on every machine, [`bootc/Containerfile`](bootc/Containerfile)
builds Fedora Sway Atomic with them already inside: Tailscale, VS Code, Ghostty,
wayvnc, the CLI tools, Intel video drivers and, for servers, tmux and fail2ban.
GitHub Actions builds it every Tuesday (and when `bootc/` changes) and pushes
`ghcr.io/<owner>/machine-setup-sway:desktop` and `:server`, so a machine's normal
updates bring Fedora's fixes and your packages together, and `rpm-ostree rollback`
undoes both.

Once, after the first build: make the package public on GitHub (your profile >
Packages > machine-setup-sway > Package settings > Change visibility), so
machines can pull it without signing in.

To move a machine onto it (a fresh Sway Atomic install, or one already set up):

```sh
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/<owner>/machine-setup-sway:desktop   # or :server
systemctl reboot
~/machine-setup/bootstrap.sh            # then the per-user setup, as usual
```

**NVIDIA machines** use `:desktop-nvidia`, which has NVIDIA's driver built in
for the image's kernel (plus the kernel arguments that keep nouveau away and
`--unsupported-gpu` for Sway). With Secure Boot on, the driver must be signed by
a key the machine trusts, and the key must stay the same from build to build:

```sh
# once, on any machine with openssl:
openssl req -new -x509 -newkey rsa:2048 -nodes -days 36500 -subj "/CN=machine-setup akmods" \
  -outform DER -keyout akmods.key -out akmods.der
gh secret set AKMODS_KEY -R <owner>/machine-setup < akmods.key
base64 -i akmods.der | tr -d '\n' | gh secret set AKMODS_CERT -R <owner>/machine-setup
# once, on the NVIDIA machine after rebasing (asks for a one-time password,
# then confirm it in the blue MOK screen on the next boot):
sudo mokutil --import /etc/pki/akmods/certs/public_key.der
```

Then keep `akmods.key` somewhere safe and off the machine. Without the secrets,
the image still builds but the driver only loads with Secure Boot off.

**Signed images.** To have machines refuse any image that isn't signed by
you, create a signing key once (on a machine with `cosign` and `gh`):

```sh
cosign generate-key-pair            # asks for a password; writes cosign.key and cosign.pub
gh secret set COSIGN_PRIVATE_KEY -R <owner>/machine-setup < cosign.key
gh secret set COSIGN_PASSWORD -R <owner>/machine-setup      # the password you chose
cp cosign.pub ~/machine-setup/bootc/cosign.pub              # commit and push this one
```

Keep `cosign.key` in your password manager and delete the local copy. Builds
then sign every image, and the image itself carries the public key and a rule
requiring that signature. After a machine is on an image built with the key,
switch it to checking signatures (once):

```sh
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/<owner>/machine-setup-sway:desktop
```

Signing protects against a tampered image or registry, not against someone
who can push to your repo's `main`: keep 2FA on your GitHub account.

The playbook finds the packages already installed and layers nothing. Packages
layered earlier stay layered (`rpm-ostree status` lists them; `sudo rpm-ostree
uninstall <name>` drops ones the image now has). Keep the image's package list
in step with `vars/apps.yml` and `vars/server.yml` when you change them.

## Making it yours

Nothing in the playbook is tied to one person. Fork the repo, then either edit
`vars/apps.yml` (and `vars/server.yml`) in your fork, or keep per-machine
settings in `vars/local.yml`. That file is gitignored, is created on the first
run of `bootstrap.sh`, and is loaded last, so any variable in it (`github_user`,
`git_user_name`, `flatpaks`, `casks`, `ghostty_theme`, ...) wins over the
defaults.

## Server profile (Fedora Server or Sway Atomic)

```sh
~/machine-setup/bootstrap.sh --profile server            # GUI auto-detected
~/machine-setup/bootstrap.sh --profile server --headless # or --gui to force it
```

The server profile ([`vars/server.yml`](vars/server.yml)) is a leaner variant
without the personal bits (no Spotify/VLC/Steam, no git name/email prompt, no GitHub
sign-in):

- **Every server:** Tailscale, git, gh, vim, tmux, btop, curl, fzf, bat, eza, delta,
  zsh + antidote, Claude Code, mise + uv, codecs, dotfiles, Podman,
  and full automatic updates that reboot when an update needs it.
- **GUI server** adds VS Code, JetBrains Toolbox, Ghostty, the Nerd Font,
  GNOME Remote Login over RDP, Chrome and Firefox (Fedora's package), and the GNOME clean-up and dark mode.
- **Hardening** ([`roles/server`](roles/server)): your public keys from
  `https://github.com/<github_user>.keys` go into `~/.ssh/authorized_keys`, SSH root
  and password logins are turned off, so only keys work. If no key is
  authorised the run warns you: add one before you close your session, or
  you'll only be able to log in at the console. fail2ban bans
  repeated failed SSH logins, and firewalld leaves only SSH open (plus RDP over
  Tailscale on a GUI server).

On **Sway Atomic**, a server logs in to Sway automatically at boot and locks
the screen straight away, so VNC (wayvnc) has a session to show: connect with
TigerVNC Viewer over Tailscale and unlock with your Linux password
(`remote_desktop_autologin: false` turns this off). Downloaded updates are
applied by restarting at 4am when one is waiting, and the firewall also closes
the 1025-65535 port range that Fedora's desktop zone opens.

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
- `extra_repos` – `rpmfusion`, `vscode`, `ghostty`, `docker` (Linux; Docker's repo isn't enabled by default). `homebrew_taps` on macOS.
- `mac_apps_remove` – paths of preinstalled Apple apps to delete on macOS (GarageBand, iMovie, iWork).
  If macOS says "Operation not permitted", give your terminal App Management access in
  System Settings → Privacy & Security, then re-run.
- `packages_remove`, `flatpaks_remove`, `casks_remove` – make sure these are gone. `packages_remove` accepts globs such as `libreoffice*` and only touches what is installed.
- `tailscale_enabled` – Tailscale from its official repo with `tailscaled` running (Linux; the
  `tailscale-app` cask on macOS, winget on Windows). Sign in with `sudo tailscale up`, or set
  `tailscale_authkey` (and optionally `tailscale_up_args`, e.g. `["--ssh"]`) in `vars/local.yml`.
- `remote_desktop_enabled` – GNOME Remote Login on Fedora: RDP into the login screen with
  nobody logged in, port 3389 opened to Tailscale only
  (add your LAN, e.g. `192.168.0.0/16`, to `remote_desktop_allowed_sources` to allow it too). On for a GUI server; set the RDP user name and password once
  with `sudo grdctl --system rdp set-credentials <user> <password>`. If HTTPS certificates are on
  for your tailnet ([DNS settings](https://login.tailscale.com/admin/dns)), RDP uses a trusted
  certificate for `<name>.<tailnet>.ts.net` (renewed weekly) so clients don't warn; otherwise a
  self-signed one.
  On **Sway** it's wayvnc instead: VNC into your running session (log in on the machine
  first), port 5900, Tailscale only. Connect with TigerVNC Viewer (the `tigervnc-viewer` cask,
  winget `TigerVNC.TigerVNC`) and log in with your Linux user name and password; the
  connection is encrypted.
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
- `services_enabled`, `user_groups` – systemd services to start and groups to add you to (Linux).
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

Tags: `repos`, `snapshots`, `packages`, `multimedia`, `flatpak`, `updates`, `gnome`, `git`, `tailscale`, `remote_desktop`, `jetbrains`, `casks`, `dotfiles`, `zsh`, `ghostty`, `vim`, `fonts`, `mise`, `claude`, `macos`, `server`.

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
roles/tailscale       Tailscale from its official repo (Linux)
roles/remote_desktop  GNOME Remote Login over RDP, or wayvnc on Sway (Fedora)
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
roles/rpm_ostree      package layering and removals on Fedora Atomic
bootstrap.sh          first-run installer
bootc/Containerfile   the Sway Atomic image (built by .github/workflows/image.yml)
tests/vm-test.sh      end-to-end test in a throwaway Fedora VM
tests/atomic-vm-test.sh  the same in a throwaway Fedora Sway Atomic VM
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

It boots a fresh Fedora Cloud VM, pre-installs Firefox (which must be kept), Chromium and LibreOffice,
copies this working tree in (uncommitted changes included), runs `./bootstrap.sh`,
runs the playbook again expecting `changed=0`, then checks the Flatpaks, the
removals and podman, and prints PASS/FAIL. The VM is deleted afterwards.
Needs a Linux x86_64 host with KVM.

For Fedora Sway Atomic, `tests/atomic-vm-test.sh` (also needs `podman`) builds
a VM disk from Fedora's Sway Atomic image once with bootc-image-builder, then
runs `./bootstrap.sh`, restarts the VM, and expects a second run to change
nothing. `--image` tests another Atomic desktop, such as Silverblue.

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

GitHub Actions (`.github/workflows/test.yml`) runs on every pull request and
push to `main`, on the 1st of every month (to catch upstream breakage), and by hand from the
Actions tab for any branch (optionally with a dotfiles branch to test). After
`ansible-lint` and `shellcheck` it runs, in parallel:

- the Fedora Sway Atomic VM test for the desktop and the server profile built
  from this repo's image, plus the desktop on plain Sway Atomic (packages
  layered by the playbook), with the repo owner's dotfiles (plain Fedora's `tests/vm-test.sh` is no longer
  run in CI, but still works by hand);
- `tests/mac-test.sh` on a macOS runner;
- a Windows job that lints `windows/bootstrap.ps1` and checks every winget ID.

Each Fedora and Mac test does a setup run, a second run that must change
nothing, and a `--dry-run` that must report no changes. If a Fedora job fails,
its logs are attached to the run.

A pull request merges itself once every job passes. To hold one back, open it
as a draft or add the `no-automerge` label.
