#!/usr/bin/env bash
# shellcheck disable=SC2016  # check commands are single-quoted on purpose: they expand inside the VM
# Test the playbook end to end in a throwaway Fedora VM.
#
#   tests/vm-test.sh                 # Fedora 43, full test
#   tests/vm-test.sh --release 42    # another Fedora release
#   tests/vm-test.sh --keep          # leave the VM running afterwards (ssh command is printed)
#   tests/vm-test.sh --quick         # skip pre-installing Firefox/Chromium/LibreOffice
#   tests/vm-test.sh --profile server  # headless Fedora Server profile
#   tests/vm-test.sh --github-user NAME [--dotfiles-version REF]
#                                      # also test NAME's dotfiles (and, on a
#                                      # server, NAME's GitHub SSH keys)
#
# What it does:
#   1. Downloads the Fedora Cloud image once (cached in ~/.cache/machine-setup-vm)
#      and verifies its checksum.
#   2. Boots a fresh VM from a disposable copy-on-write disk, so every run starts clean.
#   3. Pre-installs Chromium and LibreOffice so the removals are really tested (and
#      Firefox, which must be kept).
#   4. Copies THIS working tree (including uncommitted changes) into the VM and runs
#      ./bootstrap.sh, then runs the playbook a second time and expects changed=0.
#   5. Checks the results (Flatpaks, removals, podman, ...) and prints PASS/FAIL.
#   6. Shuts the VM down and deletes its disk (unless --keep).
#
# Needs (Fedora host): sudo dnf install -y qemu-kvm qemu-img xorriso openssh-clients curl
# Linux x86_64 with KVM only. The VM is headless, so GUI apps are checked as
# installed, not launched.
set -euo pipefail

RELEASE=43
KEEP=0
QUICK=0
PROFILE=desktop
SSH_PORT="${SSH_PORT:-2222}"
MEM_MB="${MEM_MB:-4096}"
CPUS="${CPUS:-2}"
DISK_SIZE="${DISK_SIZE:-30G}"

while [ $# -gt 0 ]; do
  case "$1" in
    --release) RELEASE="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --quick) QUICK=1; shift ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --github-user) GITHUB_USER="$2"; shift 2 ;;
    --dotfiles-version) DOTFILES_VERSION="$2"; shift 2 ;;
    -h|--help) sed -n '3,25p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

case "$PROFILE" in desktop) ;; server) QUICK=1 ;; *) echo "--profile must be desktop or server" >&2; exit 2 ;; esac
# (Nothing is removed on a headless server, so it skips the pre-installs.)

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
  vm 'sudo dnf install -y -q firefox chromium libreoffice-writer libreoffice-calc unoconv gnome-tour simple-scan'
fi
if [ "$PROFILE" = desktop ]; then
  # Fedora Workstation runs firewalld; the cloud image doesn't.
  log "Starting firewalld, as on Fedora Workstation"
  vm 'sudo dnf install -y -q firewalld && sudo systemctl enable --now firewalld'
fi

log "Copying this working tree into the VM"
tar -C "$REPO_DIR" --exclude=./.git --exclude=./collections --exclude=./.ansible -czf - . \
  | vm 'rm -rf ~/machine-setup && mkdir ~/machine-setup && tar -xzf - -C ~/machine-setup'

# ------------------------------------------------------------ run
RESULTS=()
pass() { RESULTS+=("PASS  $1"); printf '\033[32mPASS\033[0m  %s\n' "$1"; }
fail() { RESULTS+=("FAIL  $1"); printf '\033[31mFAIL\033[0m  %s\n' "$1"; }
check() { local name="$1"; shift; if vm "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

# Tag for each role (where it differs from the role name), so a failing role
# can be skipped and the rest of the playbook still tested in the same run.
role_tag() {
  case "$1" in
    jetbrains_toolbox) echo jetbrains ;;
    claude_code) echo claude ;;
    auto_updates) echo updates ;;
    git_setup) echo git ;;
    *) echo "$1" ;;
  esac
}
# Prints the role of the task that failed in a log, if any.
failed_role() {
  grep -B30 '^fatal:' "$1" | sed -n 's/^TASK \[\([a-z_]*\) : .*/\1/p' | tail -1
}

# The cloud image has no desktop, so the server profile runs headless.
if [ "$PROFILE" = server ]; then
  PB_ARGS="-e profile=server -e machine_gui=false"
  BOOT_ARGS="--profile server --headless"
else
  # Remote Login is a GUI-server default; turn it on here so it's tested.
  PB_ARGS="-e remote_desktop_enabled=true"
  BOOT_ARGS="-e remote_desktop_enabled=true"
fi
if [ -n "${GITHUB_USER:-}" ]; then
  PB_ARGS="$PB_ARGS -e github_user=$GITHUB_USER -e dotfiles_version=${DOTFILES_VERSION:-HEAD}"
  BOOT_ARGS="$BOOT_ARGS -e github_user=$GITHUB_USER -e dotfiles_version=${DOTFILES_VERSION:-HEAD}"
fi

log "Run 1: ./bootstrap.sh $BOOT_ARGS"
SKIP_TAGS=""
if vm "cd ~/machine-setup && ./bootstrap.sh $BOOT_ARGS" 2>&1 | tee "$WORK/run1.log"; then
  pass "bootstrap.sh completed"
else
  fail "bootstrap.sh completed"
  # Keep going past failing roles (up to 5) so one run reports every failure.
  logf="$WORK/run1.log"
  for attempt in 1 2 3 4 5; do
    role="$(failed_role "$logf")"
    [ -n "$role" ] || break
    fail "role '$role' failed (skipped for the rest of the test)"
    SKIP_TAGS="${SKIP_TAGS:+$SKIP_TAGS,}$(role_tag "$role")"
    logf="$WORK/run1-retry$attempt.log"
    log "Run 1 again without: $SKIP_TAGS"
    if vm "cd ~/machine-setup && ansible-playbook site.yml $PB_ARGS --skip-tags $SKIP_TAGS" 2>&1 | tee "$logf"; then
      break
    fi
  done
fi

log "Run 2: the playbook again (should change nothing)"
vm "cd ~/machine-setup && ansible-playbook site.yml $PB_ARGS" 2>&1 | tee "$WORK/run2.log" || true
if grep -Eq 'localhost +: ok=[0-9]+ +changed=0 +unreachable=0 +failed=0' "$WORK/run2.log"; then
  pass "second run reports changed=0 failed=0"
else
  fail "second run reports changed=0 failed=0"
fi

log "Run 3: bootstrap.sh --dry-run (should report no changes)"
vm "cd ~/machine-setup && ./bootstrap.sh $BOOT_ARGS --dry-run" 2>&1 | tee "$WORK/run3.log" || true
if grep -Eq 'localhost +: ok=[0-9]+ +changed=0 +unreachable=0 +failed=0' "$WORK/run3.log"; then
  pass "dry run reports changed=0 failed=0"
else
  fail "dry run reports changed=0 failed=0"
fi

log "Checking the result ($PROFILE profile)"
# Every profile.
check "podman runs a container"         'podman run --rm quay.io/podman/hello'
check "Docker not installed"            '! rpm -q docker-ce'
check "zsh is the login shell"           'getent passwd tester | grep -q "/zsh$"'
check "antidote loads in zsh"            'zsh -ic "type antidote"'
check "Claude Code installed"            'test -x .local/bin/claude && .local/bin/claude --version'
check "vim and vim-plug installed"       'vim --version >/dev/null && test -f .vim/autoload/plug.vim'
check "vim plugins installed"            'test -d .vim/plugged/vim-sensible'
check "gh installed"                     'gh --version'
check "mise and uv installed"            '.local/bin/mise --version && .local/bin/mise exec -- uv --version'
check "fzf, bat, btop and eza installed"  'command -v fzf && command -v bat && command -v btop && command -v eza'
check "Tailscale installed and running"  'rpm -q tailscale && systemctl is-active --quiet tailscaled'
check "dnf-automatic timer enabled"     'systemctl list-unit-files --state=enabled "dnf*-automatic.timer" | grep -q automatic'
check "full ffmpeg from RPM Fusion"     'rpm -q ffmpeg && rpm -q --whatprovides gstreamer1-libav'
check "git uses delta"                  '[ "$(git config --global core.pager)" = delta ] && command -v delta'
check "SSH key created"                 'test -f .ssh/id_ed25519.pub'
check "dnf takes snapper snapshots"     'before=$(sudo snapper -c root list --columns number | wc -l); sudo dnf install -y -q tree >/dev/null && after=$(sudo snapper -c root list --columns number | wc -l) && [ "$after" -ge $((before + 2)) ]'
if [ -n "${GITHUB_USER:-}" ]; then
  # Linked when the repo has a home/ folder; otherwise just cloned.
  check "dotfiles cloned and linked"    'test -d .dotfiles/.git && { [ ! -d .dotfiles/home ] || { [ -L .zshrc ] && [ -L .vimrc ]; }; }'
fi

if [ "$PROFILE" = server ]; then
  check "tmux installed"                  'command -v tmux'
  check "no desktop apps (Flatpaks, VS Code, fonts)" '! flatpak list 2>/dev/null | grep -q . && ! rpm -q code && ! fc-list 2>/dev/null | grep -qi "Nerd Font"'
  check "sshd enabled at boot"            'systemctl is-enabled --quiet sshd'
  check "SSH: root login off"             'sudo sshd -T | grep -qx "permitrootlogin no"'
  check "SSH: password login off"         'sudo sshd -T | grep -qx "passwordauthentication no"'
  check "firewall only allows SSH"        '[ "$(sudo firewall-cmd --list-services | tr " " "\n" | sort | xargs)" = "dhcpv6-client ssh" ]'
  check "fail2ban guards SSH"             'sudo fail2ban-client status sshd'
  check "all updates, reboot when needed" 'grep -qx "upgrade_type *= *default" /etc/dnf/automatic.conf && grep -qx "reboot *= *when-needed" /etc/dnf/automatic.conf'
else
  check "Chrome Flatpak installed"        'flatpak info com.google.Chrome'
  check "Spotify Flatpak installed"       'flatpak info com.spotify.Client'
  check "Firefox kept"                    'rpm -q firefox'
  check "Chromium removed"                '[ -z "$(rpm -qa "chromium*")" ]'
  check "All LibreOffice packages removed" '[ -z "$(rpm -qa "libreoffice*")" ] && ! rpm -q unoconv'
  check "GNOME Tour and Simple Scan removed" '! rpm -q gnome-tour && ! rpm -q simple-scan'
  check "VLC Flatpak installed"           'flatpak info org.videolan.VLC'
  check "Steam Flatpak installed"         'flatpak info com.valvesoftware.Steam'
  check "VS Code installed"                'rpm -q code'
  check "Ghostty installed"                'rpm -q ghostty'
  check "Ghostty theme exists"             'grep -qx "theme = Catppuccin Mocha" .config/ghostty/config && ghostty +list-themes --plain 2>/dev/null | grep -q "^Catppuccin Mocha"'
  check "JetBrains Toolbox installed"      'test -x ~/.local/share/JetBrains/Toolbox/bin/jetbrains-toolbox'
  check "JetBrains Mono Nerd Font installed" 'fc-list | grep -qi "JetBrainsMono Nerd Font"'
  check "Flatpak update timer enabled"    'systemctl is-enabled --quiet flatpak-update.timer'
  check "Remote Login service running"   'systemctl is-active --quiet gnome-remote-desktop'
  check "RDP certificate renewal timer on" 'systemctl is-enabled --quiet rdp-tailscale-cert.timer'
  # Remote Login only listens with GDM running, which the cloud image lacks.
  check "RDP listening (if GDM runs)"    '! systemctl is-active --quiet gdm || sudo ss -Htln "sport = :3389" | grep -q .'
  check "Remote Login (RDP) turned on"    'sudo grdctl --system status | grep -A1 "^RDP:" | grep -q "Status: enabled"'
  # (The cloud image doesn't run firewalld; Fedora Workstation does.)
  check "RDP open to Tailscale only"      'r=$(sudo firewall-cmd --list-rich-rules); echo "$r" | grep -q "100.64.0.0/10.*3389" && ! echo "$r" | grep -q "192.168.0.0/16" && ! sudo firewall-cmd --list-ports | grep -qw 3389/tcp'
fi

# ------------------------------------------------------------ summary
log "Summary (Fedora $RELEASE, $PROFILE profile)"
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
