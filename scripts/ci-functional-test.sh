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

ART="$PWD/ci-artifacts"; mkdir -p "$ART"
shot() { screencapture -x "$ART/$1.png" 2>/dev/null || sudo screencapture -x "$ART/$1.png" 2>/dev/null; }
cleanup() {
  [ -f "$BASE/uninstall.sh" ] && sudo bash "$BASE/uninstall.sh" --yes >/dev/null 2>&1
  cp /Users/Shared/IntentMode/last-logs/* "$ART"/ 2>/dev/null
  echo "== daemon.log =="; cat "$ART/daemon.log" 2>/dev/null | tail -n 80
  echo "== guard.log ==";  cat "$ART/guard.log" 2>/dev/null | tail -n 20
  echo "== screen log =="; cat "$ART/IntentMode-screen.log" 2>/dev/null | tail -n 60
}
trap cleanup EXIT

prep_config() {
sudo mkdir -p "$BASE"
python3 - "$PKG/Resources/config.default.json" <<'PY' | sudo tee "$BASE/config.json" >/dev/null
import json, sys
c = json.load(open(sys.argv[1]))
c["locked_allowed_domains"] += ["github.com", "githubusercontent.com", "githubassets.com", "githubapp.com",
                                "windows.net", "visualstudio.com", "azure.com", "msftauth.net"]
c["idle_end_minutes"] = 0   # nobody touches the CI Mac's keyboard
c["bedtime"] = None        # CI runs in UTC at any hour (null = bedtime off)
c["escape_wait_minutes"] = 0
c["loosening_delay_hours"] = 0.01   # 36 s instead of 24 h, so CI can watch changes apply
c["disable_delay_hours"] = 0.01
for m in c["modes"]:
    if m["id"] == "research":
        m["start_delay_seconds"] = 3   # keep CI quick
print(json.dumps(c, indent=2))
PY
}
echo "== Preparing CI config (GitHub domains allowed while locked) =="
prep_config

echo "== Installing in test mode (5 min) =="
echo "console user: $(stat -f %Su /dev/console)"
sudo bash "$PKG/install.sh" --test 5 || { bad "install"; exit 1; }
sleep 10
shot 1-locked
check "intent screen process is running"  pgrep -f IntentScreen.app/Contents/MacOS/IntentScreen

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
check  "session starts"                    intentmode start journal this is an automated test session for continuous integration checks
sleep 3
shot 2-session
echo "  status timings during the session:"
slow=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  t0=$(python3 -c 'import time;print(time.time())')
  st=$(intentmode status 2>&1 | grep '^State' || echo "State: ERROR")
  t1=$(python3 -c 'import time;print(time.time())')
  ms=$(python3 -c "print(int(($t1-$t0)*1000))")
  echo "    $st  (${ms} ms)"
  [ "$ms" -gt 1500 ] && slow=$((slow+1))
  sleep 1
done
check  "status says SESSION"               bash -c "intentmode status | grep -q 'State: SESSION'"
check  "status answers quickly in session" test "$slow" -le 1
intentmode end ci switch >/dev/null 2>&1; sleep 2
check  "claude session starts"             intentmode start claude this is an automated test session for continuous integration checks
sleep 2
check  "https://pypi.org loads"            fetch https://pypi.org
check  "https://claude.ai resolves"        resolves claude.ai
refuse "https://example.com still blocked" fetch https://example.com
refuse "youtube.com refused"               resolves www.youtube.com
check  "too-short intent is rejected"      bash -c "! intentmode start journal too short 2>/dev/null"
check  "session ends"                      intentmode end automated test finished
sleep 2
refuse "pypi.org blocked again after end"  fetch https://pypi.org

echo "== Reselling (Sundays 10–17 only) =="
if [ "$(date +%u)" = 7 ] && [ "$(date +%H)" -ge 10 ] && [ "$(date +%H)" -lt 17 ]; then
  echo "  (it's Sunday daytime here — skipping the 'outside its window' check)"
else
  check "reselling is closed outside Sunday 10–17" bash -c "intentmode status | grep reselling | grep -q 'Only Sun 10:00'"
  refuse "reselling can't be started now"          intentmode start reselling checking prices on goofish and listing three items on kleinanzeigen today
fi

echo "== Research (open web) =="
check  "research session starts (after its pause)"  intentmode start research looking up used car prices on some dealer websites for my trip planning
sleep 2
shot 3-research
check  "https://example.com loads (open web)"       fetch https://example.com
check  "https://www.wikipedia.org loads"            fetch https://www.wikipedia.org
check  "reddit.com refused (distraction list)"      nxdomain www.reddit.com
check  "youtube.com refused (distraction list)"     nxdomain www.youtube.com
check  "status shows weekly usage"                  bash -c "intentmode status | grep -q 'week 1/5'"
echo "  -- adult filter (every mode, including open web) --"
check  "mangafire.to refused (curated list)"        nxdomain mangafire.to
check  "pornhub.com refused (OISD/HaGeZi lists)"    nxdomain www.pornhub.com
check  "nhentai.net refused"                        nxdomain nhentai.net
check  "dns.google refused (bypass list)"           nxdomain dns.google
check  "archive.ph refused (bypass list)"           nxdomain archive.ph
safe_ip() { dig @127.0.0.1 +short "$1" A | grep -E '^[0-9]' | sort | head -1; }
check  "Google SafeSearch forced"                   test "$(safe_ip www.google.com)" = "$(safe_ip forcesafesearch.google.com)"
check  "Bing strict SafeSearch forced"              test "$(safe_ip www.bing.com)" = "$(safe_ip strict.bing.com)"
check  "a normal search page still loads"           fetch "https://duckduckgo.com/?q=car+rental"
check  "research session ends"                      intentmode end done researching
sleep 2
refuse "example.com blocked again after research"   fetch https://example.com
check  "research is in its 15-minute cooldown"      bash -c "intentmode status | grep -q 'Available again at'"

echo "== Open session (escape hatch) =="
refuse "open session can't be started directly"    intentmode start open just trying to skip all of the steps of the escape hatch here
cat > /tmp/im_escape.py <<'PY'
import json, socket, sys
def call(req):
    s = socket.socket(socket.AF_UNIX); s.connect("/var/run/intentmode.sock")
    s.sendall((json.dumps(req) + "\n").encode()); data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk: break
        data += chunk
    return json.loads(data)
step = sys.argv[1]
if step == "short":
    sys.exit(0 if not call({"cmd": "escape_request", "mode": "open", "reason": "too short"})["ok"] else 1)
if step == "request":
    reason = " ".join(["I need to install a printer driver from the vendor website which is not covered by any other mode today"] * 2)
    sys.exit(0 if call({"cmd": "escape_request", "mode": "open", "reason": reason})["ok"] else 1)
st = call({"cmd": "status"})["status"]
if step == "challenge_len":
    sys.exit(0 if st.get("escapeStage") == "challenge" and len(st.get("escapeChallenge", "")) == 150 else 1)
if step == "wrong":
    sys.exit(0 if not call({"cmd": "escape_challenge", "intent": "x" * 150})["ok"] else 1)
if step == "right":
    sys.exit(0 if call({"cmd": "escape_challenge", "intent": st["escapeChallenge"]})["ok"] else 1)
if step == "confirm":
    sys.exit(0 if call({"cmd": "escape_confirm"})["ok"] else 1)
if step == "week":
    s = call({"cmd": "stats"})["stats"]
    print(json.dumps({k: s[k] for k in ("totalMinutes", "sessionCount", "openSessionsUsed", "perDayMinutes")}))
    sys.exit(0 if s["sessionCount"] >= 3 else 1)
PY
check  "a short reason is refused"                 python3 /tmp/im_escape.py short
check  "a 25+ word reason is accepted"             python3 /tmp/im_escape.py request
check  "a 150-character retype text is shown"      python3 /tmp/im_escape.py challenge_len
check  "a wrong retype is refused"                 python3 /tmp/im_escape.py wrong
check  "the exact retype is accepted"              python3 /tmp/im_escape.py right
# The intent screen confirms by itself once the wait is over; whichever is first wins.
python3 /tmp/im_escape.py confirm >/dev/null 2>&1; sleep 2
check  "the open session starts after the wait"    bash -c "intentmode status | grep -q 'State: SESSION — Open session'"
check  "python3 is not quit in a session (CLI tool)" python3 -c "import time; time.sleep(3)"
sleep 2
check  "open web works in the open session"        fetch https://example.com
check  "reddit.com still refused"                  nxdomain www.reddit.com
check  "adult sites still refused"                 nxdomain www.pornhub.com
check  "open session ends"                         intentmode end done
sleep 1
check  "weekly overview counts the sessions"       python3 /tmp/im_escape.py week
check  "lock screen shows today's usage"           bash -c "intentmode status >/dev/null"

check  "config upgrader keeps a disabled bedtime off" bash -c "! intentmode status | grep -q Bedtime && ! grep -q 'added setting .bedtime' '$BASE/daemon.log'"

echo "== Uninstall restores everything =="
sudo bash "$BASE/uninstall.sh" --yes >/dev/null 2>&1
sleep 3
refuse "daemon is gone"                    sudo launchctl print system/com.intentmode.daemon
refuse "DNS no longer 127.0.0.1"           bash -c "networksetup -getdnsservers '$SVC' | grep -q '^127.0.0.1$'"
refuse "pf anchor removed"                 bash -c "sudo pfctl -a com.apple/000.intentmode -s rules 2>/dev/null | grep -q block"
check  "https://example.com works again"   fetch https://example.com
check  "logs were kept"                    test -f /Users/Shared/IntentMode/last-logs/daemon.log

echo "== Permanent install =="
prep_config
check  "permanent install works"                   bash -c "echo INSTALL | sudo bash '$PKG/install.sh' >/dev/null 2>&1"
sleep 10
check  "daemon runs from /Library/LaunchDaemons"   sudo launchctl print system/com.intentmode.daemon

echo "== Lock-down (Phase 4, for a dummy account so this runner keeps sudo) =="
cat > /tmp/im_ld.py <<'PY'
import json, socket, sys
def call(req):
    s = socket.socket(socket.AF_UNIX); s.connect("/var/run/intentmode.sock")
    s.sendall((json.dumps(req) + "\n").encode()); data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk: break
        data += chunk
    return json.loads(data)
what = sys.argv[1]
if what == "emergency":
    sys.exit(0 if not call({"cmd": "emergency_off", "username": "x", "password": "y"})["ok"] else 1)
st = call({"cmd": "status"})["status"]
if what == "pending":   print(len(st["pending"])); sys.exit(0)
if what == "minutes":   print([m["minutes"] for m in st["modes"] if m["id"] == sys.argv[2]][0]); sys.exit(0)
if what == "active":    sys.exit(0 if st["lockdownActive"] else 1)
if what == "escape":    sys.exit(0 if st["lockdownEscapeAvailable"] else 1)
if what == "cancel_all":
    for p in st["pending"]: call({"cmd": "pending_cancel", "noteId": p["id"]})
    sys.exit(0)
PY
edit_cfg() {  # edit_cfg <python expression on c> → writes ~/im-test-settings.json
  python3 - "$1" <<'PY'
import json, os, sys
c = json.load(open("/Library/Application Support/IntentMode/config.json"))
exec(sys.argv[1])
json.dump(c, open(os.path.expanduser("~/im-test-settings.json"), "w"), indent=2)
PY
}
check  "lock-down turns on"                         sudo intentmode lockdown enable --user imtest --yes
check  "sudo rule installed and valid"              bash -c "sudo test -f /etc/sudoers.d/zz-intentmode-lockdown && sudo visudo -c"
check  "status says lock-down is on"                python3 /tmp/im_ld.py active
check  "one-time turn-off is available"             python3 /tmp/im_ld.py escape
check  "emergency off is refused"                   python3 /tmp/im_ld.py emergency
refuse "learn is refused"                           sudo intentmode learn start journal
edit_cfg 'next(m for m in c["modes"] if m["id"]=="journal")["minutes"]=15'
check  "tightening applies at once"                 intentmode config propose ~/im-test-settings.json
check  "journal is now 15 min"                      test "$(python3 /tmp/im_ld.py minutes journal)" = 15
edit_cfg 'next(m for m in c["modes"] if m["id"]=="journal")["minutes"]=25'
check  "loosening is accepted as pending"           intentmode config propose ~/im-test-settings.json
check  "…and is pending, not applied"               test "$(python3 /tmp/im_ld.py minutes journal)" = 15
check  "…shows on the pending list"                 test "$(python3 /tmp/im_ld.py pending)" = 1
edit_cfg 'c["loosening_delay_hours"]=0.001'
refuse "lowering a delay is refused"                intentmode config propose ~/im-test-settings.json
sudo python3 - <<'PY'
import json
p = "/Library/Application Support/IntentMode/config.json"
c = json.load(open(p)); next(m for m in c["modes"] if m["id"] == "journal")["domains"].append("reddit.com")
json.dump(c, open(p, "w"), indent=2)
PY
sleep 7
check  "a direct loosening edit is undone"          python3 -c "import json,sys; c=json.load(open('/Library/Application Support/IntentMode/config.json')); sys.exit(0 if 'reddit.com' not in next(m for m in c['modes'] if m['id']=='journal')['domains'] else 1)"
check  "turn-off can be requested"                  intentmode lockdown disable
echo "  (waiting for the 36-second delays…)"
sleep 45
check  "the pending loosening applied after its delay" test "$(python3 /tmp/im_ld.py minutes journal)" = 25
refuse "lock-down turned off after its delay"       python3 /tmp/im_ld.py active
check  "sudo rule removed"                          bash -c "! sudo test -f /etc/sudoers.d/zz-intentmode-lockdown"
check  "lock-down can be turned on again"           sudo intentmode lockdown enable --user imtest --yes
refuse "…but the one-time turn-off is used up"      python3 /tmp/im_ld.py escape
refuse "…so it can't be requested again"            intentmode lockdown disable

echo "== Lock-down: system clock jump =="
edit_cfg 'next(m for m in c["modes"] if m["id"]=="journal")["minutes"]=40'
check  "a loosening change is pending"              intentmode config propose ~/im-test-settings.json
sudo date -u "$(date -u -v+3H +%m%d%H%M%Y)" >/dev/null
echo "  (clock moved 3 hours ahead: $(date))"
sleep 8
check  "the jump was noticed"                       grep -q "system clock was changed" "$BASE/daemon.log"
check  "…and the change is still pending"           test "$(python3 /tmp/im_ld.py pending)" = 1
check  "…not applied early"                         test "$(python3 /tmp/im_ld.py minutes journal)" = 25
sudo date -u "$(date -u -v-3H +%m%d%H%M%Y)" >/dev/null
echo "  (clock moved back: $(date))"
sleep 3
check  "pending changes can be cancelled"           python3 /tmp/im_ld.py cancel_all
check  "…and the list is empty"                     test "$(python3 /tmp/im_ld.py pending)" = 0

echo "== Lock-down: update waits, then installs; rollback stays possible =="
OLDVER="$VER"
echo "9.9.9" > VERSION
check  "a newer build (9.9.9) can be built"         bash -c "bash scripts/build.sh 'ci update test' >/dev/null 2>&1"
echo "$OLDVER" > VERSION
check  "the update is accepted as pending"          intentmode update propose "$PWD/build/IntentMode-9.9.9.tar.gz"
check  "…and the old version keeps running"         bash -c "intentmode version | grep -q '^$OLDVER'"
echo "  (waiting for the 36-second delay…)"
sleep 50
check  "the update installed after its delay"       bash -c "intentmode version | grep -q '^9.9.9'"
check  "lock-down is still on after the update"     python3 /tmp/im_ld.py active
check  "sudo rule still in place"                   sudo test -f /etc/sudoers.d/zz-intentmode-lockdown
check  "rollback works during lock-down"            intentmode update rollback
sleep 12
check  "…back on $OLDVER"                           bash -c "intentmode version | grep -q '^$OLDVER'"
check  "…with lock-down still on"                   python3 /tmp/im_ld.py active

echo "== Removing the permanent install =="
sudo bash "$BASE/uninstall.sh" --yes >/dev/null 2>&1
sleep 3
refuse "daemon is gone again"                      sudo launchctl print system/com.intentmode.daemon
check  "https://example.com works after removal"   fetch https://example.com

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
