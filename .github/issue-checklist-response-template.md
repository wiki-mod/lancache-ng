<!-- Template for a WIP/investigation-block CONSOLIDATION COMMENT, per AG-GH-022's 15-minute-cadence
     refinement. This is NOT a body template -- an issue's own body follows the AG-GH-022 "Live
     checklist -- source of truth" format directly (see PR/issue wiki-mod/lancache-ng#1523 for the
     live reference example of that format; no separate template file for it, since #1523 already is
     the worked example). This file is for the ONE comment that replaces/summarizes a run of routine
     progress-ping comments (a standing loop posting "still working, here's the current status" every
     ~15 minutes) -- structured like a rich PR body (modeled directly on wiki-mod/distcc-ng#476, which
     is what earns this level of structure: it lists a real changelog of what was tried, found, and
     changed, with evidence, not just a status line) precisely because a WIP block's real content
     deserves that same evidentiary weight even though it never becomes its own PR.

     Once posted, the issue body's own checklist gets exactly ONE entry citing this one comment's real
     ID -- never the raw ID range of the individual progress pings it replaces. Dry-run example:
     issue #1527 (sandbox, safe to reference, safe to close), consolidating comment
     #issuecomment-5277185357. -->

**WIP investigation summary** (consolidates the N progress-ping comments above -- #issuecomment-<first-id> through #issuecomment-<last-id> -- into one evidence-bearing comment, per AG-GH-022's WIP-consolidation rule).

## Summary
<!-- One or two sentences: what was investigated, and what was found. -->

## What This Actually Changes
<!-- Before/after framing, same discipline as the PR template: what was unknown/broken before this
     investigation, what's known/fixed after, and why that gap mattered. -->

## What Was Found
<!-- The actual progression: what was tried and ruled out, what was tried and confirmed, in the order
     it happened -- this is the "changelog" distcc-ng#476 demonstrates, applied to an investigation
     instead of a code change. Don't compress this into "found the bug" -- the ruled-out theories are
     real evidence too, and a later reader benefits from seeing what was already checked. -->

## What Changed In Code
<!-- File-by-file: what actually changed, briefly, if this WIP block produced a real fix/commit (not
     every investigation does -- a pure finding with no code change yet can leave this section stating
     that explicitly, e.g. "no code changed yet, fix proposed but not landed" -- do not delete the
     section, an absent section reads as "forgot to check", not as "nothing changed"). -->

## Validation
<!-- Exact reproduction/verification performed, not just "confirmed it" -- matching this project's own
     PR template's "Validation" section discipline and AG-GH-022's per-entry evidence requirement. -->

### Which changes have been verified against AGENTS.md violations
<!-- Name the specific rules actually checked against this investigation's own findings/changes (not a
     blanket "reviewed AGENTS.md"), and the outcome for each -- matching the discipline this project's
     PR bodies already use (e.g. per-fix "AG-CODE-011 search confirmations", or #1501's numbered
     governance-acceptance items). If a change was found and fixed, state which rule it would have
     violated if left as-is. If nothing in this block touched governance-relevant surface (no new
     mechanism, no CI/workflow change, no reused-vs-reinvented decision), say so explicitly rather than
     leaving this section silently empty -- an omitted section reads as "not checked", not as "nothing
     applied". -->
- Rule checked: <AG-XX-NNN> -- outcome: <compliant / violation found and fixed / not applicable and why>

## Risk / Rollback / Follow-up
<!-- Same discipline as the PR template: remaining risk, how to roll back if this landed a real
     change, and any follow-up that should stay visible rather than getting lost once this comment
     scrolls out of view. -->

## Local Scope Evidence
<!-- If this WIP block produced a real commit/diff: the actual files touched (e.g. from `git diff
     --stat`), in a fenced code block, same as the PR template's own "Local Scope Evidence" section --
     this is what makes it possible to see AT A GLANCE whether what this comment claims was actually
     checked, rather than just asserted in prose. If nothing was committed yet, say so explicitly
     instead of omitting the section. -->
```text

```

## Bugs/Problems found, that are not addressed (yet) or deliberately deferred
<!-- Name every real bug/gap/problem this investigation surfaced but did NOT fix in this same pass --
     including one found while looking at something else entirely. For each: state why it wasn't fixed
     here (out of scope, needs a separate maintainer decision, genuinely a different undertaking -- per
     AG-WF-027) and where it's tracked going forward (a specific issue/comment, or explicitly "not yet
     tracked, needs a home"). A silent omission here is worse than an honestly-listed unfixed problem:
     this section exists specifically to stop a found-but-unfixed issue from quietly disappearing once
     this comment scrolls out of view -- the exact failure mode this template's own drafting surfaced
     (2026-08-13: several real findings from earlier in the same session -- undisabled reboot cron
     entries on two runner hosts, an unimplemented runner-host script consolidation, this very rule not
     yet landed in AGENTS.md -- had accumulated with no single place listing them until asked for
     directly). If genuinely nothing was found, state that explicitly rather than leaving the section
     empty. -->
- <bug/problem> -- not fixed because <reason> -- tracked at <issue/comment link, or "not yet tracked">


