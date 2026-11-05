#!/usr/bin/env bash
# shellcheck disable=SC2029,SC2329  # remote commands are built locally on purpose; cleanup runs via trap
# Tests the setup in a throwaway macOS VM on your Mac (Apple Silicon), using
# Tart. Nothing is installed on your own Mac apart from Tart and the VM image.
#
#   brew install cirruslabs/cli/tart     # once
#   tests/mac-vm-test.sh                 # full test, then delete the VM
#   tests/mac-vm-test.sh --keep          # leave the VM running afterwards
#   tests/mac-vm-test.sh --skip-rustdesk
#   tests/mac-vm-test.sh --image ghcr.io/cirruslabs/macos-tahoe-base:latest
#
# What it does:
#   1. Clones a Cirrus Labs macOS image (Homebrew + passwordless sudo, like
#      GitHub's runners). The first run downloads it (~25 GB); later clones
#      are instant copy-on-write.
#   2. Boots it headless and copies this working tree in (uncommitted
#      changes included).
#   3. Runs tests/mac-test.sh inside it: bootstrap.sh, a second run that
#      should change nothing, then checks every cask and tool.
#   4. Copies the logs out and deletes the VM (unless --keep).
set -euo pipefail

IMAGE="ghcr.io/cirruslabs/macos-sequoia-base:latest"
DISK_GB=100
KEEP=""
TEST_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    --disk) DISK_GB="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --skip-rustdesk) TEST_ARGS+=(--skip-rustdesk); shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || die "Needs a Mac with Apple Silicon."
command -v tart >/dev/null || die "Install Tart first: brew install cirruslabs/cli/tart"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VM="machine-setup-test-$$"
LOGS="$HOME/Library/Caches/machine-setup-vm/logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"

# The Cirrus images log in as admin/admin. Feed the password to ssh without
# extra tools by using an askpass helper.
ASKPASS="$(mktemp -t machine-setup-askpass)"
printf '#!/bin/sh\necho admin\n' > "$ASKPASS"
chmod 700 "$ASKPASS"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o PubkeyAuthentication=no -o ConnectTimeout=5)
vm() { SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force ssh "${SSH_OPTS[@]}" "admin@$IP" "$@" </dev/null; }
vm_in() { SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force ssh "${SSH_OPTS[@]}" "admin@$IP" "$@"; }

cleanup() {
  rm -f "$ASKPASS"
  if [ -n "$KEEP" ]; then
    log "VM left running (--keep). Connect with: ssh admin@${IP:-<ip>}  (password: admin)"
    log "Delete it later with: tart stop $VM; tart delete $VM"
  else
    tart stop "$VM" >/dev/null 2>&1 || true
    tart delete "$VM" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

log "Cloning $IMAGE (the first time downloads it)"
tart clone "$IMAGE" "$VM"
tart set "$VM" --disk-size "$DISK_GB"

log "Booting $VM"
tart run "$VM" --no-graphics >"$LOGS/tart-run.log" 2>&1 &
IP=""
for _ in $(seq 1 60); do
  IP="$(tart ip "$VM" 2>/dev/null || true)"
  [ -n "$IP" ] && vm true 2>/dev/null && break
  IP=""
  sleep 5
done
[ -n "$IP" ] || die "VM didn't come up (see $LOGS/tart-run.log)"
echo "    up at $IP"

log "Copying the working tree in"
tar -C "$REPO_DIR" --exclude=./.git --exclude=./collections --exclude=./.ansible -czf - . \
  | vm_in 'rm -rf ~/machine-setup && mkdir ~/machine-setup && tar -xzf - -C ~/machine-setup'

log "Running tests/mac-test.sh in the VM"
status=0
vm "cd ~/machine-setup && RUNNER_TEMP=~/mac-test-logs tests/mac-test.sh ${TEST_ARGS[*]:-}" \
  2>&1 | tee "$LOGS/mac-test.log" || status=$?

vm 'tar -C ~ -czf - mac-test-logs 2>/dev/null' | tar -xzf - -C "$LOGS" 2>/dev/null || true
log "Logs: $LOGS"
exit "$status"
