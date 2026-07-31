#!/usr/bin/env bash
# Behavior tests for the generic process-to-event runner and its Lavish adapter.
#
# The source under test is a fake blocking process that returns only when its
# trigger file appears, so completion is a real process event and no test here
# depends on a discovery timer. The Lavish adapter is exercised through its own
# public commands against the currently published poll shape; no live Lavish
# server is started.
#
# Delivery is deliberately NOT asserted as at-least-once or lossless: the
# published Lavish poll clears feedback destructively before returning it, so
# the only durability under test is the runner's own - output that reached the
# runner is stored before it is announced.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-tests)
# fm_test_tmproot runs inside a command substitution, whose EXIT trap removes the
# directory it just registered, so recreate it before writing anything into it.
mkdir -p "$TMP_ROOT"
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

BLOCKER="$TMP_ROOT/blocker.sh"
cat > "$BLOCKER" <<'SH'
#!/usr/bin/env bash
# Blocks until the trigger exists, then emits its payload. Completion is the
# event; nothing here polls on a schedule.
trigger=$1; shift
while [ ! -e "$trigger" ]; do sleep 0.05; done
[ -n "${BLOCKER_STDERR:-}" ] && printf 'noise on stderr\n' >&2
[ -n "${BLOCKER_EXIT:-}" ] && exit "$BLOCKER_EXIT"
printf '%s\n' "$@"
SH
chmod +x "$BLOCKER"

pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }

# Every source this suite registers is tracked so teardown can stop its runner.
# A runner started by reconcile is detached and reparented, so a source that
# never completes outlives the suite unless it is retired explicitly - removing
# the fixture directory does not stop an already-running child.
PE_TRACKED=()
pe_register() {  # <home> <adapter> <source-id> -- <argv>...
  local home=$1 adapter=$2 id=$3
  shift 3
  PE_TRACKED+=("$home|$id")
  pe "$home" register "$adapter" "$id" "$@"
}

procevent_teardown() {
  local entry home id
  for entry in ${PE_TRACKED[@]+"${PE_TRACKED[@]}"}; do
    home=${entry%%|*}; id=${entry#*|}
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" retire "$id" >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap procevent_teardown EXIT
new_home() { mkdir -p "$1/state"; }
wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }

first_result() {  # <home> <source-id>: print the first captured result, if any
  local g
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] || continue
    printf '%s\n' "$g"
    return 0
  done
  return 1
}

count_results() {  # <home> <source-id>
  local g n=0
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

wait_for() {  # <file> [tries]
  local f=$1 n=${2:-100}
  for _ in $(seq 1 "$n"); do [ -s "$f" ] && return 0; sleep 0.1; done
  return 1
}

# --- inert with nothing configured ------------------------------------------
IDLE="$TMP_ROOT/idle"; new_home "$IDLE"
out=$(pe "$IDLE" list)
assert_contains "$out" "no sources registered" "an unconfigured home reports no sources"
out=$(pe "$IDLE" reconcile)
assert_contains "$out" "published=0 started=0" "reconcile is a no-op with nothing registered"
[ -z "$(ls -A "$IDLE/state" 2>/dev/null)" ] || fail "an unconfigured home generated state: $(ls -A "$IDLE/state")"
pass "no configured source means no generated state and no process"

sup=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2" && echo yes || echo no' _ "$ROOT" "$IDLE/state")
assert_contains "$sup" no "an unconfigured home does not need supervision"

# --- a blocking source completes into exactly one normalized event ----------
H1="$TMP_ROOT/h1"; new_home "$H1"
TRIG="$TMP_ROOT/trigger-one"
out=$(pe_register "$H1" lavish src-one -- "$BLOCKER" "$TRIG" "payload one")
assert_contains "$out" "registered: src-one" "register records a source"

sup=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2" && echo yes || echo no' _ "$ROOT" "$H1/state")
assert_contains "$sup" yes "a registered source needs supervision with no task metadata"

pe "$H1" reconcile >/dev/null
sleep 0.5
out=$(pe "$H1" start src-one)
assert_contains "$out" "already owned" "a duplicate start loses instead of running a second child"

: > "$TRIG"
wait_for "$H1/state/.wake-queue" || fail "no event was published after the source completed"
payload=$(wake_payloads "$H1")
assert_contains "$payload" "procevent lavish src-one" "completion publishes one normalized event"
assert_not_contains "$payload" "payload one" "source output never reaches the event line"
[ "$(printf '%s\n' "$payload" | grep -c .)" = 1 ] || fail "expected exactly one event, got: $payload"
pass "one blocking completion yields exactly one bounded normalized event"

RESULT=$(first_result "$H1" src-one || true)
[ -n "$RESULT" ] || fail "no durable result was captured"
mode=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_mode "$2"' _ "$ROOT" "$RESULT")
assert_contains "$mode" 600 "the captured result is private"
assert_grep 'payload one' "$RESULT" "the captured result holds the source output verbatim"
assert_present "${RESULT%.result}.announced" "a published result is marked announced"

# --- restart between durable capture and handling re-announces --------------
# Simulate the crash cut: the result is durable but its announcement never
# landed. Recovery must re-announce it without a second durable copy.
H2="$TMP_ROOT/h2"; new_home "$H2"
mkdir -p "$H2/state/procevent-inbox" "$H2/state/procevent"
printf 'adapter=lavish\nargc=1\nargv:\n/bin/true\n' > "$H2/state/procevent/src-cut.source"
chmod 0600 "$H2/state/procevent/src-cut.source"
printf 'stranded result\n' > "$H2/state/procevent-inbox/src-cut.7.result"
chmod 0600 "$H2/state/procevent-inbox/src-cut.7.result"
out=$(pe "$H2" reconcile)
assert_contains "$out" "published=1" "a durably captured but unannounced result is re-announced after restart"
assert_present "$H2/state/procevent-inbox/src-cut.7.announced" "recovery marks the recovered result"
before=$(wc -l < "$H2/state/.wake-queue")
out=$(pe "$H2" reconcile)
assert_contains "$out" "published=0" "an already-announced result is not announced twice"
[ "$(wc -l < "$H2/state/.wake-queue")" = "$before" ] || fail "recovery duplicated the handled effect"
[ "$(count_results "$H2" src-cut)" = 1 ] || fail "recovery created a second durable copy"
pass "restart recovery re-announces once without duplicating the handled effect"

# --- two homes cannot both own one canonical source -------------------------
HA="$TMP_ROOT/ha"; HB="$TMP_ROOT/hb"; new_home "$HA"; new_home "$HB"
TRIG2="$TMP_ROOT/trigger-two"
pe_register "$HA" lavish shared-src -- "$BLOCKER" "$TRIG2" "shared" >/dev/null
pe_register "$HB" lavish shared-src -- "$BLOCKER" "$TRIG2" "shared" >/dev/null
pe "$HA" reconcile >/dev/null
sleep 0.5
out=$(pe "$HB" start shared-src)
assert_contains "$out" "already owned" "a second home cannot own a source another home already owns"
[ -z "$(wake_payloads "$HB")" ] || fail "the losing home published an event"
pass "one owner per canonical source across homes"

# A source whose child never completes must not survive retirement. This is the
# leak that reparented four orphaned runners: the fixture directory was removed
# while the detached child kept blocking, with nothing left to reap it.
runner_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/shared-src.claim" 2>/dev/null)
[ -n "$runner_pid" ] || fail "no runner pid recorded for the blocked source"
kill -0 "$runner_pid" 2>/dev/null || fail "the blocked runner is not live before retirement"
pe "$HA" retire shared-src >/dev/null
for _ in $(seq 1 40); do kill -0 "$runner_pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$runner_pid" 2>/dev/null && fail "retire left the blocked runner alive"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/shared-src.claim" "retire releases the claim"
pass "retiring a never-completing source stops its runner and its blocked child"

# reconcile must also stop a runner whose registration was removed out from under it.
TRIG4="$TMP_ROOT/trigger-four"
HZ="$TMP_ROOT/hz"; new_home "$HZ"
pe_register "$HZ" lavish orphan-src -- "$BLOCKER" "$TRIG4" "orphan" >/dev/null
pe "$HZ" reconcile >/dev/null
sleep 0.5
orphan_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/orphan-src.claim" 2>/dev/null)
if [ -z "$orphan_pid" ] || ! kill -0 "$orphan_pid" 2>/dev/null; then
  fail "orphan fixture runner did not start"
fi
rm -f "$HZ/state/procevent/orphan-src.source"
out=$(pe "$HZ" reconcile)
assert_contains "$out" "stopped=1" "reconcile stops a runner whose registration was removed"
for _ in $(seq 1 40); do kill -0 "$orphan_pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$orphan_pid" 2>/dev/null && fail "reconcile left an orphaned runner alive"
pass "reconcile reaps a runner whose source registration is gone"

# --- a stale claim is reclaimable, a live one is not ------------------------
CLAIM="$FM_PROCEVENT_CLAIM_ROOT/stale-src.claim"
mkdir -p "$FM_PROCEVENT_CLAIM_ROOT"
printf '%s\n%s\n' "$TMP_ROOT/gone-home" "999999" > "$CLAIM"
chmod 0600 "$CLAIM"
HC="$TMP_ROOT/hc"; new_home "$HC"
pe_register "$HC" lavish stale-src -- /bin/echo recovered >/dev/null
out=$(pe "$HC" start stale-src)
assert_contains "$out" "captured:" "a claim whose runner is gone is reclaimable"
owner=$(head -1 "$CLAIM" 2>/dev/null || true)
[ "$owner" != "$TMP_ROOT/gone-home" ] || fail "the stale owner was not replaced"
pass "stale-owner recovery works and cannot displace a live owner"

HR="$TMP_ROOT/hr"; new_home "$HR"
RACE_TRIGGER="$TMP_ROOT/race-trigger"
RACE_LOG="$TMP_ROOT/race-executions"
RACE_BLOCKER="$TMP_ROOT/race-blocker.sh"
cat > "$RACE_BLOCKER" <<'SH'
#!/usr/bin/env bash
printf 'started\n' >> "$1"
while [ ! -e "$2" ]; do sleep 0.05; done
printf 'race result\n'
SH
chmod +x "$RACE_BLOCKER"
pe_register "$HR" lavish race-src -- "$RACE_BLOCKER" "$RACE_LOG" "$RACE_TRIGGER" >/dev/null
printf '%s\n%s\nold-token\nold-identity\n' "$TMP_ROOT/gone-home" 999999 > "$FM_PROCEVENT_CLAIM_ROOT/race-src.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/race-src.claim"
race_pids=()
for _ in $(seq 1 24); do
  pe "$HR" start race-src >/dev/null &
  race_pids+=("$!")
done
wait_for "$RACE_LOG" || fail "no contender acquired the stale claim"
sleep 0.5
[ "$(wc -l < "$RACE_LOG" | tr -d ' ')" = 1 ] || fail "stale-claim race started more than one runner"
: > "$RACE_TRIGGER"
for race_pid in "${race_pids[@]}"; do wait "$race_pid" 2>/dev/null || true; done
pass "concurrent stale-claim replacement starts exactly one runner"

HI="$TMP_ROOT/hi"; new_home "$HI"
pe_register "$HI" lavish reused-src -- /bin/true >/dev/null
sleep 60 &
innocent_pid=$!
printf '%s\n%s\nreused-token\nnot-the-live-process-identity\n' \
  "$HI" "$innocent_pid" > "$FM_PROCEVENT_CLAIM_ROOT/reused-src.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/reused-src.claim"
pe "$HI" retire reused-src >/dev/null
kill -0 "$innocent_pid" 2>/dev/null || fail "retirement signaled a PID whose identity did not match the claim"
kill "$innocent_pid" 2>/dev/null || true
wait "$innocent_pid" 2>/dev/null || true
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/reused-src.claim" "retirement releases the exact reused-pid claim"
pass "PID reuse cannot signal an unrelated process"

# --- argv boundaries, stderr, exit status, bounds, malformed output ---------
HD="$TMP_ROOT/hd"; new_home "$HD"
TRIG3="$TMP_ROOT/trigger-three"
pe_register "$HD" lavish argv-src -- "$BLOCKER" "$TRIG3" "one arg with spaces" "second; rm -rf /tmp/nope" >/dev/null
pe "$HD" reconcile >/dev/null
: > "$TRIG3"
wait_for "$HD/state/.wake-queue" || fail "argv source published no event"
R=$(first_result "$HD" argv-src || true)
assert_grep 'one arg with spaces' "$R" "an argument containing spaces survives as one argument"
assert_grep 'second; rm -rf /tmp/nope' "$R" "a shell-looking argument is passed literally, never interpreted"
assert_absent /tmp/nope "no shell interpretation occurred"
assert_not_contains "$(wake_payloads "$HD")" "rm -rf" "argv content never reaches the event line"

HE="$TMP_ROOT/he"; new_home "$HE"
pe_register "$HE" lavish fail-src -- /bin/sh -c 'exit 7' >/dev/null
out=$(pe "$HE" start fail-src)
assert_contains "$out" "no-result" "a failing source with no output publishes nothing"
[ -z "$(wake_payloads "$HE")" ] || fail "a failing source published an event"
assert_present "$HE/state/procevent/fail-src.source" "a failing source stays registered for retry"
pass "nonzero exit with no output stays armed and silent"

HF="$TMP_ROOT/hf"; new_home "$HF"
# shellcheck disable=SC2016  # single quotes are deliberate: the child shell expands this.
pe_register "$HF" lavish big-src -- /bin/sh -c 'printf "x%.0s" $(seq 1 5000)' >/dev/null
FM_PROCEVENT_MAX_OUTPUT_BYTES=100 FM_HOME="$HF" "$ROOT/bin/fm-procevent.sh" start big-src >/dev/null 2>&1
RB=$(first_result "$HF" big-src || true)
[ -n "$RB" ] || fail "bounded output was not captured at all"
[ "$(wc -c < "$RB" | tr -d ' ')" -le 100 ] || fail "output bound was not enforced"
pass "oversized output is bounded rather than published whole or dropped"

# --- the Lavish adapter uses the published poll shape -----------------------
ART="$TMP_ROOT/artifact.html"
printf '<h1>fixture</h1>\n' > "$ART"
sid=$(FM_HOME="$TMP_ROOT/hg" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART")
case "$sid" in lavish-*) : ;; *) fail "adapter source id has an unexpected shape: $sid" ;; esac
sid2=$(FM_HOME="$TMP_ROOT/hg" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART")
[ "$sid" = "$sid2" ] || fail "adapter source id is not stable"
ART_ALIAS="$TMP_ROOT/artifact-alias.html"
ln -s "$ART" "$ART_ALIAS"
sid3=$(FM_HOME="$TMP_ROOT/hg" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART_ALIAS")
[ "$sid" = "$sid3" ] || fail "a final-component symlink produced a second source id"
pass "the adapter derives a stable physical source id"

HS="$TMP_ROOT/hs"; new_home "$HS"
mkdir -p "$HS/state/procevent"
: > "$HS/state/procevent/source-only.source"
guard_out=$(FM_ROOT_OVERRIDE="$TMP_ROOT/guard-root" FM_HOME="$HS" FM_GUARD_GRACE=1 \
  "$ROOT/bin/fm-guard.sh" 2>&1)
assert_contains "$guard_out" "WATCHER DOWN - SUPERVISION IS OFF" \
  "the general guard warns when only a process-event source needs supervision"
assert_contains "$guard_out" "1 process-event source(s) registered" \
  "the general guard identifies the source-only supervision need"
pass "source-only homes trigger the general supervision guard"

CLS="$TMP_ROOT/cls"
printf 'session:\n  file: /a.html\n  status: feedback\nprompts[1]{uid}:\n  p1\n' > "$CLS"
out=$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS")
assert_contains "$out" feedback "the adapter reads the indented session status"
printf 'session:\n  file: /a.html\n  status: ended\n' > "$CLS"
assert_contains "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS")" ended "an ended session classifies as ended"
printf 'error: No active Lavish Editor session for this file\ncode: NOT_FOUND\n' > "$CLS"
assert_contains "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS")" missing "an explicit missing session classifies as missing"
printf 'garbage that is not a session block\n' > "$CLS"
assert_contains "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS")" unknown "malformed output classifies as unknown rather than a lifecycle state"
pass "the adapter classifies published poll output safely"

# --- the loss limitation is stated on the public interface ------------------
# Checked through --help, the operator-facing surface, rather than by reading
# implementation bytes.
adapter_help=$("$ROOT/bin/fm-procevent-lavish.sh" --help 2>&1 || true)
assert_contains "$adapter_help" "destructively clears" \
  "the adapter's help states the destructive-source loss limitation"
assert_contains "$adapter_help" "Never describe" \
  "the adapter's help forbids an at-least-once or lossless description"

runner_help=$("$ROOT/bin/fm-procevent.sh" --help 2>&1 || true)
assert_contains "$runner_help" "Durability boundary" \
  "the runner's help scopes what it actually proves"
assert_not_contains "$runner_help" "exactly-once" \
  "the runner's help claims no exactly-once delivery"
pass "the published interfaces state the loss limitation and claim no lossless delivery"

printf '\nall procevent tests passed\n'
