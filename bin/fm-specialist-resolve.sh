#!/usr/bin/env bash
# Resolve a wshobson/agents specialist for firstmate intake.
#
# Source of truth for agent files: FM_WSHOBSON_AGENTS_ROOT or ~/agents, then
# ~/.claude/plugins/marketplaces/claude-code-workflows.
# Catalog: FM_ROOT/.agents/skills/wshobson-specialists/catalog.tsv
# Catalog rows are curated aliases and role defaults. --from-text also scores
# eligible on-disk agent names and frontmatter descriptions, then injects only
# the winner. It never prints or loads every agent body.
#
# Usage:
#   fm-specialist-resolve.sh --list [--all]
#   fm-specialist-resolve.sh --specialist <name>
#   fm-specialist-resolve.sh --from-text "<task description>" [--role <fm-role>]
#   fm-specialist-resolve.sh --role <fm-role>
#
# Prints key=value lines: specialist, role, plugin, agent_path, skills (comma),
# rationale, source, score, agents_root. Exit 1 if unknown specialist or no
# agent file found.
set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)}
CATALOG="$FM_ROOT/.agents/skills/wshobson-specialists/catalog.tsv"
# Index-only picks must beat this; a single distinctive name token is 4.
MIN_INDEX_SCORE=4

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
Usage: fm-specialist-resolve.sh --list [--all] | --specialist NAME | --from-text TEXT [--role ROLE] | --role ROLE
U
}

# Lowercase, keep alnum as tokens, strip a trailing s on long words that do
# not end in ss so "unit tests" still matches the keyword "unit test".
normalize() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' ' | sed -E 's/  +/ /g;s/^ //;s/ $//;s/([a-z0-9]{4,}[^s])s\b/\1/g'
}

declare -A CATALOG_NAMES=()

load_catalog_names() {
  local specialist
  while IFS=$'\t' read -r specialist _; do
    case "$specialist" in ''|\#*) continue ;; esac
    CATALOG_NAMES[$specialist]=1
  done < "$CATALOG"
}

catalog_has() {
  [ -n "${CATALOG_NAMES[$1]:-}" ]
}

# Auto-pick skips generic verb agents. Explicit --specialist still accepts them.
is_auto_eligible() {
  local name=$1 desc=$2
  case "$name" in
    implement|orchestrate|qa|review|architect|session-start|session-end|compare|certify|task-executor|team-implementer|team-debugger)
      catalog_has "$name" && return 0
      return 1
      ;;
    *-pro|*-developer|*-architect|*-engineer|*-expert|*-auditor|*-reviewer|*-designer|*-specialist|*-responder|*-troubleshooter|*-automator|*-marketer|*-writer|*-optimizer|*-modernizer|*-integrator|*-analyst|*-advisor|*-coder|*-scientist|*-support|*-admin|*-documenter|*-lead|*-hunter)
      return 0
      ;;
  esac
  catalog_has "$name" && return 0
  case "$desc" in
    *[Pp][Rr][Oo][Aa][Cc][Tt][Ii][Vv][Ee][Ll][Yy]*) return 0 ;;
  esac
  return 1
}

keyword_hits() {
  local pad=$1 kw=$2
  local kwn
  kwn=$(normalize "$kw")
  [ -n "$kwn" ] || return 1
  case "$pad" in
    *" $kwn "*) return 0 ;;
  esac
  case "$kwn" in
    *' '*) return 1 ;;
  esac
  [ "${#kwn}" -ge 4 ] || return 1
  case "$pad" in
    *" $kwn"[a-z]*) return 0 ;;
  esac
  return 1
}

catalog_row() {
  local want=$1 specialist role plugin keywords skills
  while IFS=$'\t' read -r specialist role plugin keywords skills; do
    case "$specialist" in ''|\#*) continue ;; esac
    if [ "$specialist" = "$want" ]; then
      printf '%s\t%s\t%s\t%s\n' "$role" "$plugin" "${skills:-}" "${keywords:-}"
      return 0
    fi
  done < "$CATALOG"
  return 1
}

fallback_specialist_for_role() {
  case "${1:-}" in
    debugger) printf '%s\n' debugger ;;
    designer) printf '%s\n' ui-designer ;;
    architect) printf '%s\n' backend-architect ;;
    researcher) printf '%s\n' search-specialist ;;
    reviewer) printf '%s\n' code-reviewer ;;
    tester) printf '%s\n' test-automator ;;
    planner) printf '%s\n' business-analyst ;;
    *) printf '%s\n' typescript-pro ;;
  esac
}

MODE=
ARG=
LIST_ALL=0
ROLE_FALLBACK=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --list) MODE=list; shift ;;
    --all) LIST_ALL=1; shift ;;
    --specialist) MODE=specialist; ARG=${2:-}; shift 2 ;;
    --specialist=*) MODE=specialist; ARG=${1#--specialist=}; shift ;;
    --from-text) MODE=text; ARG=${2:-}; shift 2 ;;
    --from-text=*) MODE=text; ARG=${1#--from-text=}; shift ;;
    --role)
      ROLE_FALLBACK=${2:-}
      if [ -z "$MODE" ]; then
        MODE=role
        ARG=$ROLE_FALLBACK
      fi
      shift 2
      ;;
    --role=*)
      ROLE_FALLBACK=${1#--role=}
      if [ -z "$MODE" ]; then
        MODE=role
        ARG=$ROLE_FALLBACK
      fi
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown arg: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ "$LIST_ALL" -eq 1 ] && [ "$MODE" != list ]; then
  echo "error: --all requires --list" >&2
  exit 1
fi
[ -n "$MODE" ] || { usage >&2; exit 1; }
[ -f "$CATALOG" ] || { echo "error: catalog missing at $CATALOG" >&2; exit 1; }

AGENTS_ROOT=$(find_agents_root) || {
  echo "error: wshobson agents root not found (clone ~/agents or marketplace)" >&2
  exit 1
}
load_catalog_names

list_disk_agents() {
  # One awk over the agent files: name, plugin, description. Unique names keep
  # the first path after LC_ALL=C sort so the scan stays deterministic.
  # The awk program is literal; xargs only supplies agent file paths.
  # shellcheck disable=SC2016
  find "$AGENTS_ROOT/plugins" -mindepth 3 -maxdepth 3 -path '*/agents/*.md' -type f -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 -r awk '
      FNR==1 {
        if (path != "") emit()
        path = FILENAME
        desc = ""
        fm = 0
      }
      FNR==1 && $0=="---" {fm=1; next}
      fm && $0=="---" {fm=0; next}
      fm && $1=="description:" {
        sub(/^description:[[:space:]]*/, "")
        if ($0!=">" && $0!=">-" && $0!="|" && $0!=">+") desc=$0
      }
      END { emit() }
      function emit(   n, p, parts, i) {
        n = path
        sub(/^.*\//, "", n)
        sub(/\.md$/, "", n)
        p = path
        split(p, parts, "/")
        for (i in parts) if (parts[i] == "plugins") { p = parts[i+1]; break }
        print n "\t" p "\t" desc
      }
    ' \
    | awk -F'\t' '!seen[$1]++'
}

filter_eligible_agents() {
  local name plugin desc
  while IFS=$'\t' read -r name plugin desc; do
    [ -n "$name" ] || continue
    is_auto_eligible "$name" "$desc" || continue
    printf '%s\t%s\t%s\n' "$name" "$plugin" "$desc"
  done
}

# catalog columns: specialist<TAB>fm_role<TAB>plugin<TAB>keywords(comma)<TAB>skills(comma)
# comments start with #

list_eligible_agents() {
  list_disk_agents | filter_eligible_agents
}

if [ "$MODE" = list ]; then
  printf 'agents_root=%s\n' "$AGENTS_ROOT"
  awk -F'\t' 'BEGIN{OFS="\t"} /^#/||NF<3{next} {print $1,$2,$3}' "$CATALOG"
  if [ "$LIST_ALL" -eq 1 ]; then
    printf 'disk_index=eligible\n'
    list_eligible_agents
  fi
  exit 0
fi

emit_row() {
  local specialist=$1 role=$2 plugin=$3 skills=$4 rationale=$5 source=${6:-catalog} score=${7:-0}
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
  printf 'source=%s\n' "$source"
  printf 'score=%s\n' "$score"
  printf 'agents_root=%s\n' "$AGENTS_ROOT"
}

if [ "$MODE" = specialist ]; then
  [ -n "$ARG" ] || { echo "error: --specialist requires a name" >&2; exit 1; }
  while IFS=$'\t' read -r specialist role plugin keywords skills; do
    case "$specialist" in ''|\#*) continue ;; esac
    [ "$specialist" = "$ARG" ] || continue
    emit_row "$specialist" "$role" "$plugin" "${skills:-}" "explicit specialist $ARG" catalog 0
    exit 0
  done < "$CATALOG"
  # Allow any agent file even if not in catalog
  if path=$(find_agent_path "$ARG" "$AGENTS_ROOT"); then
    emit_row "$ARG" "builder" "unknown" "" "uncatalogued agent file $ARG" index 0
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
    emit_row "$specialist" "$role" "$plugin" "${skills:-}" "default specialist for role $ARG" catalog 0
    exit 0
  done < "$CATALOG"
  echo "error: no default specialist for role '$ARG'" >&2
  exit 1
fi

# --from-text: catalog keywords first, then eligible on-disk name/description.
TEXT_NORM=$(normalize "$ARG")
TEXT_PAD=" $TEXT_NORM "
BEST_CAT_SCORE=0
BEST_CAT_SPEC=
BEST_IDX_SCORE=0
BEST_IDX_SPEC=
BEST_IDX_PLUGIN=

score_catalog_keywords() {
  local keywords=$1
  local score=0 kw
  IFS=',' read -r -a kws <<KW
$keywords
KW
  for kw in "${kws[@]}"; do
    kw=$(printf '%s' "$kw" | sed 's/^ *//;s/ *$//')
    [ -n "$kw" ] || continue
    keyword_hits "$TEXT_PAD" "$kw" || continue
    score=$((score + 1 + ${#kw}/8))
    case "$kw" in
      bug|crash|regression|broken|repro|outage|incident|sev)
        score=$((score + 3))
        ;;
      "fix the"|"fix a"|"not working"|"does not work"|"failing test")
        score=$((score + 2))
        ;;
    esac
  done
  printf '%s\n' "$score"
}

while IFS=$'\t' read -r specialist role plugin keywords skills; do
  case "$specialist" in ''|\#*) continue ;; esac
  score=$(score_catalog_keywords "${keywords:-}")
  if [ "$score" -gt "$BEST_CAT_SCORE" ]; then
    BEST_CAT_SCORE=$score
    BEST_CAT_SPEC=$specialist
  fi
done < "$CATALOG"

# Score every eligible index row in one awk. Bash-per-agent scoring spawned
# thousands of sed processes against a full ~/agents clone.
score_index_best() {
  TEXT_NORM="$TEXT_NORM" awk -F'\t' '
    BEGIN {
      text = ENVIRON["TEXT_NORM"]
      pad = " " text " "
      nstop = split("about after application applications based build building code create creating development developer expert from handle handles including into master masters modern that this with when your proactively specializing patterns system systems using", sw, " ")
      for (i = 1; i <= nstop; i++) STOP[sw[i]] = 1
      split(text, twords, " ")
    }
    function lower(s) {
      gsub(/[^a-zA-Z0-9]+/, " ", s)
      s = tolower(s)
      gsub(/  +/, " ", s)
      gsub(/^ | $/, "", s)
      return s
    }
    function hits(kw,   i, w) {
      if (kw == "") return 0
      if (index(pad, " " kw " ") > 0) return 1
      if (kw ~ / /) return 0
      if (length(kw) < 4) return 0
      for (i in twords) {
        w = twords[i]
        if (index(w, kw) == 1) return 1
      }
      return 0
    }
    {
      name = $1; plugin = $2; desc = lower($3)
      phrase = lower(name)
      gsub(/-/, " ", phrase)
      phrase = lower(phrase)
      score = 0
      if (phrase != "" && index(pad, " " phrase " ") > 0) score += 10
      n = split(phrase, toks, " ")
      for (i = 1; i <= n; i++) {
        tok = toks[i]
        if (length(tok) < 4 || tok in STOP) continue
        if (hits(tok)) score += 4
      }
      n = split(desc, dtoks, " ")
      for (i = 1; i <= n; i++) {
        tok = dtoks[i]
        if (length(tok) < 5 || tok in STOP) continue
        if (hits(tok)) score += 1
      }
      if (score > best) {
        best = score
        best_name = name
        best_plugin = plugin
      }
    }
    END {
      if (best_name != "") print best "\t" best_name "\t" best_plugin
    }
  '
}

idx_row=$(list_eligible_agents | score_index_best || true)
if [ -n "$idx_row" ]; then
  BEST_IDX_SCORE=$(printf '%s\n' "$idx_row" | cut -f1)
  BEST_IDX_SPEC=$(printf '%s\n' "$idx_row" | cut -f2)
  BEST_IDX_PLUGIN=$(printf '%s\n' "$idx_row" | cut -f3)
fi

WIN_SPEC=
WIN_SOURCE=
WIN_SCORE=0
WIN_RATIONALE=

if [ "$BEST_IDX_SCORE" -ge "$MIN_INDEX_SCORE" ] && [ "$BEST_IDX_SCORE" -gt $((BEST_CAT_SCORE + 1)) ]; then
  WIN_SPEC=$BEST_IDX_SPEC
  WIN_SOURCE=index
  WIN_SCORE=$BEST_IDX_SCORE
  WIN_RATIONALE="index score $BEST_IDX_SCORE"
elif [ "$BEST_CAT_SCORE" -ge 1 ] && [ -n "$BEST_CAT_SPEC" ]; then
  WIN_SPEC=$BEST_CAT_SPEC
  WIN_SOURCE=catalog
  WIN_SCORE=$BEST_CAT_SCORE
  WIN_RATIONALE="keyword score $BEST_CAT_SCORE"
elif [ "$BEST_IDX_SCORE" -ge "$MIN_INDEX_SCORE" ] && [ -n "$BEST_IDX_SPEC" ]; then
  WIN_SPEC=$BEST_IDX_SPEC
  WIN_SOURCE=index
  WIN_SCORE=$BEST_IDX_SCORE
  WIN_RATIONALE="index score $BEST_IDX_SCORE"
fi

if [ -z "$WIN_SPEC" ]; then
  WIN_SPEC=$(fallback_specialist_for_role "$ROLE_FALLBACK")
  WIN_SOURCE=default
  WIN_SCORE=0
  if [ -n "$ROLE_FALLBACK" ]; then
    WIN_RATIONALE="no confident match; default for role $ROLE_FALLBACK"
  else
    WIN_RATIONALE="no keyword match; default typescript-pro"
  fi
fi

WIN_ROLE=builder
WIN_PLUGIN=unknown
WIN_SKILLS=
if row=$(catalog_row "$WIN_SPEC"); then
  WIN_ROLE=$(printf '%s\n' "$row" | cut -f1)
  WIN_PLUGIN=$(printf '%s\n' "$row" | cut -f2)
  WIN_SKILLS=$(printf '%s\n' "$row" | cut -f3)
elif [ "$WIN_SOURCE" = index ]; then
  WIN_PLUGIN=$BEST_IDX_PLUGIN
fi

emit_row "$WIN_SPEC" "$WIN_ROLE" "$WIN_PLUGIN" "$WIN_SKILLS" "$WIN_RATIONALE" "$WIN_SOURCE" "$WIN_SCORE"
