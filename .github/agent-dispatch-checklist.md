# Agent Dispatch Checklist

This file is the fixed, mandatory **minimum standard** baseline for every `Agent()`/`SendMessage()`/`Workflow` `agent()` call in this repository — both an **initial dispatch** and every **later continuation message** to an already-running or paused agent, **always, regardless of reason**. A specific dispatch may always add more or stricter requirements on top of this list — it may never satisfy less than what is listed here. It exists because relying on the dispatcher to recall the relevant subset of AGENTS.md from memory, per task, has repeatedly failed in practice (see AG-WF-035's own incident note). This file turns that recall problem into a fixed list to paste and check off, not a thing to remember.

**How to use this file:** Paste this entire checklist verbatim into every dispatch/continuation prompt. If any item is deliberately omitted for a specific dispatch, the prompt must say so explicitly and state why — a silent omission is a compliance gap, not a judgment call the dispatcher gets to make invisibly.

---

## Do

1. **Governance read, every dispatch, every continuation.** (AG-GOV-001)
2. **Explicit-by-name acceptance report**, spot-checked by asking for a quoted rule ID. This report must also remind the coordinator to send back this agent's own task/session ID (via `SendMessage`, or whichever equivalent applies) — an agent cannot determine that ID on its own, so it must be relayed before the marker commit in item 5 below can include it.
3. **Worktree binding, named and absolute**, verified before every commit via `git rev-parse --show-toplevel`/`git branch --show-current`. (AG-WF-002, AG-WF-024)
4. **Rebase-first** onto the current base before any work begins — AND re-verify the rebase is still current immediately before declaring the task finished, not only at the start. (AG-WF-002)
5. **Empty marker commit, first action, before any code change.** The commit message must state the task/issue binding, that this checklist was read and accepted, AND your own task/session ID — the confirmation lives as a durable, git-anchored artifact tied to the worktree, not only as a chat statement, and must remain reachable/resumable independent of worktree naming or surviving chat history. (AG-WF-002, AG-WF-017)
6. **Language split, stated explicitly**: prose/reports German, GitHub content English. This applies to the dispatch prompt's own instructional prose too, not only to the agent's output — pasting this checklist (English, quoted verbatim per its own instruction above) does not license writing the surrounding task description in English; only literal quoted material (code, log output, file paths, commit messages, GitHub content) stays English. (AG-CC-002/003, AG-GH-001)
7. **`CLD-<unixtime>` identity marker** on every GitHub-visible write, and on every marker commit — obtained fresh via `date +%s` at write time, never invented/estimated. (AG-WF-017)
8. **WIP cadence**: within 15 min, then every 15 min, real timestamp comparison. (AG-GH-013)
9. **Check for existing coverage** before starting new branch/investigation work. (AG-GH-017)
10. **Read full chronological history** before acting on any issue/PR. (AG-GH-019)
11. **Push/PR authorization boundary**, stated explicitly per dispatch.
12. **`--admin`/bypass boundary**: literal PR-scoped "ACK" via the structured question. (AG-WF-039)
13. **Durable persistence before declaring done.** (AG-WF-026)
14. **Before declaring "I think I am done": call `advisor` and check the ENTIRE PR/diff — every file it touches — against AGENTS.md as a whole, not just the task's own narrow focus.** Advisor must not stop at the first finding; it must enumerate ALL violations found. Re-verify the branch is still rebased onto current base (see item 4) before the completion report. Most real problems in this project trace back to an AGENTS.md violation somewhere in the touched files — treat the whole PR as the unit of review, not only the lines changed for the stated task. (AG-WF-035, AG-WF-033, AG-WF-011)
15. **Treat prior results as stale until reverified.** (AG-WF-021)
16. **Poll intervals ≥300s, with no exception, ever — a poll faster than 300s counts as a DISACK-equivalent violation at any moment it occurs.** (AG-CI-020)
17. **Remove the worktree once finished** (pushed/PR opened, or explicitly told to stop) — a leftover worktree becomes the next agent's recycled-slot collision otherwise. (AG-WF-002)
18. **Apply AGENTS.md in full — no shortcuts, no cherry-picking only the parts that seem relevant to the immediate task.**
19. **Prefer native local commands over an API call at any time, instead and/or before an API call — use the API when there is no local equivalent.** (AG-VAL-005)
20. **New file = formal DISACK by default.** Before creating any new script, library, or test-suite file, complete the required search: does an existing file already own the same conceptual class/responsibility (extend it), or do related sibling files already exist that should be consolidated instead? State the result of this check in the PR. The DISACK lifts only by extending an existing file, or by a documented check plus an explicit maintainer/coordinator ACK obtained *before* the file is created. (AG-CODE-013)
21. **Ground every factual claim in evidence actually obtained — a file actually read, a command actually run, an output actually observed.** State what was checked, not just the conclusion. A statement's strength must never exceed the evidence behind it: label anything unverified as such ("not verified"/"not tested") instead of presenting a plausible guess as fact. (AG-INT-001)

## Don't

1. **Not allowed to spawn own sub-agents** unless the task explicitly authorizes coordinating them — flagged: not yet backed by a numbered AGENTS.md rule.
2. **A pause/stop is lifted only by a fresh literal "ACK."** (AG-WF-038)
3. **Never a mutating git command against the shared main checkout, under any circumstance.** Never lie, invent, or attempt to misrepresent what happened. If unsure, stop and ask the coordinator for verification/clarification — do not continue until that clarification is satisfied. (AG-INT-001)
4. **Never trust a recycled or unfamiliar worktree as clean without verifying it first.** If it's not what you were told to expect, stop and clarify with your coordinator before doing any work in it. (AG-WF-024)
5. **Never declare multi-item work "complete" from memory** — recount against the full list.
6. **Never downgrade a verification requirement to "stichprobenartig"** without explicit authorization.
7. **Fix a found defect in the same pass**, don't defer to a comment. (AG-WF-027)
8. **Treat a found bug as a failure class**, search the rest of the codebase for the same pattern. (AG-WF-011, AG-CI-015)
9. **Never work or commit in an unverified/unknown worktree.** Before committing, confirm the worktree actually exists and matches what you were told — if unsure, ask your coordinator and do not proceed without an answer.
10. **Never let an English quoted artifact (this checklist, a code snippet, a log excerpt) justify writing your own surrounding instructional prose in English.** (AG-CC-003)
11. **Never create a new file because it is more convenient than reading/extending an existing one, and never create the file first and ask for the ACK afterward.** A plausible-sounding reason for a new file is not itself an ACK. If genuinely uncertain whether an existing file should be extended instead, stop and ask the coordinator — do not create the file while that is unresolved. (AG-CODE-013)
12. **Never suppress, filter, downgrade, or hide a real warning/error/failure signal to make a check appear to pass** (`|| true`, redirecting stderr, excluding a failing target from scope, relabeling a failure as expected/skipped, retrying silently until green, etc.). A check that genuinely doesn't apply gets an explicit SKIP/NOT-RUN with a stated reason — never execute-and-discard. (AG-INT-002)

---

**[AG-LAW-001]** AGENTS.md is a single, unified rulebook: all applicable rules apply simultaneously to the entire affected change, not only the rule that motivated it. A task is not complete until the entire affected file and the complete change have been checked against every applicable rule — checking only some applicable rules and then declaring the task done is itself a violation of AG-LAW-001. "You touched it, you fix it" (Rule-Ref: AG-WF-027, not AG-CODE-008 — that one is comment-specific) applies to the entire affected file: known violations found along the way must be fixed within the same piece of work, not deferred to a follow-up comment. Shortcuts and deferral are not allowed. Any uncertainty about how to proceed must be escalated up the dispatch chain to the main thread (Rule-Ref: AG-WF-002's escalation clause), which resolves it directly or obtains a decision.
