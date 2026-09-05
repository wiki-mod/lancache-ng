# Task: AG-CODE-012 Comment Cleanup

## Dispatch Parameters

The dispatcher MUST fill in every slot below before sending. Any slot
left as a `<...>` placeholder means this dispatch is incomplete and MUST
NOT be sent.

* Worktree, absolute path: `<WORKTREE_PATH>` on branch `<BRANCH>`
* Your relayed task/session ID: `<TASK_ID>`
* Audit scope, exactly the following file or files and nothing else:

  * `<FILE_1>`
  * `<FILE_2>`

The list above is the complete and only audit scope. Do not touch any
file that is not listed. Keep the scope narrow: this is a purely
mechanical task and MUST NOT be given codebase-wide latitude. If the
overall cleanup spans many files, split them across several narrow
dispatches instead of widening one.

## Goal

You are commissioned exclusively with cleaning up code comments per
`AG-CODE-012`.

The audit scope is exactly the file or files named in the Dispatch
Parameters block above, and nothing else.

Within each listed file the ENTIRE file is the audit scope. EVERY
comment in the file MUST be reviewed and brought into compliance,
including comments in untouched or unrelated sections, not only the
comments that sit next to code you might otherwise look at.

Your change authority is strictly limited to comments.

You must not change any production code, logic, configuration, data
structures, or runtime behavior.

## Binding Sources

Before any work you MUST read in full:

1. `AGENTS.md` from the current state of `current_dev`
2. `.github/agent-dispatch-checklist.md` from `current_dev`

`AGENTS.md` applies in full.

In particular you MUST apply `AG-CODE-012` in its currently valid
wording and must not reconstruct the rule from memory.

The current version on `current_dev` is authoritative.

## Mandatory Dispatch Block

The mandatory `.github/agent-dispatch-checklist.md` is embedded verbatim
at the end of this document, under "Agent Dispatch Checklist". It is a
binding part of this contract and applies in full.

Before sending, the dispatcher MUST confirm the embedded checklist still
matches the current `.github/agent-dispatch-checklist.md` on
`current_dev`, and refresh it if `current_dev` has changed. The checklist
MUST NOT be summarized, shortened, reworded, or replaced by an own
interpretation.

## For the Dispatcher: Haiku Is a Weak Model, Mandatory Re-check

Haiku is a markedly weaker, purely mechanical model, not a cheaper
Sonnet substitute.

Commission Haiku only with narrow, unambiguous sub-tasks that leave no
room for interpretation.

On ambiguity, split further rather than leave latitude.

Haiku self-reports are NOT trustworthy. The dispatcher MUST real-check
every "done" claim instead of adopting it:

1. Grep for remaining comments over the character limit, outside
   permitted exceptions such as section dividers or embedded data.
2. Verify that NO non-comment line changed: the resolved config,
   respectively the build, must stay unchanged (a real parity proof),
   not just the file diff by eye.
3. Check every `From:` reference for an invented or wrong Issue/PR.

After EVERY Haiku round you MUST additionally check `git log` and
`git status` for UNEXPECTED commits.

Haiku has already ignored an explicit "do not commit / do not push"
instruction and committed anyway, once even pushed, leaving eight
format violations plus a wrong PR reference, although it reported
"done".

A "done, not committed" self-report from Haiku does NOT replace this
re-check.

Parity and build verification run in the verified build-tools
container, not assumed local.

## Permitted Change Scope

You MAY edit only syntactically real code comments.

This includes only constructs that the respective language actually
treats as a comment.

Examples are:

`#`
`//`
`/* ... */`
`<!-- ... -->`

when these actually represent comments at the given location.

You MAY replace or merge existing comment blocks.

You MAY add a missing comment only when an applicable rule from
`AGENTS.md` explicitly requires that comment.

## Comments Not in Scope

Some comment-like lines are NOT code-location comments and MUST be left
exactly as they are:

* Section dividers, for example a `# ----`, `# ====`, or box-drawing
  banner line. They may exceed 60 characters and MUST NOT be forced
  into a `What:`/`Why:`/`From:` block.
* File license or SPDX headers.
* Any `#`, `//`, or similar line that sits inside a heredoc, a
  multi-line command string, a config template, or any other block
  whose text is DATA: it becomes part of the program output, a
  generated config file, or the resolved runtime value. Changing it
  alters runtime behavior or breaks build/config parity, so treat it as
  data, not as a comment to clean.

This exemption list is exhaustive and narrow. A multi-line explanatory
or narrative comment above a code, config, or step line is a normal
code-location comment and IS in scope — it is NOT a "doc-block", no
matter how many prose lines it spans (three or more lines of prose does
not make it exempt). It MUST become one `What:`/`Why:`/`From:` block,
with any overflow rationale moved to a durable record.

When in doubt whether a line is one of the three narrow exemptions above
or a real code comment, it IS a real code comment and in scope. Conform
it; if you genuinely cannot, flag it to the coordinator by exact file
and line. You MUST NOT silently skip a comment by classifying it as
"data" or a "doc-block" — silently skipping in-scope comments is the
exact failure this task exists to prevent.

## Strictly Forbidden

You MUST NOT:

* change production code
* change program logic
* change conditions
* change variables
* change function calls
* change commands
* change configuration values
* change strings
* change heredocs
* change outputs or messages
* change data or fixtures
* reformat files
* make pure whitespace changes outside comments
* create new files
* delete existing files
* rename files
* move code
* turn comments into code
* turn code into comments
* create scripts
* use scripts for editing
* create your own helper programs for editing
* perform automated bulk replacements
* blindly truncate comments
* merely shorten text to 60 characters
* invent information
* guess Issue or PR references
* accumulate historical references

If a necessary correction would touch production code, you MUST stop
and escalate to the coordinator.

You must not widen this boundary yourself.

## No Script-Based Editing

Scripts and automated transformation programs are forbidden for this
task.

Comment blocks must be judged semantically, one at a time.

A mechanical shortening by character count is explicitly forbidden.

A replacement is permitted only after you have understood:

1. what the associated code currently does
2. why the comment is required at this location
3. which statement is factually correct for the current code state
4. which reference actually applies to the current version

## AG-CODE-012 Target Format

Every edited comment MUST be sober, dry, and relate exclusively to the
current state.

Exactly one block per code location is permitted:

```text
What: <current behavior>
Why: <actual reason>
From: Issue #N | PR #N
```

If no valid reference is known and verified:

```text
What: <current behavior>
Why: <actual reason>
```

`From:` must never be invented.

The whole block is a hard ceiling of at most 3 physical lines when a
`From:` line applies, or 2 physical lines when it does not. Nothing may
expand it past that: no extra field, no wrapped `What:`/`Why:` text, no
continuation line, and no second block for the same location.

## What

`What:` is mandatory.

It MUST be exactly one physical line.

The complete physical line, including any leading indentation, the
`What:` tag, the colon and separator, and the content, may contain at
most 60 characters.

60 characters are NOT a target.

Shorter is explicitly preferred when the statement stays complete and
precise.

`What:` describes exclusively what the current code actually does.

It must not contain history or change history.

## Why

`Why:` is mandatory.

It MUST be exactly one physical line.

The complete physical line, including any leading indentation, the
`Why:` tag, the colon and separator, and the content, may contain at
most 60 characters.

60 characters are NOT a target.

Shorter is explicitly preferred when the actual reason is preserved.

`Why:` MUST state the real, non-obvious reason.

Permitted contents are for example:

* Constraint
* Invariant
* Security reason
* Workaround
* technical requirement
* non-obvious side effect

`Why:` must not simply repeat `What:` in other words.

## From

`From:` is permitted only when the reference has actually been
verified.

The line may contain at most one Issue and one PR reference.

It must not contain any explanation.

Permitted forms are exclusively:

```text
From: Issue #123
From: PR #456
From: Issue #123 | PR #456
```

The reference MUST belong to the current version of the commented code.

Historical or superseded references must not be accumulated.

If a reference cannot be reliably determined, it must not be guessed.

Use the existing Git history as well as Issue and PR history to verify
when needed.

## Examples

Compliant — each physical line at most 60 characters:

```text
# What: dispatches build-push for the nightly channel
# Why: nightly must rebuild the stack images daily
```

Non-compliant — a line over 60 characters. The `# What:` / `# Why:`
tag and every character on the physical line are counted:

```text
# What: this line runs well past sixty characters since the tag counts
# Why: every character on the physical line counts, so this one is too long
```

Non-compliant — three or more lines of free prose with no
`What:`/`Why:`/`From:` structure. This is a normal in-scope comment, not
a doc-block; it MUST become one What/Why/From block, with any overflow
rationale moved to a durable record:

```text
# this is a long explanatory paragraph that rambles across
# several comment lines with no What or Why or From structure
# and therefore must not be left as it is
```

## Sober and Dry

The comment MUST document exclusively the current state.

Not permitted are in particular:

* Storytelling
* investigation history
* review history
* change history
* time sequences
* earlier implementations
* abandoned approaches
* justifications of the editing process
* statements about what was wrong before
* statements about what was just fixed
* statements about how something was determined
* test or verification narratives

The comment is documentation of the current code, not a work log.

## No Blind Truncation

An existing comment MUST NOT simply be cut off until it fits under the
character limit.

You MUST first determine its technical statement.

Then you MUST reformulate that statement anew and as concisely as
possible.

If relevant historical or investigative information does not belong in
the permitted format, it must not be preserved through longer comments,
continuation lines, or additional comment blocks.

It belongs in the applicable durable work record. During active work
that means a GitHub commit comment on the commit that introduces the
change, unless a more authoritative location such as the Issue or PR
already holds it. It MUST NOT be kept in the comment.

## One Block per Location

A code location may have exactly one associated
`What:` / `Why:` / `From:` block.

You MUST NOT stack multiple blocks to circumvent the character limit.

You MUST NOT use:

```text
What: ...
What: ...
Why: ...
Why: ...
```

You MUST likewise not create continuation lines.

## Semantic Check

Before every change you MUST read the immediately associated code.

You may change a comment only when its new statement is supported by
the existing code.

If you cannot reliably determine the meaning of the code:

STOP.

Do not guess.

Do not simplify.

Do not delete.

Do not blindly reword.

Report the specific location to the coordinator.

## Existing Correct Comments

An already rule-compliant comment MUST NOT be changed artificially.

In particular, a short correct comment must not be lengthened only to
come closer to 60 characters.

Minimal, precise wording is desired.

Syntactic compliance alone is not sufficient. A block that already
looks like a valid `What:`/`Why:`/`From:` block MUST still be corrected
when its meaning, its reference, or the behavior it states no longer
matches the current code.

## Change Discipline

Before each file you MUST read its content.

After editing you MUST inspect the file's diff.

Only comment changes may appear in the diff.

As soon as a change outside a comment appears:

STOP.

Revert the unintended change.

Continue only when the diff again contains exclusively comments.

## No Side Work

This task authorizes no opportunistic improvements. This is literally a
DISACK.

Even if you find other problems during the work, you must not change
production code. Notify the coordinator or main thread, whichever is
your supervisor.

Problems outside the permitted comment scope you MUST report but not
fix yourself. Notify the coordinator or main thread, whichever is your
supervisor.

A rule from `AGENTS.md` must not be used as justification to widen this
explicit change boundary onto production code yourself. This is
literally a DISACK.

On a conflict you MUST report AND halt the work until it is clarified.
Notify the coordinator or main thread, whichever is your supervisor.
If you have another file to continue on, work on that one further, but
you MUST NOT keep editing the file that has a conflict until it is
clarified.

## Final Check

Before starting you MUST confirm:

* read AND understood the current `AGENTS.md` from `current_dev` in full
* read and accepted the current dispatch checklist in full
* checked `AG-CODE-012` against the current wording
* changed comments only
* changed no production logic
* created or used no scripts for transformation
* performed no blind truncation
* checked every changed statement against the associated code
* `What:` at most 60 characters
* `Why:` at most 60 characters
* did not treat 60 characters as a target
* used `From:` only with verified references
* created no stacked comment blocks
* created no continuation lines
* inspected the final diff in full
* confirmed that no comment violation remains anywhere in the audited
  file, including sections you did not otherwise touch

If even one point cannot be confirmed, the task must not be reported as
complete.

## Final Report

The final report MUST stay concise.

Report exclusively:

1. which files were checked
2. which files received comment changes
3. number of changed comment blocks
4. whether only comments were changed
5. whether all character limits were checked
6. whether any unresolved locations remain

DISACK: Do not perform any additional implementation work.

## Agent Dispatch Checklist

This file is the fixed, mandatory minimum standard baseline for every Agent()/SendMessage()/Workflow agent() call in this repository — both an initial dispatch and every later continuation message to an already-running or paused agent, always, regardless of reason. A specific dispatch may always add more or stricter requirements on top of this list — it may never satisfy less than what is listed here. It exists because relying on the dispatcher to recall the relevant subset of AGENTS.md from memory, per task, has repeatedly failed in practice (see AG-WF-035's own incident note). This file turns that recall problem into a fixed list to paste and check off, not a thing to remember.

How to use this file: Paste this entire checklist verbatim into every dispatch/continuation prompt. If any item is deliberately omitted for a specific dispatch, the prompt must say so explicitly and state why — a silent omission is a compliance gap, not a judgment call the dispatcher gets to make invisibly.

Do
Governance read, every dispatch, every continuation. (AG-GOV-001)
Explicit-by-name acceptance report, spot-checked by asking for a quoted rule ID. This report must also remind the coordinator to send back this agent's own task/session ID (via SendMessage, or whichever equivalent applies) — an agent cannot determine that ID on its own, so it must be relayed before the marker commit in item 5 below can include it.
Worktree binding, named and absolute, verified before every commit via git rev-parse --show-toplevel/git branch --show-current. (AG-WF-002, AG-WF-024)
Rebase-first onto the current base before any work begins — AND re-verify the rebase is still current immediately before declaring the task finished, not only at the start. (AG-WF-002)
Empty marker commit, first action, before any code change. The commit message must state the task/issue binding, that this checklist was read and accepted, AND your own task/session ID — the confirmation lives as a durable, git-anchored artifact tied to the worktree, not only as a chat statement, and must remain reachable/resumable independent of worktree naming or surviving chat history. (AG-WF-002, AG-WF-017)
Language split, stated explicitly: prose/reports German, GitHub content English. This applies to the dispatch prompt's own instructional prose too, not only to the agent's output — pasting this checklist (English, quoted verbatim per its own instruction above) does not license writing the surrounding task description in English; only literal quoted material (code, log output, file paths, commit messages, GitHub content) stays English. (AG-CC-002/003, AG-GH-001)
CLD-<unixtime> identity marker on every GitHub-visible write, and on every marker commit — obtained fresh via date +%s at write time, never invented/estimated. (AG-WF-017)
WIP cadence: within 15 min, then every 15 min, real timestamp comparison. (AG-GH-013)
Check for existing coverage before starting new branch/investigation work. (AG-GH-017)
Read full chronological history before acting on any issue/PR. (AG-GH-019)
Push/PR authorization boundary, stated explicitly per dispatch.
--admin/bypass boundary: literal PR-scoped "ACK" via the structured question. (AG-WF-039)
Durable persistence before declaring done. (AG-WF-026)
Before declaring "I think I am done": call advisor and check the ENTIRE PR/diff — every file it touches — against AGENTS.md as a whole, not just the task's own narrow focus. Advisor must not stop at the first finding; it must enumerate ALL violations found. Re-verify the branch is still rebased onto current base (see item 4) before the completion report. Most real problems in this project trace back to an AGENTS.md violation somewhere in the touched files — treat the whole PR as the unit of review, not only the lines changed for the stated task. (AG-WF-035, AG-WF-033, AG-WF-011)
Treat prior results as stale until reverified. (AG-WF-021)
Poll intervals ≥300s, with no exception, ever — a poll faster than 300s counts as a DISACK-equivalent violation at any moment it occurs. (AG-CI-020)
Remove the worktree once finished (pushed/PR opened, or explicitly told to stop) — a leftover worktree becomes the next agent's recycled-slot collision otherwise. (AG-WF-002)
Apply AGENTS.md in full — no shortcuts, no cherry-picking only the parts that seem relevant to the immediate task.
Prefer native local commands over an API call at any time, instead and/or before an API call — use the API when there is no local equivalent. (AG-VAL-005)
New file = formal DISACK by default. Before creating any new script, library, or test-suite file, complete the required search: does an existing file already own the same conceptual class/responsibility (extend it), or do related sibling files already exist that should be consolidated instead? State the result of this check in the PR. The DISACK lifts only by extending an existing file, or by a documented check plus an explicit maintainer/coordinator ACK obtained before the file is created. (AG-CODE-013)
Ground every factual claim in evidence actually obtained — a file actually read, a command actually run, an output actually observed. State what was checked, not just the conclusion. A statement's strength must never exceed the evidence behind it: label anything unverified as such ("not verified"/"not tested") instead of presenting a plausible guess as fact. (AG-INT-001)
Don't
Not allowed to spawn own sub-agents unless the task explicitly authorizes coordinating them — flagged: not yet backed by a numbered AGENTS.md rule.
A pause/stop is lifted only by a fresh literal "ACK." (AG-WF-038)
Never a mutating git command against the shared main checkout, under any circumstance. Never lie, invent, or attempt to misrepresent what happened. If unsure, stop and ask the coordinator for verification/clarification — do not continue until that clarification is satisfied. (AG-INT-001)
Never trust a recycled or unfamiliar worktree as clean without verifying it first. If it's not what you were told to expect, stop and clarify with your coordinator before doing any work in it. (AG-WF-024)
Never declare multi-item work "complete" from memory — recount against the full list.
Never downgrade a verification requirement to "stichprobenartig" without explicit authorization.
Fix a found defect in the same pass, don't defer to a comment. (AG-WF-027)
Treat a found bug as a failure class, search the rest of the codebase for the same pattern. (AG-WF-011, AG-CI-015)
Never work or commit in an unverified/unknown worktree. Before committing, confirm the worktree actually exists and matches what you were told — if unsure, ask your coordinator and do not proceed without an answer.
Never let an English quoted artifact (this checklist, a code snippet, a log excerpt) justify writing your own surrounding instructional prose in English. (AG-CC-003)
Never create a new file because it is more convenient than reading/extending an existing one, and never create the file first and ask for the ACK afterward. A plausible-sounding reason for a new file is not itself an ACK. If genuinely uncertain whether an existing file should be extended instead, stop and ask the coordinator — do not create the file while that is unresolved. (AG-CODE-013)
Never suppress, filter, downgrade, or hide a real warning/error/failure signal to make a check appear to pass (|| true, redirecting stderr, excluding a failing target from scope, relabeling a failure as expected/skipped, retrying silently until green, etc.). A check that genuinely doesn't apply gets an explicit SKIP/NOT-RUN with a stated reason — never execute-and-discard. (AG-INT-002)
[AG-LAW-001] AGENTS.md is a single, unified rulebook: all applicable rules apply simultaneously to the entire affected change, not only the rule that motivated it. A task is not complete until the entire affected file and the complete change have been checked against every applicable rule — checking only some applicable rules and then declaring the task done is itself a violation of AG-LAW-001. "You touched it, you fix it" (Rule-Ref: AG-WF-027, not AG-CODE-008 — that one is comment-specific) applies to the entire affected file: known violations found along the way must be fixed within the same piece of work, not deferred to a follow-up comment. Shortcuts and deferral are not allowed. Any uncertainty about how to proceed must be escalated up the dispatch chain to the main thread (Rule-Ref: AG-WF-002's escalation clause), which resolves it directly or obtains a decision.
