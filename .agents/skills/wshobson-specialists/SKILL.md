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

## Token rule

One worker receives one specialist body.
Never install the 90+ marketplace plugins into a crewmate context.
Never paste more than the winning agent file into a brief.
`bin/fm-specialist-resolve.sh --from-text` may scan the on-disk index (name + one-line description only).
That scan stays in the resolver.
It does not enter firstmate chat or the worker brief.

A big multi-domain request is not one worker with many specialists.
Split it into independent subtasks.
Resolve and spawn each subtask with its own specialist.

## When to load

Load this skill on every intake that will call `fm-brief` / `fm-spawn`
(ship or scout), immediately after `agent-roles`.

Skip only for pure inline assistant answers that never dispatch.

## Procedure (mandatory for dispatch)

1. Classify firstmate **role** via `agent-roles` (ship vs scout, role name).
2. If the request has more than one independent domain, split it first.
   Resolve each piece on its own.
3. Resolve a **specialist**:
   ```bash
   bin/fm-specialist-resolve.sh --from-text "<captain request + project context>" --role <role>
   # or explicit:
   bin/fm-specialist-resolve.sh --specialist frontend-developer
   ```
   Trust `specialist=` from that output.
   `source=default` means no confident match; keep the role default unless the captain named one.
4. Scaffold with both axes:
   ```bash
   bin/fm-brief.sh <id> <repo> [--scout] --role <role> --specialist <specialist>
   bin/fm-spawn.sh <id> <repo> [--scout] --role <role> --specialist <specialist> ...
   ```
5. If resolve picks a different role than step 1 and you have no strong reason
   to keep your role, prefer the resolve `role=` for scouts; for ships keep
   builder/debugger/tester when the work is implementation or fix.
6. Tell the captain which specialist is on the job in plain language
   (e.g. “mobile specialist on the Expo screens”), not internal catalog names
   unless they ask.

## Catalog vs full pack

- File: `.agents/skills/wshobson-specialists/catalog.tsv`
- Helper: `bin/fm-specialist-resolve.sh`
- List curated rows: `bin/fm-specialist-resolve.sh --list`
- List eligible on-disk agents: `bin/fm-specialist-resolve.sh --list --all`
- Agent bodies: `~/agents/plugins/*/agents/<name>.md`

The catalog holds aliases, intent keywords, and role defaults.
`--from-text` also scores eligible agent filenames and frontmatter descriptions under `~/agents`.
Generic verb agents (`implement`, `qa`, `orchestrate`, …) are not auto-picked.
`--specialist NAME` still accepts any agent file on disk.

Add a catalog row when a specialist is used repeatedly and the request words do not appear in its name.
Do not copy the whole marketplace into the catalog.

## Defaults

| Situation | Specialist |
| --- | --- |
| No confident match | role default (`typescript-pro` for builder / unknown) |
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
