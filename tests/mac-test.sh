#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088  # checks are single-quoted on purpose; bash -lc expands them
# Runs the setup on a throwaway macOS machine (a GitHub Actions macOS runner)
# and checks the result. Don't run this on your own Mac: it installs and
# removes apps for real.
#
#   tests/mac-test.sh [--skip-rustdesk]
#
# 1. Pre-installs Firefox (as a cask) so its removal can be checked.
# 2. Runs ./bootstrap.sh, then the playbook again and expects changed=0.
# 3. Checks each app and tool.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
WORK="${RUNNER_TEMP:-/tmp}/mac-test"
mkdir -p "$WORK"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
RESULTS=()
pass() { RESULTS+=("PASS  $1"); printf '\033[32mPASS\033[0m  %s\n' "$1"; }
fail() { RESULTS+=("FAIL  $1"); printf '\033[31mFAIL\033[0m  %s\n' "$1"; }
check() { local name="$1"; shift; if bash -lc "$*" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

SKIP_RUSTDESK=""
[ "${1:-}" = "--skip-rustdesk" ] && SKIP_RUSTDESK=1
EXTRA=()
[ -n "$SKIP_RUSTDESK" ] && EXTRA=(-e rustdesk_enabled=false)

# Non-interactive shells (CI, ssh) may not have Homebrew on PATH yet.
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [ -x "$b" ] && eval "$("$b" shellenv)" && break
done

log "Preinstalling Firefox to check it gets removed"
brew install --cask firefox >/dev/null 2>&1 || true

log "Run 1: ./bootstrap.sh"
if ./bootstrap.sh ${EXTRA[@]+"${EXTRA[@]}"} 2>&1 | tee "$WORK/run1.log"; then
  pass "bootstrap.sh completed"
else
  fail "bootstrap.sh completed"
fi

log "Run 2: the playbook again (should change nothing)"
eval "$(brew shellenv)"
ansible-playbook site.yml ${EXTRA[@]+"${EXTRA[@]}"} 2>&1 | tee "$WORK/run2.log" || true
if grep -Eq 'localhost +: ok=[0-9]+ +changed=0 +unreachable=0 +failed=0' "$WORK/run2.log"; then
  pass "second run reports changed=0 failed=0"
else
  fail "second run reports changed=0 failed=0"
fi

log "Run 3: bootstrap.sh --dry-run (should report no changes)"
./bootstrap.sh --dry-run ${EXTRA[@]+"${EXTRA[@]}"} 2>&1 | tee "$WORK/run3.log" || true
if grep -Eq 'localhost +: ok=[0-9]+ +changed=0 +unreachable=0 +failed=0' "$WORK/run3.log"; then
  pass "dry run reports changed=0 failed=0"
else
  fail "dry run reports changed=0 failed=0"
fi

log "Checking the result"
while read -r cask; do
  [ "$cask" = rustdesk ] && [ -n "$SKIP_RUSTDESK" ] && continue
  check "cask $cask installed" "brew list --cask $cask"
done < <(sed -n '/^casks:/,/^[a-z_]*:/p' vars/apps.yml | sed -n 's/^  - \([a-z0-9-]*\).*/\1/p')
check "Firefox removed"                  '! brew list --cask firefox'
check "git, gh, vim installed"           'command -v git && command -v gh && command -v vim'
check "fzf, bat, btop and eza installed" 'command -v fzf && command -v bat && command -v btop && command -v eza'
check "podman installed"                 'command -v podman'
check "antidote loads in zsh"            "zsh -ic 'type antidote'"
check "Claude Code installed"            '~/.local/bin/claude --version'
check "vim-plug and plugins installed"   '[ -f ~/.vim/autoload/plug.vim ] && [ -d ~/.vim/plugged/vim-surround ]'
check "mise and uv installed"            '~/.local/bin/mise which uv'
check "Ghostty config has the theme"     'grep -q "^theme = " ~/.config/ghostty/config'
check "git uses delta"                   '[ "$(git config --global core.pager)" = delta ]'
check "SSH key created"                  '[ -f ~/.ssh/id_ed25519.pub ]'
check "dark mode on"                     '[ "$(defaults read -g AppleInterfaceStyle)" = Dark ]'
check "Dock hides automatically"         '[ "$(defaults read com.apple.dock autohide)" = 1 ]'
check "fast key repeat"                  '[ "$(defaults read -g KeyRepeat)" = 2 ]'
check "Finder shows extensions and hidden files" '[ "$(defaults read -g AppleShowAllExtensions)" = 1 ] && [ "$(defaults read com.apple.finder AppleShowAllFiles)" = 1 ]'
check "GarageBand removed"               '[ ! -e /Applications/GarageBand.app ]'

log "Summary"
printf '%s\n' "${RESULTS[@]}"
if printf '%s\n' "${RESULTS[@]}" | grep -q '^FAIL'; then
  exit 1
fi
