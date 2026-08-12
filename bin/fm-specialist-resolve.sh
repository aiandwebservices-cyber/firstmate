#!/usr/bin/env bash
# Resolve a wshobson/agents specialist for firstmate intake.
#
# Source of truth for agent files: FM_WSHOBSON_AGENTS_ROOT or ~/agents, then
# ~/.claude/plugins/marketplaces/claude-code-workflows.
# Catalog: FM_ROOT/.agents/skills/wshobson-specialists/catalog.tsv
#
# Usage:
#   fm-specialist-resolve.sh --list
#   fm-specialist-resolve.sh --specialist <name>
#   fm-specialist-resolve.sh --from-text "<task description>"
#   fm-specialist-resolve.sh --role <fm-role>
#
# Prints key=value lines: specialist, role, plugin, agent_path, skills (comma),
# rationale. Exit 1 if unknown specialist or no agent file found.
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)}
CATALOG="$FM_ROOT/.agents/skills/wshobson-specialists/catalog.tsv"

find_agents_root() {
  local c
  for c in \
    "${FM_WSHOBSON_AGENTS_ROOT:-}" \
    "$HOME/agents" \
    "$HOME/.claude/plugins/marketplaces/claude-code-workflows"
  do
    [ -n "$c" ] || continue
    [ -d "$c/plugins" ] || continue
    printf '%s\n' "$c"
    return 0
  done
  return 1
}

find_agent_path() {
  local name=$1 root=$2 plugin=${3:-}
  local hit preferred
  # Catalog plugin wins: the same agent name is copied into several marketplace
  # plugins, and find|head is filesystem-order, not the intended contract.
  if [ -n "$plugin" ] && [ "$plugin" != unknown ]; then
    preferred="$root/plugins/$plugin/agents/${name}.md"
    if [ -f "$preferred" ]; then
      printf '%s\n' "$preferred"
      return 0
    fi
  fi
  hit=$(find "$root/plugins" -path "*/agents/${name}.md" 2>/dev/null | head -1 || true)
  [ -n "$hit" ] || return 1
  printf '%s\n' "$hit"
}

usage() {
  cat <<'U'
Usage: fm-specialist-resolve.sh --list | --specialist NAME | --from-text TEXT | --role ROLE
U
}

MODE=
ARG=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --list) MODE=list; shift ;;
    --specialist) MODE=specialist; ARG=${2:-}; shift 2 ;;
    --specialist=*) MODE=specialist; ARG=${1#--specialist=}; shift ;;
    --from-text) MODE=text; ARG=${2:-}; shift 2 ;;
    --from-text=*) MODE=text; ARG=${1#--from-text=}; shift ;;
    --role) MODE=role; ARG=${2:-}; shift 2 ;;
    --role=*) MODE=role; ARG=${1#--role=}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown arg: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[ -n "$MODE" ] || { usage >&2; exit 1; }
[ -f "$CATALOG" ] || { echo "error: catalog missing at $CATALOG" >&2; exit 1; }

AGENTS_ROOT=$(find_agents_root) || {
  echo "error: wshobson agents root not found (clone ~/agents or marketplace)" >&2
  exit 1
}

# catalog columns: specialist<TAB>fm_role<TAB>plugin<TAB>keywords(comma)<TAB>skills(comma)
# comments start with #

if [ "$MODE" = list ]; then
  printf 'agents_root=%s\n' "$AGENTS_ROOT"
  awk -F'\t' 'BEGIN{OFS="\t"} /^#/||NF<3{next} {print $1,$2,$3}' "$CATALOG"
  exit 0
fi

emit_row() {
  local specialist=$1 role=$2 plugin=$3 skills=$4 rationale=$5
  local path
  path=$(find_agent_path "$specialist" "$AGENTS_ROOT" "$plugin") || {
    echo "error: agent file not found for specialist '$specialist' under $AGENTS_ROOT" >&2
    exit 1
  }
  printf 'specialist=%s\n' "$specialist"
  printf 'role=%s\n' "$role"
  printf 'plugin=%s\n' "$plugin"
  printf 'agent_path=%s\n' "$path"
  printf 'skills=%s\n' "$skills"
  printf 'rationale=%s\n' "$rationale"
  printf 'agents_root=%s\n' "$AGENTS_ROOT"
}

if [ "$MODE" = specialist ]; then
  [ -n "$ARG" ] || { echo "error: --specialist requires a name" >&2; exit 1; }
  while IFS=$'\t' read -r specialist role plugin keywords skills; do
    case "$specialist" in ''|\#*) continue ;; esac
    [ "$specialist" = "$ARG" ] || continue
    emit_row "$specialist" "$role" "$plugin" "${skills:-}" "explicit specialist $ARG"
    exit 0
  done < "$CATALOG"
  # Allow any agent file even if not in catalog
  if path=$(find_agent_path "$ARG" "$AGENTS_ROOT"); then
    emit_row "$ARG" "builder" "unknown" "" "uncatalogued agent file $ARG"
    exit 0
  fi
  echo "error: unknown specialist '$ARG'" >&2
  exit 1
fi

if [ "$MODE" = role ]; then
  [ -n "$ARG" ] || { echo "error: --role requires a name" >&2; exit 1; }
  # First catalog row matching fm_role
  while IFS=$'\t' read -r specialist role plugin keywords skills; do
    case "$specialist" in ''|\#*) continue ;; esac
    [ "$role" = "$ARG" ] || continue
    emit_row "$specialist" "$role" "$plugin" "${skills:-}" "default specialist for role $ARG"
    exit 0
  done < "$CATALOG"
  echo "error: no default specialist for role '$ARG'" >&2
  exit 1
fi

# --from-text: score keyword hits
TEXT=$(printf '%s' "$ARG" | tr '[:upper:]' '[:lower:]')
BEST_SCORE=0
BEST_ROLE=
BEST_PLUGIN=
BEST_SKILLS=
BEST_SPEC=

while IFS=$'\t' read -r specialist role plugin keywords skills; do
  case "$specialist" in ''|\#*) continue ;; esac
  score=0
  IFS=',' read -r -a kws <<KW
$keywords
KW
  for kw in "${kws[@]}"; do
    kw=$(printf '%s' "$kw" | sed 's/^ *//;s/ *$//')
    [ -n "$kw" ] || continue
    case "$TEXT" in
      *"$kw"*)
        score=$((score + 1 + ${#kw}/8))
        # Intent boosts: diagnostic words beat domain-only hits when both match.
        case "$kw" in
          bug|crash|regression|broken|repro|outage|incident|sev)
            score=$((score + 3))
            ;;
          "fix the"|"fix a"|"not working"|"does not work"|"failing test")
            score=$((score + 2))
            ;;
        esac
        ;;
    esac
  done
  if [ "$score" -gt "$BEST_SCORE" ]; then
    BEST_SCORE=$score
    BEST_SPEC=$specialist
    BEST_ROLE=$role
    BEST_PLUGIN=$plugin
    BEST_SKILLS=${skills:-}
  fi
done < "$CATALOG"

if [ "$BEST_SCORE" -eq 0 ] || [ -z "$BEST_SPEC" ]; then
  # Safe default: general builder / typescript for this fleet's JS/TS heavy work
  emit_row "typescript-pro" "builder" "javascript-typescript" "" "no keyword match; default typescript-pro"
  exit 0
fi

emit_row "$BEST_SPEC" "$BEST_ROLE" "$BEST_PLUGIN" "$BEST_SKILLS" "keyword score $BEST_SCORE"
