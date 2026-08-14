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
    "$AGENTS_ROOT/plugins/custom-plugin/agents" \
    "$AGENTS_ROOT/plugins/shell-scripting/agents" \
    "$AGENTS_ROOT/plugins/ui-design/agents" \
    "$AGENTS_ROOT/plugins/elixir-development/agents" \
    "$AGENTS_ROOT/plugins/cloud-infrastructure/agents" \
    "$AGENTS_ROOT/plugins/llm-application-dev/agents"
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
  printf '%s\n' 'You are the bash-pro specialist.' \
    > "$AGENTS_ROOT/plugins/shell-scripting/agents/bash-pro.md"
  printf '%s\n' 'You are the ui-designer specialist.' \
    > "$AGENTS_ROOT/plugins/ui-design/agents/ui-designer.md"
  printf '%s\n' \
    '---' \
    'name: elixir-pro' \
    'description: Elixir and Phoenix services. Use PROACTIVELY for elixir.' \
    'model: opus' \
    '---' \
    'You are an uncatalogued elixir-pro specialist.' \
    > "$AGENTS_ROOT/plugins/elixir-development/agents/elixir-pro.md"
  printf '%s\n' 'You are the temporal-python-pro specialist.' \
    > "$AGENTS_ROOT/plugins/backend-development/agents/temporal-python-pro.md"
  printf '%s\n' 'You are the terraform-specialist.' \
    > "$AGENTS_ROOT/plugins/cloud-infrastructure/agents/terraform-specialist.md"
  printf '%s\n' 'You are the vector-database-engineer specialist.' \
    > "$AGENTS_ROOT/plugins/llm-application-dev/agents/vector-database-engineer.md"
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

test_from_text_picks_qdrant_as_vector_specialist() {
  local out
  out=$(run_resolve --from-text 'qdrant collection for dealership embeddings') \
    || fail "--from-text qdrant language exited non-zero"
  [ "$(kv "$out" specialist)" = vector-database-engineer ] \
    || fail "qdrant language must resolve to vector-database-engineer, got: $out"
  pass "catalog aliases pick vector-database-engineer for qdrant"
}

test_from_text_picks_uncatalogued_persona_from_index() {
  local out
  out=$(run_resolve --from-text 'write an elixir phoenix service') \
    || fail "--from-text elixir language exited non-zero"
  [ "$(kv "$out" specialist)" = elixir-pro ] \
    || fail "elixir language must resolve to elixir-pro, got: $out"
  [ "$(kv "$out" source)" = index ] \
    || fail "elixir-pro must come from the disk index, got: $out"
  assert_contains "$out" \
    "agent_path=$AGENTS_ROOT/plugins/elixir-development/agents/elixir-pro.md" \
    "index resolve must point at the elixir-pro fixture"
  pass "index scoring picks an uncatalogued persona from its name"
}

test_from_text_role_fallback_when_no_match() {
  local out
  out=$(run_resolve --from-text 'please do the usual thing tomorrow' --role designer) \
    || fail "--from-text --role designer exited non-zero"
  [ "$(kv "$out" specialist)" = ui-designer ] \
    || fail "designer fallback must be ui-designer, got: $out"
  [ "$(kv "$out" source)" = default ] \
    || fail "no-match with --role must set source=default, got: $out"
  pass "no confident match falls back to the role default specialist"
}

test_from_text_word_boundary_ignores_embedded_error() {
  local out
  out=$(run_resolve --from-text 'please inspect the terror tomorrow') \
    || fail "--from-text terror language exited non-zero"
  [ "$(kv "$out" specialist)" = typescript-pro ] \
    || fail "terror must not match debugger via embedded error, got: $out"
  pass "keyword scoring requires a word boundary"
}

test_list_all_includes_disk_persona() {
  local out
  out=$(run_resolve --list --all) || fail "--list --all exited non-zero"
  assert_contains "$out" "elixir-pro" "--list --all must include the disk persona"
  assert_contains "$out" "disk_index=eligible" "--list --all must mark the disk section"
  pass "fm-specialist-resolve --list --all prints eligible disk agents"
}

test_all_without_list_fails_loudly() {
  local err status=0
  err=$(run_resolve --all 2>&1) || status=$?
  expect_code 1 "$status" "--all without --list must be rejected"
  assert_contains "$err" "--all requires --list" \
    "--all without --list must name the requirement"
  pass "--all without --list fails loudly"
}

test_list_prints_catalog_rows
test_explicit_specialist_uses_catalog_plugin_path
test_from_text_picks_debugger_for_crash_language
test_from_text_defaults_when_no_keyword_hits
test_unknown_specialist_fails_loudly
test_uncatalogued_agent_file_is_accepted
test_missing_agents_root_fails_loudly
test_from_text_picks_qdrant_as_vector_specialist
test_from_text_picks_uncatalogued_persona_from_index
test_from_text_role_fallback_when_no_match
test_from_text_word_boundary_ignores_embedded_error
test_list_all_includes_disk_persona
test_all_without_list_fails_loudly

echo "# all fm-specialist-resolve tests passed"
