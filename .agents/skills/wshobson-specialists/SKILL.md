---
name: wshobson-specialists
description: >-
  Agent-only routing of captain work onto wshobson/agents domain specialists
  (backend-architect, frontend-developer, debugger, security-auditor, …).
  Load at every task intake after agent-roles, before scaffolding fm-brief or
  spawning. Owns the specialist catalog, resolve helper, and the rule that
  every dispatched ship/scout carries a specialist when one fits.
user-invocable: false
metadata:
  internal: true
---

# wshobson-specialists

Firstmate roles (`assistant` … `tester`) are the lifecycle axis.
**Specialists** are domain experts from [wshobson/agents](https://github.com/wshobson/agents)
cloned at `~/agents` (marketplace: `claude-code-workflows`).

Installing the marketplace alone does not make firstmate use them.
This skill is the use path: resolve → inject into brief → record on spawn.

## When to load

Load this skill on every intake that will call `fm-brief` / `fm-spawn`
(ship or scout), immediately after `agent-roles`.

Skip only for pure inline assistant answers that never dispatch.

## Procedure (mandatory for dispatch)

1. Classify firstmate **role** via `agent-roles` (ship vs scout, role name).
2. Resolve a **specialist**:
   ```bash
   bin/fm-specialist-resolve.sh --from-text "<captain request + project context>"
   # or explicit:
   bin/fm-specialist-resolve.sh --specialist frontend-developer
   ```
3. Scaffold with both axes:
   ```bash
   bin/fm-brief.sh <id> <repo> [--scout] --role <role> --specialist <specialist>
   bin/fm-spawn.sh <id> <repo> [--scout] --role <role> --specialist <specialist> ...
   ```
4. If resolve picks a different role than step 1 and you have no strong reason
   to keep your role, prefer the resolve `role=` for scouts; for ships keep
   builder/debugger/tester when the work is implementation or fix.
5. Tell the captain which specialist is on the job in plain language
   (e.g. “mobile specialist on the Expo screens”), not internal catalog names
   unless they ask.

## Catalog

- File: `.agents/skills/wshobson-specialists/catalog.tsv`
- Helper: `bin/fm-specialist-resolve.sh`
- List: `bin/fm-specialist-resolve.sh --list`
- Agent bodies: `~/agents/plugins/*/agents/<name>.md`

Add a row to the catalog when a specialist is used repeatedly and missing.
Do not install all 90+ marketplace plugins into every harness context
(token cost). Prefer brief injection of the one agent contract.

## Defaults

| Situation | Specialist |
| --- | --- |
| No keyword match | `typescript-pro` (this fleet is TS-heavy) |
| Bug / fix / crash | `debugger` |
| UI / React / Next | `frontend-developer` |
| Mobile / Expo / Cap | `mobile-developer` |
| API / Nest / backend design | `backend-architect` (scout) or same + builder ship |
| Security / auth | `security-auditor` |
| Multi-agent / LLM platform | `ai-engineer` |
| Prod down / ops | `incident-responder` or `devops-troubleshooter` |

## Harness note

- **Grok / Claude crewmates:** specialist text is in the brief; they need no plugin install to follow it.
- **Claude Code interactive:** high-value plugins may also be installed user-scope from marketplace `claude-code-workflows` for slash/skills discovery.
- **OMP:** plugins may already be installed user-scope; still inject via brief for fleet crewmates.

## Constraints

- Does not replace hard rules in `AGENTS.md` section 1.
- Does not expand the fixed firstmate role catalog; specialists are a second label.
- Never invent a specialist name that has no agent file under `~/agents`.
- Captain may override with an explicit specialist or “no specialist”.
