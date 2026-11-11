#!/usr/bin/env bash
# shellcheck disable=SC2016  # check commands are single-quoted on purpose: they expand inside the VM
# Test the playbook end to end in a throwaway Fedora Sway Atomic VM.
#
#   tests/atomic-vm-test.sh                 # Sway Atomic 43
#   tests/atomic-vm-test.sh --release 42    # another Fedora release
#   tests/atomic-vm-test.sh --image <base image>   # another base than Sway Atomic
#   tests/atomic-vm-test.sh --keep          # leave the VM running afterwards
#   tests/atomic-vm-test.sh --profile server  # the server profile
#
# What it does:
#   1. Builds this repo's image (bootc/Containerfile) for the profile, then a VM
#      disk from it with bootc-image-builder. The only test additions: a
#      "tester" user with an SSH key and passwordless sudo, and sshd on.
#   2. Boots a fresh VM from a disposable copy-on-write disk.
#   3. Copies THIS working tree into the VM and runs ./bootstrap.sh, restarts
#      the VM, runs the playbook again and expects changed=0, then a --dry-run.
#   4. Checks the results and prints PASS/FAIL.
#
# Needs: Linux x86_64 with KVM, podman (run with sudo), qemu, ssh.
#   Fedora: sudo dnf install -y podman qemu-kvm qemu-img openssh-clients
set -euo pipefail

RELEASE=43
IMAGE=""
KEEP=0
PROFILE=desktop
SSH_PORT="${SSH_PORT:-2224}"
MEM_MB="${MEM_MB:-4096}"
CPUS="${CPUS:-2}"
BIB="${BIB:-quay.io/centos-bootc/bootc-image-builder:latest}"

while [ $# -gt 0 ]; do
  case "$1" in
    --release) RELEASE="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --github-user) GITHUB_USER="$2"; shift 2 ;;
    --dotfiles-version) DOTFILES_VERSION="$2"; shift 2 ;;
    -h|--help) sed -n '3,21p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
IMAGE="${IMAGE:-quay.io/fedora-ostree-desktops/sway-atomic:$RELEASE}"
UPSTREAM="$IMAGE"
case "$PROFILE" in desktop|server) ;; *) echo "--profile must be desktop or server" >&2; exit 2 ;; esac

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/machine-setup-vm"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/machine-setup-atomic.XXXXXX")"
PIDFILE="$WORK/qemu.pid"
mkdir -p "$CACHE"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------ preflight
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || die "Needs a Linux x86_64 host."
[ -w /dev/kvm ] || die "/dev/kvm is not usable. Enable virtualization, or add yourself to the 'kvm' group."
for cmd in podman qemu-system-x86_64 qemu-img ssh ssh-keygen; do
  command -v "$cmd" >/dev/null || die "Missing '$cmd'."
done
if (exec 3<>/dev/tcp/127.0.0.1/"$SSH_PORT") 2>/dev/null; then
  die "Port $SSH_PORT is in use (another test VM?). Use SSH_PORT=2225 $0"
fi

cleanup() {
  if [ "$KEEP" = 1 ] && [ -f "$PIDFILE" ]; then
    log "VM left running (--keep)"
    echo "  ssh:  ssh -i $CACHE/atomic_id_ed25519 -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null tester@127.0.0.1"
    echo "  stop: kill \$(cat $PIDFILE) && rm -rf $WORK"
    return
  fi
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ------------------------------------------------------------ disk image
KEY="$CACHE/atomic_id_ed25519"
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -f "$KEY"
log "Building this repo's bootc image ($PROFILE) from $UPSTREAM"
IMAGE="localhost/machine-setup-sway:$PROFILE"
sudo podman build --pull=newer -f "$REPO_DIR/bootc/Containerfile" \
  --build-arg BASE="$UPSTREAM" --build-arg PROFILE="$PROFILE" \
  --build-arg IMAGE_REPO=ghcr.io/machine-setup-test/machine-setup-sway \
  -t "$IMAGE" "$REPO_DIR"
BASE="$WORK/image-base.qcow2"   # built fresh from this working tree every time

{
  log "Building a VM disk from $IMAGE (about 10 minutes)"
  build="$WORK/build"
  mkdir -p "$build/output"
  cat > "$build/Containerfile" <<EOF
FROM $IMAGE
RUN echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/90-test-nopasswd \\
 && chmod 440 /etc/sudoers.d/90-test-nopasswd \\
 && systemctl enable sshd
EOF
  cat > "$build/config.toml" <<EOF
[[customizations.user]]
name = "tester"
key = "$(cat "$KEY.pub")"
groups = ["wheel"]

[[customizations.filesystem]]
mountpoint = "/"
minsize = "40 GiB"
EOF
  sudo podman build -q -t localhost/machine-setup-sway-test "$build"
  sudo podman run --rm --privileged --pull=newer \
    --security-opt label=type:unconfined_t \
    -v "$build/config.toml:/config.toml:ro" \
    -v "$build/output:/output" \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    "$BIB" --type qcow2 --rootfs btrfs localhost/machine-setup-sway-test
  sudo mv "$build/output/qcow2/disk.qcow2" "$BASE.part"
  sudo chown "$(id -u):$(id -g)" "$BASE.part"
  mv "$BASE.part" "$BASE"
  # The container images aren't needed any more; free the disk space.
  sudo podman rmi -f localhost/machine-setup-sway-test "$IMAGE" "$UPSTREAM" "$BIB" >/dev/null 2>&1 || true
}

# ------------------------------------------------------------ VM
qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$WORK/disk.qcow2"

SSH_OPTS=(-i "$KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
# shellcheck disable=SC2029  # commands are meant to run in the VM
vm() { ssh "${SSH_OPTS[@]}" tester@127.0.0.1 "$@"; }

boot() {
  log "Booting the VM (console log: $WORK/console.log)"
  qemu-system-x86_64 \
    -enable-kvm -cpu host -m "$MEM_MB" -smp "$CPUS" \
    -drive "file=$WORK/disk.qcow2,if=virtio" \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" -device virtio-net-pci,netdev=n0 \
    -display none -serial "file:$WORK/console.log" \
    -daemonize -pidfile "$PIDFILE"
  wait_for_ssh
}
wait_for_ssh() {
  printf 'Waiting for ssh'
  for _ in $(seq 1 90); do
    if vm true 2>/dev/null; then break; fi
    printf '.'; sleep 2
  done
  echo
  vm true || die "VM didn't come up. See $WORK/console.log (run with --keep to inspect)."
}
reboot_vm() {
  log "Restarting the VM"
  local before
  before="$(vm cat /proc/sys/kernel/random/boot_id)"
  vm 'sudo systemctl reboot' || true
  for _ in $(seq 1 90); do
    sleep 2
    now="$(vm cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
    [ -n "$now" ] && [ "$now" != "$before" ] && return 0
  done
  die "VM didn't come back after restarting. See $WORK/console.log."
}

boot
vm 'rpm-ostree status'

log "Copying this working tree into the VM"
tar -C "$REPO_DIR" --exclude=./.git --exclude=./collections --exclude=./.ansible -czf - . \
  | vm 'rm -rf ~/machine-setup && mkdir ~/machine-setup && tar -xzf - -C ~/machine-setup'

# ------------------------------------------------------------ run
RESULTS=()
pass() { RESULTS+=("PASS  $1"); printf '\033[32mPASS\033[0m  %s\n' "$1"; }
fail() { RESULTS+=("FAIL  $1"); printf '\033[31mFAIL\033[0m  %s\n' "$1"; }
check() { local name="$1"; shift; if vm "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
clean_run() { grep -Eq 'localhost +: ok=[0-9]+ +changed=0 +unreachable=0 +failed=0' "$1"; }

if [ "$PROFILE" = server ]; then
  PB_ARGS="-e profile=server"
  BOOT_ARGS="--profile server"
else
  # Remote desktop is off by default on a desktop; turn it on so wayvnc is tested.
  PB_ARGS="-e remote_desktop_enabled=true"
  BOOT_ARGS="$PB_ARGS"
fi
if [ -n "${GITHUB_USER:-}" ]; then
  PB_ARGS="$PB_ARGS -e github_user=$GITHUB_USER -e dotfiles_version=${DOTFILES_VERSION:-HEAD}"
  BOOT_ARGS="$BOOT_ARGS -e github_user=$GITHUB_USER -e dotfiles_version=${DOTFILES_VERSION:-HEAD}"
fi

log "Run 1: ./bootstrap.sh $BOOT_ARGS"
if vm "cd ~/machine-setup && ./bootstrap.sh $BOOT_ARGS" 2>&1 | tee "$WORK/run1.log"; then
  pass "bootstrap.sh completed"
else
  fail "bootstrap.sh completed"
fi
if grep -q 'Switching this machine' "$WORK/run1.log"; then
  fail "bootstrap.sh saw the machine is already on the image"
fi

reboot_vm
vm 'rpm-ostree status'

log "Run 2: the playbook again after the restart (should change nothing)"
vm "cd ~/machine-setup && ansible-playbook site.yml $PB_ARGS" 2>&1 | tee "$WORK/run2.log" || true
if clean_run "$WORK/run2.log"; then pass "second run reports changed=0 failed=0"
else fail "second run reports changed=0 failed=0"; fi

log "Run 3: bootstrap.sh --dry-run (should report no changes)"
vm "cd ~/machine-setup && ./bootstrap.sh $BOOT_ARGS --dry-run" 2>&1 | tee "$WORK/run3.log" || true
if clean_run "$WORK/run3.log"; then pass "dry run reports changed=0 failed=0"
else fail "dry run reports changed=0 failed=0"; fi

log "Checking the result ($PROFILE profile)"
check "nothing waiting for a restart"     'rpm-ostree status --json | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin)[\"deployments\"][0][\"booted\"] else 1)"'
check "packages come with the image (nothing layered)" 'rpm -q gh code ghostty tailscale wayvnc ansible-core && ! rpm-ostree status --json | python3 -c "import json,sys; d=json.load(sys.stdin)[\"deployments\"][0]; sys.exit(1 if d.get(\"requested-packages\") else 0)"'
check "Firefox kept"                     'rpm -q firefox'
check "wayvnc installed and configured"  'rpm -q wayvnc && grep -qx enable_pam=true .config/wayvnc/config && test -s .config/wayvnc/rsa_key.pem && test -f /etc/pam.d/wayvnc'
check "wayvnc starts with Sway"          'test -L .config/systemd/user/graphical-session.target.wants/wayvnc.service'
check "VNC and SSH open to Tailscale only" 'sudo firewall-cmd --zone=tailscale --list-sources | grep -q 100.64.0.0/10 && sudo firewall-cmd --zone=tailscale --list-ports | grep -qw 5900/tcp && ! sudo firewall-cmd --list-ports | grep -qw 5900/tcp'
check "podman runs a container"          'podman run --rm quay.io/podman/hello'
check "Docker not installed"             '! rpm -q docker-ce'
check "Tailscale running"                'systemctl is-active --quiet tailscaled'
check "zsh is the login shell"           'getent passwd tester | grep -q "/zsh$"'
check "antidote loads in zsh"            'zsh -ic "type antidote"'
check "Claude Code installed"            'test -x .local/bin/claude && .local/bin/claude --version'
check "vim plugins installed"            'test -d .vim/plugged/vim-sensible'
check "mise and uv installed"            '.local/bin/mise --version && .local/bin/mise exec -- uv --version'
check "fzf, bat, btop and eza installed"  'command -v fzf && command -v bat && command -v btop && command -v eza'
check "git uses delta"                   '[ "$(git config --global core.pager)" = delta ] && command -v delta'
check "Chrome Flatpak installed"         'flatpak info com.google.Chrome'
check "JetBrains Mono Nerd Font installed" 'fc-list | grep -qi "JetBrainsMono Nerd Font"'
check "automatic image updates staged"   'grep -qx "AutomaticUpdatePolicy=stage" /etc/rpm-ostreed.conf && systemctl is-enabled --quiet rpm-ostreed-automatic.timer'
check "Flatpak update timer enabled"     'systemctl is-enabled --quiet flatpak-update.timer'
if [ "$PROFILE" = server ]; then
  check "tmux and fail2ban layered"       'rpm -q tmux fail2ban'
  check "sshd enabled at boot"            'systemctl is-enabled --quiet sshd'
  check "SSH: root login off"             'sudo sshd -T | grep -qx "permitrootlogin no"'
  check "SSH: password login off"         'sudo sshd -T | grep -qx "passwordauthentication no"'
  check "firewall only allows SSH"        '[ "$(sudo firewall-cmd --get-default-zone)" = server ] && [ "$(sudo firewall-cmd --list-services | tr " " "\n" | sort | xargs)" = "dhcpv6-client ssh" ] && [ -z "$(sudo firewall-cmd --list-ports)" ]'
  check "fail2ban guards SSH"             'sudo fail2ban-client status sshd'
  check "restarts into downloaded updates" 'systemctl is-enabled --quiet rpm-ostree-reboot.timer'
  check "logs in to Sway at boot, locked" 'grep -qx "User=tester" /etc/sddm.conf.d/50-machine-setup-autologin.conf && test -L .config/systemd/user/graphical-session.target.wants/swaylock-at-login.service'
else
  check "VLC Flatpak installed"           'flatpak info org.videolan.VLC'
  check "no automatic login on a desktop" '! test -e /etc/sddm.conf.d/50-machine-setup-autologin.conf'
fi

# ------------------------------------------------------------ summary
log "Summary ($IMAGE, $PROFILE profile)"
printf '%s\n' "${RESULTS[@]}"
if printf '%s\n' "${RESULTS[@]}" | grep -q '^FAIL'; then
  mkdir -p "$CACHE/logs"
  cp "$WORK"/run*.log "$WORK/console.log" "$CACHE/logs/" 2>/dev/null || true
  echo "Logs saved in $CACHE/logs/"
  exit 1
fi
echo "All checks passed."
