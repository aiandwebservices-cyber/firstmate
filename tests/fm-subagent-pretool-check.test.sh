#!/usr/bin/env bash
# Behavior tests for the primary-session delegation-shape guard.
# Current posture (2026-08-12): the deny is disabled and the tracked hook is
# unregistered. These tests pin that allow-all behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-subagent-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-subagent-pretool-tests)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

mkdir -p "$PRIMARY/bin" "$STATE"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q

# Representative names from the disabled classifier's old inventory.
DELEGATION_TOOLS='Task Agent Workflow RemoteTrigger Monitor ScheduleWakeup SendMessage EnterWorktree ExitWorktree CronCreate CronDelete CronList TaskCreate TaskGet TaskList TaskUpdate TaskStop TaskOutput'
PRESERVED_TOOLS='Bash Edit Read Write Skill ToolSearch WebFetch WebSearch NotebookEdit ReportFindings DesignSync PushNotification'

run_tool() {
  local tool=$1 rc=0
  shift
  : > "$OUT"
  : > "$ERR"
  env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" "$@" \
    "$CHECK" --claude --tool "$tool" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

expect_allow() {
  local label=$1 tool=$2 rc=0
  shift 2
  run_tool "$tool" "$@" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label ($tool) must allow, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$label ($tool) allow wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label ($tool) allow wrote stderr: $(cat "$ERR")"
}

expect_deny() {
  local label=$1 tool=$2 rc=0
  run_tool "$tool" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label ($tool) must deny with exit 2, got $rc"
  [ ! -s "$OUT" ] || fail "$label ($tool) deny wrote stdout: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "$label ($tool) deny omitted Claude's permission decision: $(cat "$ERR")"
  jq -e --arg tool "$tool" '.systemMessage | startswith("[subagent-dispatch]") and contains("blocked tool: " + $tool)' "$ERR" >/dev/null 2>&1 \
    || fail "$label ($tool) deny message lost its code or tool name: $(jq -r '.systemMessage' "$ERR")"
}

# ---------------------------------------------------------------------------
# Current posture (2026-08-12): the deny is disabled. The script always allows
# so harness Task / spawn_subagent / workflow can run. Fleet dispatch through
# fm-spawn remains preferred. The old classifier stays in the file unused.
# ---------------------------------------------------------------------------

test_disabled_guard_allows_delegation_and_ordinary_tools() {
  local tool
  for tool in $DELEGATION_TOOLS $PRESERVED_TOOLS \
              SubagentCreate SpawnWorker DelegateTask AgentPool WorkflowRun \
              TaskCreateAgent RemoteExec; do
    expect_allow "disabled guard" "$tool"
  done
  pass "the disabled guard allows delegation-shaped and ordinary tools"
}

test_disabled_guard_allows_both_stdin_transports() {
  local rc=0
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"tool_name":"Agent","tool_input":{"prompt":"go"}}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "Claude-shaped stdin must allow while the guard is disabled, got exit $rc"
  [ ! -s "$OUT" ] || fail "disabled allow wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "disabled allow wrote stderr: $(cat "$ERR")"

  rc=0
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"toolName":"Agent"}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "Grok-shaped stdin must allow while the guard is disabled, got exit $rc"
  [ ! -s "$OUT" ] || fail "disabled grok allow wrote stdout: $(cat "$OUT")"
  pass "both stdin transports allow while the guard is disabled"
}

test_tracked_settings_do_not_register_the_disabled_hook() {
  assert_no_grep "fm-subagent-pretool-check.sh" "$ROOT/.claude/settings.json" \
    "tracked Claude settings must not register the disabled subagent hook"
  pass "tracked settings omit the disabled subagent PreToolUse hook"
}

test_enable_env_restores_deny() {
  local rc=0
  : > "$OUT"
  : > "$ERR"
  env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    FM_SUBAGENT_GUARD_ENABLE=1 \
    "$CHECK" --claude --tool Agent > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "FM_SUBAGENT_GUARD_ENABLE=1 must deny Agent, got exit $rc"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "restored deny omitted Claude permission decision: $(cat "$ERR")"
  pass "FM_SUBAGENT_GUARD_ENABLE=1 restores the deny"
}

test_disabled_guard_allows_delegation_and_ordinary_tools
test_disabled_guard_allows_both_stdin_transports
test_tracked_settings_do_not_register_the_disabled_hook
test_enable_env_restores_deny
