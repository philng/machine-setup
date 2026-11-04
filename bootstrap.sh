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

echo "==> Running the playbook"
if [ "$OS" = "Darwin" ]; then
  # Homebrew runs as you, but some cask installers need sudo.
  read -rsp "Password for sudo (used by cask installers): " MACHINE_SETUP_SUDO_PASS </dev/tty
  echo
  MACHINE_SETUP_SUDO_PASS="$MACHINE_SETUP_SUDO_PASS" ansible-playbook site.yml "$@" </dev/tty
else
  echo "    (enter your sudo password at the BECOME password prompt)"
  ansible-playbook site.yml -K "$@" </dev/tty
fi
