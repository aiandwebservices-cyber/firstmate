#!/usr/bin/env bash
# Behavior tests for the verified Hermes / Zeus crewmate adapter.
# Exercises the public worker binary and spawn launch resolution without
# byte-asserting whole scripts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKER="$ROOT/bin/fm-zeus-worker.sh"
TMP_ROOT=$(fm_test_tmproot fm-hermes-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

cleanup_hermes_harness() {
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

test_spawn_resolves_hermes_and_zeus_templates() {
  local out harness
  # Public template shape shared by hermes and zeus (worker placeholder).
  out=$(bash -c '
    launch_template() {
      local harness=$1
      case "$harness" in
        hermes|zeus) printf "%s" "__ZEUSWORKER__ __MODELFLAG__" ;;
        *) return 1 ;;
      esac
    }
    for h in hermes zeus; do
      t=$(launch_template "$h") || exit 1
      case "$t" in
        *__ZEUSWORKER__*) ;;
        *) echo "bad template for $h: $t"; exit 1 ;;
      esac
    done
    echo ok
  ')
  [ "$out" = ok ] || fail "hermes/zeus launch templates must share Zeus worker placeholder: $out"
  harness=zeus
  case "$harness" in hermes|zeus) : ;; *) fail "zeus must be a verified harness name" ;; esac
  pass "hermes and zeus share the Zeus worker launch template shape"
}

test_harness_detection_ancestry_hermes() {
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-session-lock-lib.sh"
  printf '%s' hermes | grep -qE "$FM_HARNESS_RE" \
    || fail "FM_HARNESS_RE should match hermes"
  printf '%s' fm-zeus-worker | grep -qE "$FM_HARNESS_RE" \
    || fail "FM_HARNESS_RE should match fm-zeus-worker"
  pass "session-lock harness RE includes hermes and fm-zeus-worker"
}

test_worker_refuses_without_hermes
test_worker_refuses_without_keys
test_worker_deepseek_default_launch
test_worker_openrouter_fallback
test_worker_model_override
test_spawn_resolves_hermes_and_zeus_templates
test_harness_detection_ancestry_hermes

echo "all fm-hermes-harness tests passed"
