#!/usr/bin/env bash
# Fresh-machine setup for Fedora (including Atomic), Debian/Ubuntu or macOS.
#   ./bootstrap.sh                 # from a checkout of this repo
#   REPO_URL=https://github.com/<you>/machine-setup.git bash <(curl -fsSL <raw URL of this file>)
#   ./bootstrap.sh --profile server [--gui | --headless]   # Fedora Server
#   ./bootstrap.sh --dry-run       # show what would change, change nothing
# Extra args go to ansible-playbook, e.g.  ./bootstrap.sh --tags packages
set -euo pipefail

# Our own options; everything else is passed through to ansible-playbook.
PROFILE=desktop
GUI=""
DRY_RUN=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:?--profile needs desktop or server}"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    --server) PROFILE=server; shift ;;
    --gui) GUI=true; shift ;;
    --headless) GUI=false; shift ;;
    --dry-run|--check) DRY_RUN=1; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
case "$PROFILE" in desktop|server) ;; *) echo "--profile must be desktop or server" >&2; exit 2 ;; esac
ARGS=(-e "profile=$PROFILE" ${GUI:+-e "machine_gui=$GUI"} ${DRY_RUN:+--check --diff} ${ARGS[@]+"${ARGS[@]}"})
set -- "${ARGS[@]}"

REPO_URL="${REPO_URL:-}"   # only needed when not run from a checkout
DEST="${DEST:-$HOME/machine-setup}"

if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as your normal user, not root. You'll be asked for your password." >&2
  exit 1
fi

OS="$(uname -s)"
echo "==> Installing git and Ansible"
if [ "$OS" = "Darwin" ]; then
  if ! command -v brew >/dev/null 2>&1; then
    # Official installer; also installs the Xcode Command Line Tools.
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$b" ] && eval "$("$b" shellenv)" && break
  done
  brew install git ansible
elif [ -e /run/ostree-booted ]; then
  # Fedora Atomic (Silverblue, Sway Atomic, ...): /usr is read-only, so layer
  # Ansible with rpm-ostree and apply it live (no restart needed).
  need=()
  command -v git >/dev/null 2>&1 || need+=(git)
  command -v ansible-playbook >/dev/null 2>&1 || need+=(ansible-core)
  if [ ${#need[@]} -gt 0 ]; then
    if ! sudo rpm-ostree install -y --idempotent --apply-live "${need[@]}"; then
      echo "Couldn't install Ansible live (an update is probably waiting for a restart)." >&2
      echo "Restart (systemctl reboot) and run this again." >&2
      exit 1
    fi
  fi
elif command -v dnf >/dev/null 2>&1; then
  # python3-libdnf5 lets Ansible drive dnf5 (Fedora 41+).
  sudo dnf install -y git ansible-core python3-libdnf5
elif command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y git ansible-core python3-debian
else
  echo "Unsupported system: need macOS, dnf or apt." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/site.yml" ]; then
  DEST="$SCRIPT_DIR"   # already running from a checkout
  echo "==> Using the checkout in $DEST"
elif [ -d "$DEST/.git" ]; then
  echo "==> Updating $DEST"
  git -C "$DEST" pull --ff-only
else
  if [ -z "$REPO_URL" ]; then
    echo "Run this from a clone of the repo, or set REPO_URL=https://github.com/<you>/machine-setup.git" >&2
    exit 1
  fi
  echo "==> Cloning into $DEST"
  git clone "$REPO_URL" "$DEST"
fi
cd "$DEST"

echo "==> Installing Ansible collections"
ansible-galaxy collection install -r requirements.yml

# Read prompts from the terminal even when this script's stdin is a pipe.
# Without a terminal (CI, ssh with no tty) every question below is skipped.
have_tty() { (exec </dev/tty) 2>/dev/null; }
run() { if have_tty; then "$@" </dev/tty; else "$@"; fi; }
ask() { local reply; read -rp "$1" reply </dev/tty; printf '%s' "$reply"; }
yaml_str() { printf "'%s'" "${1//\'/\'\'}"; }

# --- First run: personal settings -------------------------------------------
# Kept in vars/local.yml (not committed), which overrides vars/apps.yml and
# vars/server.yml. Edit it to change these, or to override anything else.
LOCAL_VARS="$DEST/vars/local.yml"
if [ -z "$DRY_RUN" ] && [ ! -f "$LOCAL_VARS" ] && have_tty; then
  echo "==> First run: a few personal settings (saved in vars/local.yml)"
  # Guess the GitHub user from gh, or from the owner of this checkout's remote.
  gh_guess="$(gh api user -q .login 2>/dev/null || true)"
  if [ -z "$gh_guess" ]; then
    gh_guess="$(git remote get-url origin 2>/dev/null | sed -nE 's#.*github\.com[:/]([^/]+)/.*#\1#p')"
  fi
  if [ "$PROFILE" = server ]; then
    why="its public SSH keys will be allowed to log in"
  else
    why="used for your dotfiles repo"
  fi
  github_user="$(ask "    GitHub username ($why)${gh_guess:+ [$gh_guess]}: ")"
  github_user="${github_user:-$gh_guess}"
  git_name="" git_email=""
  if [ "$PROFILE" = desktop ] && [ -z "$(git config --global user.name 2>/dev/null || true)" ]; then
    git_name="$(ask "    Name for git commits (Enter to skip): ")"
    git_email="$(ask "    Email for git commits (Enter to skip): ")"
  fi
  {
    echo "# Personal settings for this machine (not committed)."
    echo "# Anything from vars/apps.yml or vars/server.yml can be overridden here too."
    echo "github_user: $(yaml_str "$github_user")"
    [ -n "$git_name" ] && echo "git_user_name: $(yaml_str "$git_name")"
    [ -n "$git_email" ] && echo "git_user_email: $(yaml_str "$git_email")"
    true
  } > "$LOCAL_VARS"
fi

if [ -n "$DRY_RUN" ]; then
  echo "==> Dry run: showing what would change (nothing is changed)"
  echo "    Most useful on a machine that's already set up; on a fresh one, steps"
  echo "    that depend on earlier installs can't be previewed."
else
  echo "==> Running the playbook"
fi

if [ "$OS" = "Darwin" ]; then
  # Homebrew runs as you, but some cask installers need sudo.
  # (Skipped when sudo needs no password, e.g. a CI runner.)
  if [ -z "${MACHINE_SETUP_SUDO_PASS:-}" ] && ! { sudo -k && sudo -n true 2>/dev/null; }; then
    read -rsp "Password for sudo (used by cask installers): " MACHINE_SETUP_SUDO_PASS </dev/tty
    echo
  fi
  MACHINE_SETUP_SUDO_PASS="${MACHINE_SETUP_SUDO_PASS:-}" run ansible-playbook site.yml "$@"
elif sudo -k && sudo -n true 2>/dev/null; then
  # Passwordless sudo (e.g. a test VM): don't ask for a password.
  # (sudo -k drops the cached login from above so this tests for NOPASSWD.)
  run ansible-playbook site.yml "$@"
else
  echo "    (enter your sudo password at the BECOME password prompt)"
  run ansible-playbook site.yml -K "$@"
fi

# --- After the playbook ---------------------------------------------------------
if [ -n "$DRY_RUN" ]; then
  echo
  echo "==> Dry run finished. Lines marked 'changed' are what a real run would do."
  exit 0
fi

# Sign in to GitHub and add this machine's SSH key, so cloning and pushing
# work straight away. Adding a key needs an extra gh permission, which is
# asked for only while the key is uploaded and dropped again afterwards, so
# the saved token can't change your SSH keys.
if [ "$PROFILE" = desktop ] && have_tty && command -v gh >/dev/null 2>&1; then
  if ! gh auth status >/dev/null 2>&1; then
    echo "==> Signing in to GitHub (choose SSH)"
    run gh auth login --hostname github.com --git-protocol ssh --web || true
  fi
  KEY="$HOME/.ssh/id_ed25519.pub"
  # GitHub publishes every account's public keys at github.com/<user>.keys,
  # so check there first: if the key is already on GitHub, nothing to ask.
  key_on_github() {
    local user
    user="$(gh api user --jq .login 2>/dev/null)" || return 1
    curl -fsSL "https://github.com/$user.keys" 2>/dev/null | grep -qF "$(cut -d' ' -f2 "$KEY")"
  }
  if gh auth status >/dev/null 2>&1 && [ -f "$KEY" ] && key_on_github; then
    echo "==> This machine's SSH key is already on GitHub"
  elif gh auth status >/dev/null 2>&1 && [ -f "$KEY" ]; then
    key_scope() { gh auth status 2>&1 | grep -qE "'(admin|write):public_key'"; }
    if ! key_scope; then
      echo "==> Allowing gh to add your SSH key for a moment (approve in the browser)"
      run gh auth refresh --hostname github.com -s write:public_key || true
    fi
    if ! gh ssh-key list 2>/dev/null | grep -qF "$(cut -d' ' -f2 "$KEY")"; then
      echo "==> Adding this machine's SSH key to GitHub"
      run gh ssh-key add "$KEY" --title "$(hostname -s 2>/dev/null || hostname)" \
        || echo "    Couldn't add it; run: gh auth refresh -s write:public_key && gh ssh-key add $KEY"
    fi
    if key_scope; then
      echo "==> Removing gh's SSH key permission again (approve in the browser)"
      run gh auth refresh --hostname github.com -r write:public_key -r admin:public_key || true
    fi
  fi
fi

if [ "$PROFILE" = server ]; then
  cat <<'DONE'

==> Done. What's left to do by hand:
  - Log out and back in (zsh becomes your shell).
  - Check you can still SSH in from your laptop with your key before closing
    this session: password logins are now off, so only keys work.
  - Run `claude` once to sign in to Claude Code.
  - Run `sudo tailscale up` and open the link it prints to add this machine to
    your tailnet (skip if you set tailscale_authkey).
  - Sway server: it logs in automatically at boot with the screen locked.
    Connect TigerVNC Viewer to this machine's Tailscale name, port 5900, and
    unlock with your Linux user name and password.
  - GNOME server: choose a remote desktop user name and password with
      sudo grdctl --system rdp set-credentials <user> <password>
    then connect with any RDP client to this machine's Tailscale name or
    100.x address (RDP only accepts connections over Tailscale). To avoid
    certificate warnings, turn on HTTPS certificates at
    https://login.tailscale.com/admin/dns, re-run, and connect to the full
    <name>.<tailnet>.ts.net name.
    Open JetBrains Toolbox and click Install next to IntelliJ IDEA.
DONE
else
  cat <<'DONE'

==> Done. What's left to do by hand:
  - Log out and back in (zsh becomes your shell).
  - Sign in to Chrome, Spotify and the Claude app, and to Google Drive
    (on Linux: Settings > Online Accounts > Google).
  - Open JetBrains Toolbox and click Install next to IntelliJ IDEA.
  - Run `claude` once in a terminal to sign in to Claude Code.
  - Sign in to Tailscale: `sudo tailscale up` on Linux, or open the Tailscale app.
  - NVIDIA only: if the playbook printed MOK steps, reboot and enroll the key.
DONE
  if [ -f "$HOME/.config/wayvnc/config" ]; then
    cat <<'DONE'
  - Remote desktop (Sway): while you're logged in here, connect TigerVNC
    Viewer to this machine's Tailscale name, port 5900, and log in with your
    Linux user name and password.
DONE
  fi
  if [ -e /run/ostree-booted ]; then
    cat <<'DONE'
  - Fedora Atomic: restart (systemctl reboot) to finish removing preinstalled
    apps. If the playbook stopped early to wait for a restart, run
    ./bootstrap.sh again afterwards.
DONE
  fi
fi
