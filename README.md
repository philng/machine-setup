# machine-setup

Sets up my machines from scratch: Fedora Sway Atomic (desktop and server),
macOS and Windows. Safe to re-run: a second run changes nothing.

| | Fedora Sway Atomic | macOS |
|---|---|---|
| System, CLI tools, VS Code, Ghostty, Tailscale | this repo's image ([`bootc/`](bootc/)) | Homebrew formulae and casks |
| GUI apps | Flatpak from Flathub | Homebrew casks |
| Per-user setup (dotfiles, zsh, vim, mise, Claude Code, fonts, git) | Ansible | Ansible |

On Linux the heavy lifting is a container image: Fedora's Sway Atomic with the
packages and system settings built in, rebuilt every week. Machines update to
it like any Atomic system, and `rpm-ostree rollback` undoes an update.
The Ansible playbook does the rest, as your user.

## Fresh machine

**Linux:** install [Fedora Sway Atomic](https://fedoraproject.org/atomic-desktops/sway/), then:

```sh
git clone https://github.com/<you>/machine-setup.git ~/machine-setup   # your fork
~/machine-setup/bootstrap.sh                    # or --profile server
systemctl reboot
~/machine-setup/bootstrap.sh                    # again, after the restart
```

The first run switches the machine to this repo's image
(`ghcr.io/<you>/machine-setup-sway:desktop`, `:desktop-nvidia` when it finds an
NVIDIA card, or `:server`). The images are private, so that first run asks for
a GitHub token that can read them (see below). After the restart, the second
run does the per-user setup.

**macOS:** the same clone and `~/machine-setup/bootstrap.sh`, once. It installs
Homebrew, git and Ansible first.

Along the way `bootstrap.sh`:

- asks for your sudo password once;
- on the first run, asks for your GitHub username (and, on a desktop, your git
  name and email) and saves them in `vars/local.yml`;
- afterwards, signs you in to GitHub with `gh` and uploads the machine's new SSH
  key (or just uploads the key if you're already signed in). gh only gets
  permission to add SSH keys while it uploads the key, then gives it up again,
  so you approve two short prompts in the browser (skipped when the key is
  already on GitHub);
- ends with the few things left to do by hand: log out and back in, sign in to
  your apps and Tailscale, install IntelliJ from JetBrains Toolbox, and run
  `claude` once.

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

## The image

[`bootc/Containerfile`](bootc/Containerfile) builds Fedora Sway Atomic with:

- the packages in [`bootc/packages/common.txt`](bootc/packages/common.txt) (CLI
  tools, VS Code, Ghostty, Tailscale, wayvnc, Ansible, Intel video drivers) and,
  for servers, [`server.txt`](bootc/packages/server.txt) (tmux, fail2ban). These
  are the only Linux package lists: edit them to add or remove packages;
- automatic updates, downloaded in the background and used from the next boot;
- weekly Flatpak updates;
- a firewall zone that lets your tailnet (and only your tailnet) reach SSH and
  VNC;
- for servers ([`bootc/server/`](bootc/server/)): key-only SSH, fail2ban, a
  default firewall zone with only SSH open, and a restart at 4am when a
  downloaded update is waiting.

[`.github/workflows/image.yml`](.github/workflows/image.yml) builds it every
Tuesday (and when `bootc/` changes on `main`) and pushes
`ghcr.io/<owner>/machine-setup-sway:desktop`, `:desktop-nvidia` and `:server`.
The package stays private, so each machine logs in to GHCR to download it.
bootstrap.sh asks for the token the first time and saves it in
`/etc/ostree/auth.json` (readable by root only), where rpm-ostree and bootc
look for it on every update. Create it at
[github.com/settings/tokens](https://github.com/settings/tokens/new?scopes=read:packages):
a classic token with only the `read:packages` scope (fine-grained tokens can't
read packages). It can read your packages and nothing else. Without a terminal,
pass it as `MACHINE_SETUP_GHCR_TOKEN`.

If the token expires or you revoke it, updates stop until you log in again:

```
sudo podman login --authfile /etc/ostree/auth.json ghcr.io
```

To switch a machine by hand: `sudo rpm-ostree rebase
ostree-unverified-registry:ghcr.io/<owner>/machine-setup-sway:<tag>`, then restart.

**NVIDIA machines** get `:desktop-nvidia` (bootstrap.sh picks it when it sees an NVIDIA card), which has NVIDIA's driver built in
for the image's kernel (plus the kernel arguments that keep nouveau away and
`--unsupported-gpu` for Sway). With Secure Boot on, the driver must be signed by
a key the machine trusts, and the key must stay the same from build to build:

```sh
# once, on any machine with openssl:
openssl req -new -x509 -newkey rsa:2048 -nodes -days 36500 -subj "/CN=machine-setup akmods" \
  -outform DER -keyout akmods.key -out akmods.der
gh secret set AKMODS_KEY -R <owner>/machine-setup < akmods.key
base64 -i akmods.der | tr -d '\n' | gh secret set AKMODS_CERT -R <owner>/machine-setup
# once, on the NVIDIA machine once it's on the image (asks for a one-time password,
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

## Making it yours

Nothing in the playbook is tied to one person. Fork the repo, then either edit
`vars/apps.yml` (and `vars/server.yml`) in your fork, or keep per-machine
settings in `vars/local.yml`. That file is gitignored, is created on the first
run of `bootstrap.sh`, and is loaded last, so any variable in it (`github_user`,
`git_user_name`, `flatpaks`, `casks`, `ghostty_theme`, ...) wins over the
defaults.

## Server profile

```sh
~/machine-setup/bootstrap.sh --profile server            # GUI (Sway)
~/machine-setup/bootstrap.sh --profile server --headless # no desktop apps
```

The server profile ([`vars/server.yml`](vars/server.yml)) runs on the `:server`
image and leaves out the personal bits (only Chrome as a Flatpak, no git
name/email prompt, no GitHub sign-in). Your public keys from
`https://github.com/<github_user>.keys` go into `~/.ssh/authorized_keys`; password
and root SSH logins are off in the image, so only keys work. If no key is
authorised the run warns you: add one before you close your session, or you'll
only be able to log in at the console.

With a GUI, the server logs in to Sway automatically at boot and locks the screen
straight away, so VNC has a session to show: connect with TigerVNC Viewer over
Tailscale and unlock with your Linux password (`remote_desktop_autologin: false`
turns this off).

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

`-WithWsl` also installs WSL with Fedora (a plain Fedora shell: `bootstrap.sh` is
only for Sway Atomic and macOS). The app lists live at the top
of the script, so keep them in step with `vars/apps.yml` by hand. CI lints the
script and checks every winget ID exists on a Windows runner.

## Adding or removing apps

- **Linux packages:** [`bootc/packages/*.txt`](bootc/packages/) (rebuilt into the
  image; machines get them with their next update).
- Everything else: **`vars/apps.yml`**.

In `vars/apps.yml`:

- `flatpaks`, `flatpaks_remove` – Flathub app IDs (Linux GUI apps).
- `packages`, `packages_remove` – Homebrew formulae (macOS).
- `casks`, `casks_remove` – Homebrew casks (macOS GUI apps). `homebrew_taps` for extra taps.
- `mac_apps_remove` – paths of preinstalled Apple apps to delete on macOS (GarageBand, iMovie, iWork).
  If macOS says "Operation not permitted", give your terminal App Management access in
  System Settings → Privacy & Security, then re-run.
- `tailscale_authkey`, `tailscale_up_args` – join your tailnet without the browser (Linux;
  put them in `vars/local.yml`). Otherwise run `sudo tailscale up` once.
- `remote_desktop_enabled` – wayvnc: VNC into your running Sway session, port 5900,
  Tailscale only. Connect with TigerVNC Viewer (the `tigervnc-viewer` cask, winget
  `TigerVNC.TigerVNC`) and log in with your Linux user name and password; the connection
  is encrypted. On for servers.
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
- `git_user_name`, `git_user_email` – your git identity. The git role also sets delta as the
  diff pager, `gh` for GitHub https logins, and creates `~/.ssh/id_ed25519` if missing
  (add it to GitHub with `gh ssh-key add ~/.ssh/id_ed25519.pub`).
- `dotfiles_enabled`, `dotfiles_repo`, `dotfiles_version` – clone your dotfiles and link
  `home/` into `~` (see Dotfiles above).
- `macos_defaults` – macOS settings: dark mode, Dock auto-hide, fast key repeat, Finder
  showing extensions and hidden files (`roles/macos/defaults/main.yml`).

Then re-run:

```sh
ansible-playbook site.yml -K                      # everything (Linux)
ansible-playbook site.yml                         # everything (macOS, no -K)
ansible-playbook site.yml -K --tags flatpak       # just one part
ansible-playbook site.yml -K --check --diff       # dry run (or ./bootstrap.sh --dry-run)
```

Tags: `packages`, `casks`, `macos`, `flatpak`, `tailscale`, `remote_desktop`, `jetbrains`, `dotfiles`, `vim`, `ghostty`, `mise`, `claude`, `fonts`, `git`, `zsh`, `server`.

## Layout

```
bootc/Containerfile   the Sway Atomic image (built by .github/workflows/image.yml)
bootc/packages/       the Linux package lists
bootc/files/          system settings for every image; bootc/server/ for servers
bootc/nvidia.sh       NVIDIA's driver, for :desktop-nvidia
site.yml              the playbook (localhost)
vars/apps.yml         your app lists and settings (desktop profile)
vars/server.yml       server profile overrides
vars/local.yml        per-machine settings (not committed)
roles/packages        Homebrew formulae and taps (macOS)
roles/casks           Homebrew casks (macOS)
roles/macos           macOS settings (defaults write)
roles/flatpak         Flathub remote + apps (Linux)
roles/tailscale       join the tailnet with an auth key (Linux)
roles/remote_desktop  wayvnc in your Sway session (Linux)
roles/jetbrains_toolbox  JetBrains Toolbox from jetbrains.com (Linux)
roles/server          your SSH keys (server profile)
roles/git_setup       ~/.gitconfig, delta, gh logins, SSH key
roles/dotfiles        your dotfiles repo, linked into ~
roles/zsh             antidote + zsh login shell
roles/vim             vim-plug + starter ~/.vimrc
roles/ghostty         starter Ghostty config
roles/fonts           Nerd Fonts (Linux)
roles/mise            mise + uv
roles/claude_code     Claude Code CLI (native installer)
bootstrap.sh          first-run installer
windows/bootstrap.ps1 Windows setup (winget)
tests/atomic-vm-test.sh  end-to-end test in a throwaway Sway Atomic VM
tests/mac-test.sh     the macOS checks (CI runner or tests/mac-vm-test.sh)
```

On macOS, some cask installers need sudo; when run through `bootstrap.sh` the
password is passed in the `MACHINE_SETUP_SUDO_PASS` environment variable. When
running the playbook by hand on a Mac, export that variable first if a cask asks
for a password.

## Testing in a throwaway VM

```sh
sudo dnf install -y podman qemu-kvm qemu-img openssh-clients   # once (Fedora host)
tests/atomic-vm-test.sh                 # add --profile server, or --keep to poke around
```

It builds this repo's image from the working tree, turns it into a VM disk with
bootc-image-builder, boots it, copies this working tree in (uncommitted changes
included), runs `./bootstrap.sh`, restarts, runs the playbook again expecting
`changed=0`, then checks the packages, firewall, SSH, Flatpaks and so on, and
prints PASS/FAIL. The VM is deleted afterwards. Needs a Linux x86_64 host with KVM.

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

- the Sway Atomic VM test for the desktop and the server profile, with the repo
  owner's dotfiles;
- a build of the `:desktop-nvidia` image (it can't boot without an NVIDIA card);
- `tests/mac-test.sh` on a macOS runner;
- a Windows job that lints `windows/bootstrap.ps1` and checks every winget ID.

Each VM and Mac test does a setup run, a second run that must change
nothing, and a `--dry-run` that must report no changes. If a VM job fails,
its logs are attached to the run.

A pull request merges itself once every job passes. To hold one back, open it
as a draft or add the `no-automerge` label.
