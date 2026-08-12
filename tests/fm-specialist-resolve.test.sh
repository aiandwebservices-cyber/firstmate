#!/usr/bin/env bash
# Behavior tests for bin/fm-specialist-resolve.sh.
#
# Resolution is the public interface: key=value lines, catalog vs fixture
# agent files, plugin-path preference, and fail-loud unknown names. Tests never
# read the resolver source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESOLVE="$ROOT/bin/fm-specialist-resolve.sh"
TMP_ROOT=$(fm_test_tmproot fm-specialist-resolve)
AGENTS_ROOT="$TMP_ROOT/agents"

make_agents_fixture() {
  mkdir -p \
    "$AGENTS_ROOT/plugins/javascript-typescript/agents" \
    "$AGENTS_ROOT/plugins/frontend-mobile-development/agents" \
    "$AGENTS_ROOT/plugins/unit-testing/agents" \
    "$AGENTS_ROOT/plugins/backend-development/agents" \
    "$AGENTS_ROOT/plugins/data-engineering/agents" \
    "$AGENTS_ROOT/plugins/custom-plugin/agents"
  printf '%s\n' 'You are the typescript-pro specialist.' \
    > "$AGENTS_ROOT/plugins/javascript-typescript/agents/typescript-pro.md"
  printf '%s\n' 'You are the frontend-developer specialist.' \
    > "$AGENTS_ROOT/plugins/frontend-mobile-development/agents/frontend-developer.md"
  printf '%s\n' 'You are the debugger specialist.' \
    > "$AGENTS_ROOT/plugins/unit-testing/agents/debugger.md"
  printf '%s\n' 'You are the catalog backend-architect specialist.' \
    > "$AGENTS_ROOT/plugins/backend-development/agents/backend-architect.md"
  printf '%s\n' 'You are the decoy backend-architect specialist.' \
    > "$AGENTS_ROOT/plugins/data-engineering/agents/backend-architect.md"
  printf '%s\n' 'You are an uncatalogued custom-pro specialist.' \
    > "$AGENTS_ROOT/plugins/custom-plugin/agents/custom-pro.md"
}

run_resolve() {
  FM_WSHOBSON_AGENTS_ROOT="$AGENTS_ROOT" FM_ROOT_OVERRIDE="$ROOT" \
    "$RESOLVE" "$@"
}

kv() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

make_agents_fixture

test_list_prints_catalog_rows() {
  local out
  out=$(run_resolve --list) || fail " --list exited non-zero"
  assert_contains "$out" "agents_root=$AGENTS_ROOT" "--list must report the fixture agents root"
  assert_contains "$out" "frontend-developer" "--list must include frontend-developer"
  assert_contains "$out" "debugger" "--list must include debugger"
  pass "fm-specialist-resolve --list prints catalog rows against the fixture root"
}

test_explicit_specialist_uses_catalog_plugin_path() {
  local out
  out=$(run_resolve --specialist backend-architect) \
    || fail "--specialist backend-architect exited non-zero"
  [ "$(kv "$out" specialist)" = backend-architect ] \
    || fail "specialist= mismatch: $out"
  [ "$(kv "$out" role)" = architect ] \
    || fail "role= mismatch: $out"
  [ "$(kv "$out" plugin)" = backend-development ] \
    || fail "plugin= mismatch: $out"
  assert_contains "$out" \
    "agent_path=$AGENTS_ROOT/plugins/backend-development/agents/backend-architect.md" \
    "catalog plugin path must beat a same-name decoy in another plugin"
  pass "explicit specialist prefers the catalog plugin path over a same-name decoy"
}

test_from_text_picks_debugger_for_crash_language() {
  local out
  out=$(run_resolve --from-text 'the app crashed and the stack trace is broken') \
    || fail "--from-text crash language exited non-zero"
  [ "$(kv "$out" specialist)" = debugger ] \
    || fail "crash language must resolve to debugger, got: $out"
  pass "keyword scoring picks debugger for crash language"
}

test_from_text_defaults_when_no_keyword_hits() {
  local out
  out=$(run_resolve --from-text 'please do the usual thing tomorrow') \
    || fail "--from-text default exited non-zero"
  [ "$(kv "$out" specialist)" = typescript-pro ] \
    || fail "no-match default must be typescript-pro, got: $out"
  pass "no keyword match defaults to typescript-pro"
}

test_unknown_specialist_fails_loudly() {
  local err status=0
  err=$(run_resolve --specialist not-a-real-agent 2>&1) || status=$?
  expect_code 1 "$status" "unknown specialist must be rejected"
  assert_contains "$err" "unknown specialist 'not-a-real-agent'" \
    "unknown specialist must be named in the error"
  pass "unknown specialist fails loudly"
}

test_uncatalogued_agent_file_is_accepted() {
  local out
  out=$(run_resolve --specialist custom-pro) \
    || fail "uncatalogued agent file must still resolve"
  [ "$(kv "$out" specialist)" = custom-pro ] \
    || fail "uncatalogued specialist= mismatch: $out"
  [ "$(kv "$out" role)" = builder ] \
    || fail "uncatalogued default role must be builder: $out"
  assert_contains "$out" "agent_path=$AGENTS_ROOT/plugins/custom-plugin/agents/custom-pro.md" \
    "uncatalogued resolve must point at the found agent file"
  pass "an uncatalogued agent file still resolves"
}

test_missing_agents_root_fails_loudly() {
  local err status=0
  err=$(FM_WSHOBSON_AGENTS_ROOT="$TMP_ROOT/missing" HOME="$TMP_ROOT/empty-home" \
    FM_ROOT_OVERRIDE="$ROOT" "$RESOLVE" --list 2>&1) || status=$?
  expect_code 1 "$status" "missing agents root must fail"
  assert_contains "$err" "wshobson agents root not found" \
    "missing root must fail with the documented error"
  pass "missing agents root fails loudly"
}

test_list_prints_catalog_rows
test_explicit_specialist_uses_catalog_plugin_path
test_from_text_picks_debugger_for_crash_language
test_from_text_defaults_when_no_keyword_hits
test_unknown_specialist_fails_loudly
test_uncatalogued_agent_file_is_accepted
test_missing_agents_root_fails_loudly

echo "# all fm-specialist-resolve tests passed"
