#!/usr/bin/env bash
# fm-zeus-worker.sh - local Hermes Agent coding worker with the Zeus DeepSeek stack.
#
# Process host: the caller's cwd (the task worktree). Tools edit local files.
# Inference uses the same model stack as VPS container aerolot-zeus
# (deepseek-v4-flash / provider deepseek, with OpenRouter fallback).
# This is NOT docker ACP, zeus-acp, or `hermes acp` (Desktop/Buzz-only).
#
# Usage (from fm-spawn launch template):
#   fm-zeus-worker.sh [--model <name>] [--provider <name>]
#
# Credential resolution (never reads or prints secret values):
#   1. DEEPSEEK_API_KEY set -> provider deepseek, model deepseek-v4-flash
#   2. else OPENROUTER_API_KEY set -> provider openrouter,
#      model deepseek/deepseek-v4-flash (one loud stderr notice)
#   3. else refuse
# Explicit --model / --provider override the defaults for the chosen key path.
set -euo pipefail

hermes_bin=
candidate=$(command -v hermes 2>/dev/null || true)
if [ -n "$candidate" ] && [ -x "$candidate" ]; then
  case "$candidate" in
    /*) hermes_bin=$candidate ;;
    *)
      dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || dir=
      if [ -n "$dir" ]; then
        hermes_bin="$dir/$(basename "$candidate")"
      fi
      ;;
  esac
fi
if [ -z "$hermes_bin" ] || [ ! -x "$hermes_bin" ]; then
  echo "error: hermes executable not found on PATH; install Hermes Agent (expected e.g. ~/.local/bin/hermes)" >&2
  exit 1
fi

model=
provider=
while [ $# -gt 0 ]; do
  case "$1" in
    --model)
      [ $# -ge 2 ] || { echo "error: --model requires a value" >&2; exit 1; }
      model=$2
      shift 2
      ;;
    --provider)
      [ $# -ge 2 ] || { echo "error: --provider requires a value" >&2; exit 1; }
      provider=$2
      shift 2
      ;;
    *)
      echo "error: unsupported fm-zeus-worker argument: $1" >&2
      exit 1
      ;;
  esac
done

if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
  [ -n "$provider" ] || provider=deepseek
  [ -n "$model" ] || model=deepseek-v4-flash
elif [ -n "${OPENROUTER_API_KEY:-}" ]; then
  [ -n "$provider" ] || provider=openrouter
  [ -n "$model" ] || model=deepseek/deepseek-v4-flash
  if [ -z "${FM_ZEUS_OPENROUTER_WARNED:-}" ]; then
    echo "fm-zeus-worker: DEEPSEEK_API_KEY unset; falling back to OpenRouter model deepseek/deepseek-v4-flash" >&2
    export FM_ZEUS_OPENROUTER_WARNED=1
  fi
else
  echo "error: Zeus stack needs DEEPSEEK_API_KEY (preferred) or OPENROUTER_API_KEY in the environment" >&2
  exit 1
fi

# Interactive unattended coding pane (verified 2026-08-06, Hermes Agent v0.18.2):
# --yolo bypasses dangerous-command approval; --accept-hooks auto-approves config hooks;
# --cli forces the classic REPL (stable ❯ composer); -m/--provider pin the Zeus stack.
# Top-level hermes -z is one-shot and is not used for supervised workers.
exec "$hermes_bin" chat --yolo --accept-hooks --cli -m "$model" --provider "$provider"
