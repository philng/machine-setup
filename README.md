# machine-setup

Ansible playbook that installs my apps on a fresh machine. Built for Fedora,
also works on Debian/Ubuntu and macOS. Safe to re-run: a second run changes nothing.

| | Linux (Fedora, Debian/Ubuntu) | macOS |
|---|---|---|
| CLI tools | dnf / apt | Homebrew formulae |
| GUI apps | Flatpak from Flathub | Homebrew casks |
| Extra sources | RPM Fusion, VS Code, Docker repos | Homebrew taps |

## Fresh machine

The repo is private, so clone it first (sign in with `gh auth login`, or use an SSH key), then:

```sh
git clone https://github.com/philng/machine-setup.git ~/machine-setup
~/machine-setup/bootstrap.sh
```

`bootstrap.sh` installs git and Ansible (installing Homebrew first on macOS),
installs the Ansible collections, and runs the playbook. It asks for your sudo
password once.

## Adding or removing apps

Edit **`vars/apps.yml`**. That's the only file you normally touch.

- `packages` – CLI tools. Use a generic name; if a distro calls it something
  else, add it to `package_name_map` (map to `""` to skip it on that OS).
- `flatpaks` – Flathub app IDs (Linux GUI apps).
- `casks` – Homebrew casks (macOS GUI apps).
- `extra_repos` – `rpmfusion`, `vscode`, `docker` (Linux). `homebrew_taps` on macOS.
- `packages_remove`, `flatpaks_remove`, `casks_remove` – make sure these are gone. `packages_remove` accepts globs such as `libreoffice*` and only touches what is installed.
- `services_enabled`, `user_groups` – e.g. `docker` (Linux).
- `dotfiles_enabled` – clone `dotfiles_repo` and optionally run `dotfiles_install_cmd`.

Then re-run:

```sh
ansible-playbook site.yml -K                      # everything (Linux)
ansible-playbook site.yml                         # everything (macOS, no -K)
ansible-playbook site.yml -K --tags flatpak       # just one part
ansible-playbook site.yml -K --check --diff       # dry run
```

Tags: `repos`, `packages`, `flatpak`, `casks`, `dotfiles`.

## Layout

```
site.yml              the playbook (localhost)
vars/apps.yml         your app lists
roles/repos           Linux repos (per-distro task files) / Homebrew taps
roles/packages        dnf/apt via the generic package module, Homebrew on macOS
roles/flatpak         Flathub remote + apps (Linux)
roles/casks           Homebrew casks (macOS)
roles/dotfiles        optional dotfiles checkout
bootstrap.sh          first-run installer
```

On macOS, some cask installers need sudo; when run through `bootstrap.sh` the
password is passed in the `MACHINE_SETUP_SUDO_PASS` environment variable. When
running the playbook by hand on a Mac, export that variable first if a cask asks
for a password.
