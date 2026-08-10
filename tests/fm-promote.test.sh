#!/usr/bin/env bash
# Behavior tests for bin/fm-promote.sh role handling.
#
# Promotion turns a scout task into a ship task in place: kind= flips scout -> ship
# and, per ADLC's Implementation-stage mapping (docs/adlc-standard.md, agent-roles
# skill), role= flips to builder so the recorded contract matches the ship
# instructions the worker is about to receive. Without the role flip a promoted
# researcher-scout would carry a role=builder meta but a loaded brief that still
# says "never edit project files" - a direct contract conflict.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-promote)
PROMOTE="$ROOT/bin/fm-promote.sh"

test_promote_flips_kind_and_role() {
  local home meta out status
  home="$TMP_ROOT/flip-home"
  mkdir -p "$home/state"
  meta="$home/state/research-task.meta"
  fm_write_meta "$meta" \
    "window=firstmate:research-task" \
    "endpoint_task_id=research-task" \
    "worktree=$home/wt" \
    "project=$home/proj" \
    "harness=claude" \
    "kind=scout" \
    "mode=no-mistakes" \
    "yolo=off" \
    "tasktmp=$home/tmp" \
    "model=default" \
    "effort=xhigh" \
    "role=researcher"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" research-task 2>&1); status=$?
  expect_code 0 "$status" "fm-promote should succeed on a scout task"
  assert_contains "$out" "promoted research-task to ship" "promote did not report the promotion"
  assert_contains "$out" "you are now the Builder" "promote next-step must tell the worker the role changed"
  assert_grep "kind=ship" "$meta" "meta still records kind=scout after promotion"
  assert_no_grep "kind=scout" "$meta" "meta retained the scout kind"
  assert_grep "role=builder" "$meta" "meta did not flip role to builder on promotion"
  assert_no_grep "role=researcher" "$meta" "meta retained the scout role after promotion"
  pass "fm-promote: flips kind=scout -> ship and role=<scout-role> -> builder"
}

test_promote_keeps_other_meta_fields() {
  local home meta
  home="$TMP_ROOT/fields-home"
  mkdir -p "$home/state"
  meta="$home/state/audit-task.meta"
  fm_write_meta "$meta" \
    "window=firstmate:audit-task" \
    "endpoint_task_id=audit-task" \
    "worktree=$home/wt" \
    "project=$home/proj" \
    "harness=grok" \
    "kind=scout" \
    "mode=direct-PR" \
    "yolo=off" \
    "tasktmp=$home/tmp" \
    "model=default" \
    "effort=high" \
    "role=architect" \
    "backend=herdr" \
    "herdr_session=default"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" audit-task >/dev/null 2>&1 \
    || fail "fm-promote should succeed on a scout task"
  assert_grep "window=firstmate:audit-task" "$meta" "promote dropped the window binding"
  assert_grep "endpoint_task_id=audit-task" "$meta" "promote dropped the endpoint binding"
  assert_grep "harness=grok" "$meta" "promote dropped the harness"
  assert_grep "mode=direct-PR" "$meta" "promote dropped the delivery mode"
  assert_grep "backend=herdr" "$meta" "promote dropped the backend"
  assert_grep "herdr_session=default" "$meta" "promote dropped the backend session binding"
  pass "fm-promote: preserves every other meta field while flipping kind and role"
}

test_promote_refuses_non_scout() {
  local home meta out status
  home="$TMP_ROOT/refuse-home"
  mkdir -p "$home/state"
  meta="$home/state/ship-task.meta"
  fm_write_meta "$meta" \
    "window=firstmate:ship-task" \
    "endpoint_task_id=ship-task" \
    "worktree=$home/wt" \
    "project=$home/proj" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "role=builder"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" ship-task 2>&1); status=$?
  expect_code 1 "$status" "fm-promote must refuse a non-scout task"
  assert_contains "$out" "not a scout task" "refusal must state the kind mismatch"
  assert_grep "kind=ship" "$meta" "refused promote must not touch the meta"
  assert_grep "role=builder" "$meta" "refused promote must not touch the role"
  pass "fm-promote: refuses ship tasks and leaves their meta untouched"
}

test_promote_guard_refuses_in_gate() {
  local home meta out status
  home="$TMP_ROOT/gate-home"
  mkdir -p "$home/state"
  meta="$home/state/gated-task.meta"
  fm_write_meta "$meta" \
    "window=firstmate:gated-task" \
    "endpoint_task_id=gated-task" \
    "worktree=$home/wt" \
    "project=$home/proj" \
    "harness=claude" \
    "kind=scout" \
    "role=researcher"
  # The no-mistakes gate-refusal environment must abort the promote just like
  # every other fleet mutation (bin/fm-gate-refuse-lib.sh). Tests normally set
  # FM_GATE_REFUSE_BYPASS in lib.sh, so clear it for this case and provide the
  # gate marker the guard checks.
  # lib.sh exports FM_GATE_REFUSE_BYPASS=1 for the whole suite; this case must
  # clear it and set the gate marker to verify real refusal (the empty-string
  # assignment form avoids the shellcheck SC1007 space-after-= warning).
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_GATE_REFUSE_BYPASS='' NO_MISTAKES_GATE=1 "$PROMOTE" gated-task 2>&1); status=$?
  expect_code 3 "$status" "fm-promote must refuse under the gate lifecycle"
  assert_grep "kind=scout" "$meta" "gate-refused promote must not touch the meta"
  assert_no_grep "role=builder" "$meta" "gate-refused promote must not flip the role"
  pass "fm-promote: refuses under the no-mistakes gate lifecycle"
}

test_promote_guard_absent_marker_allows() {
  local home meta out status
  home="$TMP_ROOT/guard-off-home"
  mkdir -p "$home/state"
  meta="$home/state/plain-task.meta"
  fm_write_meta "$meta" \
    "window=firstmate:plain-task" \
    "endpoint_task_id=plain-task" \
    "worktree=$home/wt" \
    "project=$home/proj" \
    "harness=claude" \
    "kind=scout" \
    "role=researcher"
  # A real firstmate home has no NO_MISTAKES_GATE marker, so promotion must pass
  # there even though lib.sh normally exports FM_GATE_REFUSE_BYPASS globally.
  # An empty-but-set NO_MISTAKES_GATE still counts as the marker (presence is
  # the signal, per fm-gate-refuse-lib.sh), so unset it rather than emptying it.
  out=$(env -u NO_MISTAKES_GATE FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_GATE_REFUSE_BYPASS='' "$PROMOTE" plain-task 2>&1); status=$?
  expect_code 0 "$status" "fm-promote must succeed without the gate marker"
  assert_grep "kind=ship" "$meta" "promote did not flip kind without the gate marker"
  assert_grep "role=builder" "$meta" "promote did not flip role without the gate marker"
  pass "fm-promote: succeeds when no gate marker is present"
}

test_promote_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-promote.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-promote.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-promote.sh emitted unexpected output: $out"
  pass "fm-promote.sh: bash -n succeeds"
}

test_promote_script_parses
test_promote_flips_kind_and_role
test_promote_keeps_other_meta_fields
test_promote_refuses_non_scout
test_promote_guard_refuses_in_gate
test_promote_guard_absent_marker_allows

echo "# all fm-promote tests passed"
