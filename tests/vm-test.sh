#!/usr/bin/env bash
# Test the playbook end to end in a throwaway Fedora VM.
#
#   tests/vm-test.sh                 # Fedora 43, full test
#   tests/vm-test.sh --release 42    # another Fedora release
#   tests/vm-test.sh --keep          # leave the VM running afterwards (ssh command is printed)
#   tests/vm-test.sh --quick         # skip pre-installing Firefox/Chromium/LibreOffice
#
# What it does:
#   1. Downloads the Fedora Cloud image once (cached in ~/.cache/machine-setup-vm)
#      and verifies its checksum.
#   2. Boots a fresh VM from a disposable copy-on-write disk, so every run starts clean.
#   3. Pre-installs Firefox, Chromium and LibreOffice so the removals are really tested.
#   4. Copies THIS working tree (including uncommitted changes) into the VM and runs
#      ./bootstrap.sh, then runs the playbook a second time and expects changed=0.
#   5. Checks the results (Flatpaks, removals, podman, docker) and prints PASS/FAIL.
#   6. Shuts the VM down and deletes its disk (unless --keep).
#
# Needs (Fedora host): sudo dnf install -y qemu-kvm qemu-img xorriso openssh-clients curl
# Linux x86_64 with KVM only. The VM is headless, so GUI apps are checked as
# installed, not launched.
set -euo pipefail

RELEASE=43
KEEP=0
QUICK=0
SSH_PORT="${SSH_PORT:-2222}"
MEM_MB="${MEM_MB:-4096}"
CPUS="${CPUS:-2}"
DISK_SIZE="${DISK_SIZE:-30G}"

while [ $# -gt 0 ]; do
  case "$1" in
    --release) RELEASE="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --quick) QUICK=1; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/machine-setup-vm"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/machine-setup-vm.XXXXXX")"
PIDFILE="$WORK/qemu.pid"
mkdir -p "$CACHE"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------ preflight
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || die "Needs a Linux x86_64 host."
[ -w /dev/kvm ] || die "/dev/kvm is not usable. Enable virtualization, or add yourself to the 'kvm' group."
for cmd in qemu-system-x86_64 qemu-img ssh ssh-keygen curl sha256sum; do
  command -v "$cmd" >/dev/null || die "Missing '$cmd'. On Fedora: sudo dnf install -y qemu-kvm qemu-img xorriso openssh-clients curl"
done
if command -v xorriso >/dev/null; then MKISO=(xorriso -as mkisofs)
elif command -v genisoimage >/dev/null; then MKISO=(genisoimage)
elif command -v mkisofs >/dev/null; then MKISO=(mkisofs)
else die "Missing xorriso (or genisoimage). On Fedora: sudo dnf install -y xorriso"; fi
if (exec 3<>/dev/tcp/127.0.0.1/"$SSH_PORT") 2>/dev/null; then
  die "Port $SSH_PORT is in use (another test VM?). Use SSH_PORT=2223 $0"
fi

cleanup() {
  if [ "$KEEP" = 1 ] && [ -f "$PIDFILE" ]; then
    log "VM left running (--keep)"
    echo "  ssh:  ssh -i $WORK/id_ed25519 -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null tester@127.0.0.1"
    echo "  stop: kill \$(cat $PIDFILE) && rm -rf $WORK"
    return
  fi
  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ------------------------------------------------------------ image
BASE_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/$RELEASE/Cloud/x86_64/images"
log "Finding the Fedora $RELEASE Cloud image"
CHECKSUM_FILE="$CACHE/CHECKSUM-$RELEASE"
listing="$(curl -fsSL "$BASE_URL/")" || die "Couldn't reach $BASE_URL"
IMAGE="$(grep -o 'Fedora-Cloud-Base-Generic[^"<>]*\.x86_64\.qcow2' <<<"$listing" | sort -u | tail -1)"
CSUM_NAME="$(grep -o 'Fedora-Cloud-[^"<>]*-CHECKSUM' <<<"$listing" | sort -u | tail -1)"
[ -n "$IMAGE" ] && [ -n "$CSUM_NAME" ] || die "Couldn't find the image in $BASE_URL"

if [ ! -f "$CACHE/$IMAGE" ]; then
  log "Downloading $IMAGE (about 500 MB, once)"
  curl -fL --progress-bar -o "$CACHE/$IMAGE.part" "$BASE_URL/$IMAGE"
  curl -fsSL -o "$CHECKSUM_FILE" "$BASE_URL/$CSUM_NAME"
  expected="$(grep -E "^SHA256 \($IMAGE\)" "$CHECKSUM_FILE" | awk '{print $NF}')"
  actual="$(sha256sum "$CACHE/$IMAGE.part" | awk '{print $1}')"
  [ -n "$expected" ] && [ "$expected" = "$actual" ] || { rm -f "$CACHE/$IMAGE.part"; die "Checksum mismatch for $IMAGE"; }
  mv "$CACHE/$IMAGE.part" "$CACHE/$IMAGE"
else
  echo "Using cached $IMAGE"
fi

# ------------------------------------------------------------ VM
log "Creating a disposable VM disk and cloud-init seed"
qemu-img create -q -f qcow2 -F qcow2 -b "$CACHE/$IMAGE" "$WORK/disk.qcow2" "$DISK_SIZE"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/id_ed25519"
mkdir "$WORK/seed"
cat > "$WORK/seed/meta-data" <<EOF
instance-id: machine-setup-test-$(date +%s)
local-hostname: machine-setup-test
EOF
cat > "$WORK/seed/user-data" <<EOF
#cloud-config
users:
  - name: tester
    groups: [wheel]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "$WORK/id_ed25519.pub")
EOF
"${MKISO[@]}" -quiet -o "$WORK/seed.iso" -V cidata -J -r "$WORK/seed" 2>/dev/null

log "Booting the VM (console log: $WORK/console.log)"
qemu-system-x86_64 \
  -enable-kvm -cpu host -m "$MEM_MB" -smp "$CPUS" \
  -drive "file=$WORK/disk.qcow2,if=virtio" \
  -drive "file=$WORK/seed.iso,media=cdrom" \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" -device virtio-net-pci,netdev=n0 \
  -display none -serial "file:$WORK/console.log" \
  -daemonize -pidfile "$PIDFILE"

SSH_OPTS=(-i "$WORK/id_ed25519" -p "$SSH_PORT" -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
# shellcheck disable=SC2029  # commands are meant to run in the VM
vm() { ssh "${SSH_OPTS[@]}" tester@127.0.0.1 "$@"; }

printf 'Waiting for ssh'
for _ in $(seq 1 90); do
  if vm true 2>/dev/null; then break; fi
  printf '.'; sleep 2
done
echo
vm true || die "VM didn't come up. See $WORK/console.log (run with --keep to inspect)."
vm 'sudo cloud-init status --wait >/dev/null' || true

# ------------------------------------------------------------ prepare
if [ "$QUICK" = 0 ]; then
  log "Pre-installing apps the playbook should remove (Firefox, Chromium, LibreOffice, ...)"
  vm 'sudo dnf install -y -q firefox chromium libreoffice-writer libreoffice-calc gnome-tour simple-scan'
fi

log "Copying this working tree into the VM"
tar -C "$REPO_DIR" --exclude=./.git --exclude=./collections --exclude=./.ansible -czf - . \
  | vm 'rm -rf ~/machine-setup && mkdir ~/machine-setup && tar -xzf - -C ~/machine-setup'

# ------------------------------------------------------------ run
RESULTS=()
pass() { RESULTS+=("PASS  $1"); printf '\033[32mPASS\033[0m  %s\n' "$1"; }
fail() { RESULTS+=("FAIL  $1"); printf '\033[31mFAIL\033[0m  %s\n' "$1"; }
check() { local name="$1"; shift; if vm "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

log "Run 1: ./bootstrap.sh"
if vm 'cd ~/machine-setup && ./bootstrap.sh' 2>&1 | tee "$WORK/run1.log"; then
  pass "bootstrap.sh completed"
else
  fail "bootstrap.sh completed"
fi

log "Run 2: the playbook again (should change nothing)"
vm 'cd ~/machine-setup && ansible-playbook site.yml' 2>&1 | tee "$WORK/run2.log" || true
if grep -Eq 'localhost +: ok=[0-9]+ +changed=0 +unreachable=0 +failed=0' "$WORK/run2.log"; then
  pass "second run reports changed=0 failed=0"
else
  fail "second run reports changed=0 failed=0"
fi

# A new ssh session so the new docker group membership applies.
log "Checking the result"
check "Chrome Flatpak installed"        'flatpak info com.google.Chrome'
check "Spotify Flatpak installed"       'flatpak info com.spotify.Client'
check "Firefox removed"                 '! rpm -q firefox'
check "Chromium removed"                '! rpm -q chromium'
# shellcheck disable=SC2016  # expands inside the VM
check "All LibreOffice packages removed" '[ -z "$(rpm -qa "libreoffice*")" ]'
check "GNOME Tour and Simple Scan removed" '! rpm -q gnome-tour && ! rpm -q simple-scan'
check "podman runs a container"         'podman run --rm quay.io/podman/hello'
check "docker service is running"       'systemctl is-active --quiet docker'
check "user is in the docker group"     'id -nG | grep -qw docker'
check "docker runs a container (no sudo)" 'docker run --rm hello-world'
check "VLC Flatpak installed"           'flatpak info org.videolan.VLC'
check "VS Code installed"                'rpm -q code'
check "Ghostty installed"                'rpm -q ghostty'
check "JetBrains Toolbox installed"      'test -x ~/.local/share/JetBrains/Toolbox/bin/jetbrains-toolbox'
check "zsh is the login shell"           'getent passwd tester | grep -q "/zsh$"'
check "antidote loads in zsh"            'zsh -ic "type antidote"'
check "Claude Code installed"            'test -x .local/bin/claude && .local/bin/claude --version'
check "vim and vim-plug installed"       'vim --version >/dev/null && test -f .vim/autoload/plug.vim'
check "vim plugins installed"            'test -d .vim/plugged/vim-sensible'
check "gh installed"                     'gh --version'
check "JetBrains Mono Nerd Font installed" 'fc-list | grep -qi "JetBrainsMono Nerd Font"'
check "NoMachine installed"             'rpm -q nomachine'
check "NoMachine server running"        'systemctl is-active --quiet nxserver'

# ------------------------------------------------------------ summary
log "Summary (Fedora $RELEASE)"
printf '%s\n' "${RESULTS[@]}"
if printf '%s\n' "${RESULTS[@]}" | grep -q '^FAIL'; then
  if [ "$KEEP" = 0 ]; then
    mkdir -p "$CACHE/logs"
    cp "$WORK"/run*.log "$WORK/console.log" "$CACHE/logs/" 2>/dev/null || true
    echo "Logs saved in $CACHE/logs/"
  fi
  exit 1
fi
echo "All checks passed."
