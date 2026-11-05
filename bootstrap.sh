#!/usr/bin/env bash
# Fresh-machine setup for Fedora, Debian/Ubuntu or macOS.
#   ./bootstrap.sh                 # from a checkout of this repo
#   bash <(curl -fsSL <raw URL>)   # only works while the repo is public
# Extra args go to ansible-playbook, e.g.  ./bootstrap.sh --tags packages
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/philng/machine-setup.git}"
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
# Kept in vars/local.yml (not committed), which overrides vars/apps.yml.
LOCAL_VARS="$DEST/vars/local.yml"
if [ ! -f "$LOCAL_VARS" ] && have_tty \
   && ! grep -Eq "^git_user_name: *[\"']?[^\"' ]" vars/apps.yml \
   && [ -z "$(git config --global user.name 2>/dev/null || true)" ]; then
  echo "==> First run: a couple of personal settings (saved in vars/local.yml)"
  git_name="$(ask "    Name for git commits (Enter to skip): ")"
  git_email="$(ask "    Email for git commits (Enter to skip): ")"
  {
    echo "# Personal settings for this machine (not committed). Overrides vars/apps.yml."
    echo "git_user_name: $(yaml_str "$git_name")"
    echo "git_user_email: $(yaml_str "$git_email")"
  } > "$LOCAL_VARS"
fi

echo "==> Running the playbook"

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
# Sign in to GitHub and add this machine's SSH key, so cloning and pushing
# work straight away. gh offers to upload ~/.ssh/id_ed25519.pub during login.
if have_tty && command -v gh >/dev/null 2>&1; then
  if ! gh auth status >/dev/null 2>&1; then
    echo "==> Signing in to GitHub (choose SSH, and say yes to uploading your key)"
    run gh auth login --hostname github.com --git-protocol ssh --web || true
  elif [ -f "$HOME/.ssh/id_ed25519.pub" ] \
       && ! gh ssh-key list 2>/dev/null | grep -qF "$(cut -d' ' -f2 "$HOME/.ssh/id_ed25519.pub")"; then
    echo "==> Adding this machine's SSH key to GitHub"
    run gh ssh-key add "$HOME/.ssh/id_ed25519.pub" --title "$(hostname -s 2>/dev/null || hostname)" \
      || echo "    Couldn't add it; run: gh auth refresh -s admin:public_key && gh ssh-key add ~/.ssh/id_ed25519.pub"
  fi
fi

cat <<'DONE'

==> Done. What's left to do by hand:
  - Log out and back in (zsh becomes your shell; on Linux, docker works without sudo).
  - Sign in to Chrome, Spotify and the Claude app, and to Google Drive
    (on Linux: Settings > Online Accounts > Google).
  - Open JetBrains Toolbox and click Install next to IntelliJ IDEA.
  - Run `claude` once in a terminal to sign in to Claude Code.
  - NVIDIA only: if the playbook printed MOK steps, reboot and enroll the key.
DONE
