#!/bin/bash
# End-to-end test on a throwaway CI Mac: installs Intent Mode in TEST mode and checks that
# DNS + pf really block and allow what they should, then uninstalls and checks everything is restored.
# GitHub's own domains are added to the locked allowlist so the CI runner keeps its connection.
# Not meant for your own Mac (use "Try Intent Mode.command" there).
set -u
cd "$(dirname "$0")/.."
VER="$(tr -d ' \n' < VERSION)"
PKG="$PWD/build/IntentMode-$VER"
BASE="/Library/Application Support/IntentMode"
PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
refuse() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$name"; else ok "$name"; fi; }

resolves()   { dig @127.0.0.1 +time=3 +tries=1 +short "$1" A | grep -qE '^[0-9]+\.'; }
nxdomain()   { dig @127.0.0.1 +time=3 +tries=1 "$1" A | grep -q 'status: NXDOMAIN'; }
fetch()      { curl -s -o /dev/null -m 10 "$1"; }
first_service() { networksetup -listallnetworkservices | tail -n +2 | sed 's/^\*//' | head -1; }

cleanup() {
  echo "== daemon.log =="; sudo cat "$BASE/daemon.log" 2>/dev/null | tail -n 60
  echo "== guard.log ==";  sudo cat "$BASE/guard.log" 2>/dev/null | tail -n 20
  echo "== uninstall =="
  [ -f "$BASE/uninstall.sh" ] && sudo bash "$BASE/uninstall.sh" --yes
}
trap cleanup EXIT

echo "== Preparing CI config (GitHub domains allowed while locked) =="
sudo mkdir -p "$BASE"
python3 - "$PKG/Resources/config.default.json" <<'PY' | sudo tee "$BASE/config.json" >/dev/null
import json, sys
c = json.load(open(sys.argv[1]))
c["locked_allowed_domains"] += ["github.com", "githubusercontent.com", "githubassets.com", "githubapp.com",
                                "windows.net", "visualstudio.com", "azure.com", "msftauth.net"]
print(json.dumps(c, indent=2))
PY

echo "== Installing in test mode (5 min) =="
sudo bash "$PKG/install.sh" --test 5 || { bad "install"; exit 1; }
sleep 10

echo "== Daemon =="
check "daemon is running"                 sudo launchctl print system/com.intentmode.daemon
check "intentmode status answers"         intentmode status
intentmode status || true
check "pf is enabled"                     bash -c "sudo pfctl -s info | grep -q 'Status: Enabled'"
check "our pf anchor is loaded"           bash -c "sudo pfctl -a com.apple/000.intentmode -s rules | grep -q 'block return out quick all'"
SVC="$(first_service)"
check "DNS of '$SVC' points to 127.0.0.1" bash -c "networksetup -getdnsservers '$SVC' | grep -q '^127.0.0.1$'"

echo "== Locked =="
check  "resolver answers for an allowed name (github.com)"  resolves github.com
check  "resolver refuses example.com (NXDOMAIN)"            nxdomain example.com
check  "resolver refuses reddit.com (NXDOMAIN)"             nxdomain reddit.com
check  "https://github.com loads"                           fetch https://github.com
refuse "https://example.com is blocked"                     fetch https://example.com
refuse "hard-coded IP https://1.1.1.1 is blocked"           fetch https://1.1.1.1
refuse "other DNS server 8.8.8.8 is blocked"                dig @8.8.8.8 +time=2 +tries=1 +short example.com A
refuse "resolving via 8.8.8.8 returns nothing usable"       bash -c "dig @8.8.8.8 +time=2 +tries=1 +short example.com | grep -qE '^[0-9]'"

echo "== Claude session =="
check  "session starts"                    intentmode start claude this is an automated test session for continuous integration checks
sleep 2
check  "https://pypi.org loads"            fetch https://pypi.org
check  "https://claude.ai resolves"        resolves claude.ai
refuse "https://example.com still blocked" fetch https://example.com
refuse "youtube.com refused"               resolves www.youtube.com
check  "too-short intent is rejected"      bash -c "! intentmode start journal too short 2>/dev/null"
check  "session ends"                      intentmode end automated test finished
sleep 2
refuse "pypi.org blocked again after end"  fetch https://pypi.org

echo "== Uninstall restores everything =="
sudo bash "$BASE/uninstall.sh" --yes >/dev/null 2>&1
sleep 3
refuse "daemon is gone"                    sudo launchctl print system/com.intentmode.daemon
refuse "DNS no longer 127.0.0.1"           bash -c "networksetup -getdnsservers '$SVC' | grep -q '^127.0.0.1$'"
refuse "pf anchor removed"                 bash -c "sudo pfctl -a com.apple/000.intentmode -s rules 2>/dev/null | grep -q block"
check  "https://example.com works again"   fetch https://example.com
check  "logs were kept"                    test -f /Users/Shared/IntentMode/last-logs/daemon.log

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
