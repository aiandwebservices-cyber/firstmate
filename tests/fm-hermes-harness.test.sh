#!/usr/bin/env bash
# Behavior tests for the verified Hermes / Zeus crewmate adapter.
# Exercises the public worker binary and spawn launch resolution without
# byte-asserting whole scripts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKER="$ROOT/bin/fm-zeus-worker.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-hermes-harness)
HERMES_RUNTIME_TASK_TMP=
JQ_BIN=$(command -v jq) || fail "test needs jq"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

cleanup_hermes_harness() {
  [ -z "$HERMES_RUNTIME_TASK_TMP" ] || rm -rf "$HERMES_RUNTIME_TASK_TMP"
  rm -rf "$TMP_ROOT"
}
trap cleanup_hermes_harness EXIT

test_worker_refuses_without_hermes() {
  local err
  # Keep a minimal PATH so env/coreutils resolve, but omit any hermes binary.
  err=$(PATH="/usr/bin:/bin" env -u DEEPSEEK_API_KEY -u OPENROUTER_API_KEY \
    "$WORKER" 2>&1) && fail "worker should refuse when hermes is missing"
  printf '%s' "$err" | grep -Fq 'hermes executable not found' \
    || fail "missing hermes should mention hermes executable: $err"
  pass "fm-zeus-worker refuses when hermes is not on PATH"
}

test_worker_refuses_without_keys() {
  local dir fakebin err
  dir="$TMP_ROOT/no-keys"; mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  printf '#!/bin/sh\necho should-not-run\n' > "$fakebin/hermes"
  chmod +x "$fakebin/hermes"
  err=$(PATH="$fakebin:$BASE_PATH" env -u DEEPSEEK_API_KEY -u OPENROUTER_API_KEY \
    "$WORKER" 2>&1) && fail "worker should refuse without API keys"
  printf '%s' "$err" | grep -Fq 'DEEPSEEK_API_KEY' \
    || fail "missing keys should mention DEEPSEEK_API_KEY: $err"
  pass "fm-zeus-worker refuses without DeepSeek or OpenRouter keys"
}

test_worker_deepseek_default_launch() {
  local dir fakebin out
  dir="$TMP_ROOT/deepseek"; mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  printf '#!/bin/sh\nprintf "%%s\\n" "$*"\n' > "$fakebin/hermes"
  chmod +x "$fakebin/hermes"
  out=$(PATH="$fakebin:$BASE_PATH" DEEPSEEK_API_KEY=test-key \
    env -u OPENROUTER_API_KEY "$WORKER" 2>/dev/null)
  printf '%s' "$out" | grep -Fq -- 'chat --yolo --accept-hooks --cli -m deepseek-v4-flash --provider deepseek' \
    || fail "deepseek default launch wrong: $out"
  pass "fm-zeus-worker launches hermes chat with Zeus deepseek defaults"
}

test_worker_openrouter_fallback() {
  local dir fakebin out err
  dir="$TMP_ROOT/openrouter"; mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  printf '#!/bin/sh\nprintf "%%s\\n" "$*"\n' > "$fakebin/hermes"
  chmod +x "$fakebin/hermes"
  out=$(PATH="$fakebin:$BASE_PATH" OPENROUTER_API_KEY=or-key \
    env -u DEEPSEEK_API_KEY "$WORKER" 2>"$dir/err")
  err=$(cat "$dir/err")
  printf '%s' "$out" | grep -Fq -- 'chat --yolo --accept-hooks --cli -m deepseek/deepseek-v4-flash --provider openrouter' \
    || fail "openrouter fallback launch wrong: $out"
  printf '%s' "$err" | grep -Fq 'falling back to OpenRouter' \
    || fail "openrouter fallback should warn once on stderr: $err"
  pass "fm-zeus-worker falls back to OpenRouter with a loud stderr notice"
}

test_worker_model_override() {
  local dir fakebin out
  dir="$TMP_ROOT/model-override"; mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  printf '#!/bin/sh\nprintf "%%s\\n" "$*"\n' > "$fakebin/hermes"
  chmod +x "$fakebin/hermes"
  out=$(PATH="$fakebin:$BASE_PATH" DEEPSEEK_API_KEY=test-key \
    "$WORKER" --model deepseek-v4-pro 2>/dev/null)
  printf '%s' "$out" | grep -Fq -- '-m deepseek-v4-pro --provider deepseek' \
    || fail "model override wrong: $out"
  pass "fm-zeus-worker honors --model override with DeepSeek provider"
}

# --- fm-spawn against a fake tmux -------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_HERMES_STATE" 2>/dev/null || true)
# Hermes classic REPL: welcome banner, YOLO footer, bordered ❯ composer.
fake_screen() {
  case "$state" in
    ready)
      printf 'Welcome to Hermes Agent!\n⚠ YOLO\n╭────────────────────────────────╮\n│ ❯                              │\n╰────────────────────────────────╯\n'
      ;;
    pointer-typed)
      printf '⚠ YOLO\n╭────────────────────────────────╮\n│ ❯ Read the brief and follow it │\n│                                │\n╰────────────────────────────────╯\n'
      ;;
    delivered)
      printf '❯ Read the brief at %s and follow it exactly.\n⚠ YOLO\n╭────────────────────────────────╮\n│ ❯                              │\n╰────────────────────────────────╯\n' "$FM_FAKE_BRIEF_REAL"
      ;;
    shell-prompt)
      # The worker exited; the pane fell back to a shell whose prompt glyph is ❯.
      printf 'fm-zeus-worker: error\n❯\n'
      ;;
    *)
      printf 'shell starting\n$ \n'
      ;;
  esac
}
fake_cursor_y() {
  case "$state" in
    ready|delivered) printf '3\n' ;;
    pointer-typed) printf '3\n' ;;
    shell-prompt) printf '1\n' ;;
    *) printf '1\n' ;;
  esac
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) fake_cursor_y; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        *fm-zeus-worker.sh*)
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf '%s\n' "${FM_FAKE_HERMES_LAUNCHED_STATE:-launched}" > "$FM_FAKE_HERMES_STATE"
          ;;
        export\ GOTMPDIR=*|treehouse*) ;;
        *)
          printf '%s\n' "$literal" >> "$FM_FAKE_POINTER_LOG"
          printf 'pointer-typed\n' > "$FM_FAKE_HERMES_STATE"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launched)
            if [ "${FM_FAKE_HERMES_READY:-yes}" = yes ]; then
              printf 'ready\n' > "$FM_FAKE_HERMES_STATE"
            fi
            ;;
          pointer-typed)
            case "${FM_FAKE_HERMES_DELIVERY:-yes}" in
              yes) printf 'delivered\n' > "$FM_FAKE_HERMES_STATE" ;;
              swallowed) ;;
              *) printf 'ready\n' > "$FM_FAKE_HERMES_STATE" ;;
            esac
            ;;
        esac
        ;;
    esac
    exit 0
    ;;
  capture-pane)
    start= end= prev=
    for arg in "$@"; do
      case "$prev" in
        -S) start=$arg ;;
        -E) end=$arg ;;
      esac
      case "$arg" in -S|-E) prev=$arg ;; *) prev= ;; esac
    done
    case "$start:$end" in
      *[!0-9:]*|'':*|*:'') fake_screen ;;
      *) fake_screen | awk -v start="$start" -v end="$end" \
           'NR - 1 >= start && NR - 1 <= end' ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh hermes
  ln -s "$JQ_BIN" "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief for hermes\n' > "$home/data/$id/brief.md"
  printf 'zeus\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/pointer.log"
  : > "$case_dir/hermes.state"
  : > "$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6 harness=$7
  shift 7
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_POINTER_LOG="$case_dir/pointer.log" \
    FM_FAKE_HERMES_STATE="$case_dir/hermes.state" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_BRIEF_REAL="$(cd "$home/data/$id" && pwd -P)/brief.md" \
    FM_HERMES_READY_POLLS=2 FM_HERMES_DELIVERY_POLLS=2 FM_HERMES_POLL_INTERVAL=0 \
    FM_HERMES_SUBMIT_RETRIES=2 FM_HERMES_SUBMIT_SLEEP=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness "$harness" "$@" 2>&1
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

test_spawn_launches_zeus_worker_with_model_and_no_effort_flag() {
  local id rec out rc launch pointer brief_real meta task_tmp
  id="hermes-success-z1-$$"
  task_tmp="/tmp/fm-$id"
  HERMES_RUNTIME_TASK_TMP=$task_tmp
  rm -rf "$task_tmp"
  rec=$(make_spawn_case success "$id")
  read_spawn_record "$rec"
  out=$(DEEPSEEK_API_KEY=ds-test-key run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" zeus \
    --model deepseek-v4-pro --effort high)
  rc=$?
  expect_code 0 "$rc" "verified hermes/zeus launch-then-send should succeed"
  assert_contains "$out" "spawned $id harness=zeus" "zeus spawn did not report success"

  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "$ROOT/bin/fm-zeus-worker.sh" \
    "zeus launch did not run the Zeus worker (hermes chat flags are the worker's own, covered above)"
  assert_contains "$launch" "--model 'deepseek-v4-pro'" "zeus launch lost the requested model"
  assert_contains "$launch" "DEEPSEEK_API_KEY=" \
    "zeus launch did not forward a key the pane cannot inherit"
  assert_not_contains "$launch" "--effort" "zeus launch emitted a nonexistent effort flag"
  assert_not_contains "$launch" "__ZEUSWORKER__" "zeus launch retained its worker placeholder"
  assert_not_contains "$launch" "__MODELFLAG__" "zeus launch retained its model placeholder"

  brief_real="$(cd "$HOME_DIR/data/$id" && pwd -P)/brief.md"
  pointer=$(cat "$CASE_DIR/pointer.log")
  [ "$pointer" = "Read the brief at $brief_real and follow it exactly." ] \
    || fail "zeus pointer was not the exact absolute-path-only instruction: $pointer"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'harness=zeus' "$meta" "zeus meta did not record its own harness name"
  assert_grep 'effort=high' "$meta" "zeus meta did not retain the unsupported effort axis"
  pass "fm-spawn: zeus launches the Zeus worker, forwards its key, and delivers the brief"
}

test_spawn_records_hermes_harness_name() {
  local id rec out rc launch
  id="hermes-name-z2-$$"
  rec=$(make_spawn_case harness-name "$id")
  read_spawn_record "$rec"
  out=$(unset DEEPSEEK_API_KEY; OPENROUTER_API_KEY=or-test-key run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" hermes)
  rc=$?
  expect_code 0 "$rc" "hermes spawn should succeed on the same template"
  assert_contains "$out" "spawned $id harness=hermes" "hermes spawn did not report its own name"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "$ROOT/bin/fm-zeus-worker.sh" "hermes launch did not run the Zeus worker"
  assert_contains "$launch" "OPENROUTER_API_KEY=" "hermes launch did not forward the fallback key"
  assert_grep 'harness=hermes' "$HOME_DIR/state/$id.meta" "hermes meta collapsed into zeus"
  pass "fm-spawn: hermes and zeus share one template and each records its own harness"
}

test_spawn_refuses_without_any_zeus_key() {
  local id rec out rc
  id="hermes-nokey-z3-$$"
  rec=$(make_spawn_case no-key "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(unset DEEPSEEK_API_KEY OPENROUTER_API_KEY; run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" zeus) || rc=$?
  [ "$rc" -ne 0 ] || fail "keyless hermes/zeus spawn should refuse"
  assert_contains "$out" "DEEPSEEK_API_KEY" "keyless refusal did not name the required key"
  if grep -Eq '(^| )new-(session|window)( |$)' "$CASE_DIR/tmux-calls.log"; then
    fail "keyless hermes/zeus refusal created a tmux container or pane"
  fi
  pass "fm-spawn: hermes/zeus refuses before launch when no Zeus key can reach the pane"
}

test_spawn_never_treats_a_shell_prompt_as_ready() {
  local id rec out rc
  id="hermes-shell-z4-$$"
  rec=$(make_spawn_case shell-prompt "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(DEEPSEEK_API_KEY=ds-test-key FM_FAKE_HERMES_LAUNCHED_STATE=shell-prompt run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" zeus) || rc=$?
  [ "$rc" -ne 0 ] || fail "a bare ❯ shell prompt must not pass the hermes readiness gate"
  assert_contains "$out" "did not show a verified ready signal" \
    "shell-prompt readiness failure lacked a loud diagnostic"
  [ ! -s "$CASE_DIR/pointer.log" ] || fail "hermes pointer was typed into a dead shell"
  pass "fm-spawn: hermes readiness rejects a shell whose prompt glyph is ❯"
}

test_spawn_rejects_a_swallowed_submit() {
  local id rec out rc
  id="hermes-swallow-z5-$$"
  rec=$(make_spawn_case swallowed "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(DEEPSEEK_API_KEY=ds-test-key FM_FAKE_HERMES_DELIVERY=swallowed run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" zeus) || rc=$?
  [ "$rc" -ne 0 ] || fail "a pointer left unsubmitted in the composer must fail the spawn"
  assert_contains "$out" "composer verdict: pending" \
    "swallowed submit did not report the proof-carrying verdict"
  assert_grep 'failed: hermes/zeus brief pointer could not be submitted' \
    "$HOME_DIR/state/$id.status" \
    "swallowed submit did not leave a supervisor-visible failure"
  pass "fm-spawn: hermes rejects a swallowed Enter instead of confirming its own echoed text"
}

test_spawn_unconfirmed_delivery_fails_loudly() {
  local id rec out rc
  id="hermes-drop-z6-$$"
  rec=$(make_spawn_case drop "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(DEEPSEEK_API_KEY=ds-test-key FM_FAKE_HERMES_DELIVERY=no run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" zeus) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unconfirmed hermes delivery should fail"
  assert_contains "$out" "hermes/zeus brief pointer delivery was not confirmed" \
    "unconfirmed hermes delivery lacked a loud diagnostic"
  pass "fm-spawn: hermes treats a silent pointer drop as a failed spawn"
}

test_harness_detection_ancestry_hermes() {
  local dir fakebin cfg out
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-session-lock-lib.sh"
  printf '%s' hermes | grep -qE "$FM_HARNESS_RE" \
    || fail "FM_HARNESS_RE should match hermes"
  # fm-zeus-worker.sh execs into hermes, so the live command name is the agent's.
  printf '%s' hermes-agent | grep -qE "$FM_HARNESS_RE" \
    || fail "FM_HARNESS_RE should match the hermes-agent exec target"

  dir="$TMP_ROOT/detection"
  fakebin=$(fm_fakebin "$dir")
  cfg="$dir/config"
  mkdir -p "$cfg"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=
pid=
prev=
for arg in "$@"; do
  [ "$prev" = -o ] && field=$arg
  [ "$prev" = -p ] && pid=$arg
  prev=$arg
done
case "$field:$pid" in
  comm=:4242) printf '/home/u/.hermes/hermes-agent\n' ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:4242) printf '1\n' ;;
  ppid=:*) printf '4242\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = hermes ] || fail "hermes ancestry detection returned '$out'"
  pass "harness identity: hermes is matched by its exec-target command name everywhere"
}

test_tmux_backend_reads_hermes_pane_alive() {
  local dir fakebin out
  dir="$TMP_ROOT/agent-state"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_command}"*) printf 'hermes-agent\n'; exit 0 ;;
  list-windows*) printf 'fm-hermes\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  out=$(PATH="$fakebin:$BASE_PATH" FM_BACKEND_LIB_DIR="$ROOT/bin" bash -c '
    . "$1/bin/backends/tmux.sh"
    fm_backend_tmux_agent_state firstmate:fm-hermes
  ' _ "$ROOT")
  [ "$out" = alive ] || fail "a live hermes pane must classify alive, got '$out'"
  pass "tmux backend: a live hermes worker pane classifies alive"
}

test_worker_refuses_without_hermes
test_worker_refuses_without_keys
test_worker_deepseek_default_launch
test_worker_openrouter_fallback
test_worker_model_override
test_spawn_launches_zeus_worker_with_model_and_no_effort_flag
test_spawn_records_hermes_harness_name
test_spawn_refuses_without_any_zeus_key
test_spawn_never_treats_a_shell_prompt_as_ready
test_spawn_rejects_a_swallowed_submit
test_spawn_unconfirmed_delivery_fails_loudly
test_harness_detection_ancestry_hermes
test_tmux_backend_reads_hermes_pane_alive

echo "all fm-hermes-harness tests passed"
