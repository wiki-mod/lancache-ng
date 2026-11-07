# How to Audit Documentation

This policy defines how every document under `docs/` is audited against the
code and against `AGENTS.md`. It applies to each file that carries the section
"Howto audit this file".

## Contents

1. [Scope](#1-scope)
2. [Binding rules](#2-binding-rules)
3. [Preconditions](#3-preconditions)
4. [Procedure](#4-procedure)
5. [Gates](#5-gates)
6. [Evidence classes](#6-evidence-classes)
7. [Form of a document](#7-form-of-a-document)
8. [Conflicts](#8-conflicts)
9. [Section in each document](#9-section-in-each-document)
10. [Special deviations](#10-special-deviations)
11. [Audit record](#11-audit-record)

## 1. Scope

| Item | Value |
| --- | --- |
| Audited | Every `docs/**/*.md` file |
| Reference | The code and configuration of the audited commit |
| Result | Each statement is supported by evidence or removed |

## 2. Binding rules

`AGENTS.md` is one rulebook (`AG-LAW-001`). An audit passes only when every
applicable rule passes; passing one rule does not establish compliance.

| Rule | Requirement for an audit |
| --- | --- |
| `AG-LAW-001` | All applicable rules apply to the audited change as a whole |
| `AG-INT-001` | A factual claim needs evidence obtained in the audit; claim scope does not exceed evidence scope |
| `AG-INT-002` | Results represent observed reality; adverse evidence is not hidden |
| `AG-DOC-001` | Relevant documentation matches the implementation; stale documentation blocks completion |
| `AG-DOC-002` | Verified code behavior is ground truth; a document that contradicts it is stale |
| `AG-DOC-008` to `AG-DOC-010` | A source conflict is not resolved silently; it is corrected or escalated |
| `AG-GH-001` | GitHub-visible content, including documentation, is English |
| `AG-CODE-011` | Reasoning, search before, search after and one canonical owner are recorded per change |
| `AG-VAL-016` | Verification runs in the matching `build-tools` environment |
| `AG-WF-026` | Substantive knowledge is persisted in a durable record |

## 3. Preconditions

- `AGENTS.md` is read in full, not in excerpts.
- The audit target is one commit; its short hash is recorded.
- The checkout is a worktree of the audit task; the base is fetched.
- Every rule cited by the document is read in its complete text.

## 4. Procedure

| Step | Action | Evidence |
| --- | --- | --- |
| 1 | Record the audited commit and any dependent pull request | Marker in the document |
| 2 | List every statement about code, configuration, behavior, command, path, key, route, port or default | Statement list |
| 3 | Search every backticked identifier with `git grep`; test every path with `test -e` | A name without a hit is stale |
| 4 | Read the owning code of each behavior statement: function, callers, defaults, alternate paths | File and function |
| 5 | Prove every negative statement with a documented search pattern and its scope | Pattern and result |
| 6 | Read each value in `.github/yaml/build-manifest.yml`: key, default, owner | SOT key |
| 7 | Search all documents for the same names and keys | List of hits |
| 8 | Check the form (section 7) | Word search |
| 9 | Run the checks below in the `build-tools` container | Exit status per check |
| 10 | Record the audit (section 11) | Commit message |

Checks of step 9 (`bash .github/scripts/ci.sh check <name>`):
`line-endings`, `language-policy`, `governance-guards`, `naming-consistency`,
`proxy-cache-env-doc-drift`, `exit-evidence`; and `git diff --check`.

## 5. Gates

An audit passes only when every gate is met. A gate without evidence is not
met.

| Gate | Criterion | Evidence | Step |
| --- | --- | --- | --- |
| G1 | `AGENTS.md` and every rule cited by the document are read in full | Statement in the audit record | 3 |
| G2 | The audited commit and dependent pull requests are recorded | Marker in the document | 1 |
| G3 | Every backticked identifier and path exists | Search result with zero misses | 3 |
| G4 | Every behavior statement is backed by read code | File and function | 4 |
| G5 | Every negative statement has a search pattern and scope | Pattern and result | 5 |
| G6 | Every value or default is read from its SOT key | Key and owner | 6 |
| G7 | No other document contradicts the statement | Search result across `docs/` | 7 |
| G8 | The form word search has no history or narrative hit | Search result | 8 |
| G9 | Every listed check has exit status 0 | Exit status per check | 9 |
| G10 | The audit record is complete | Commit message | 10 |

## 6. Evidence classes

| Class | Basis | Allowed wording |
| --- | --- | --- |
| Observed | A command executed in the audit | The result, with command and exit status |
| Static | Code read, not executed | "The code does X" with file and function |
| Hypothesis | Inference from static evidence | "It appears" or "if" |
| Unknown | No evidence | Not stated |

Reading code does not prove runtime behavior. A runtime statement needs an
observed result; without it the document states the static fact only.

## 7. Form of a document

- It states the current state, in the present tense.
- It contains no history, narrative, storytelling, rationale of how a
  conclusion was reached, or comparison with earlier states.
- One fact per sentence; lists and tables for enumerations.
- Each capability or mitigation names its evidence (file, function, SOT key or
  route).
- Risk ratings and design intent are marked as assessments, not as code facts.
- It does not copy a value that has an owner in the SOT; it names the key.

Word search for step 8: `earlier`, `previously`, `no longer`, `used to`,
`has been`, `was`, `were`, `now`, `legacy`, `old`.

## 8. Conflicts

| Conflict | Resolution |
| --- | --- |
| Document against verified code | The code governs (`AG-DOC-002`); the document is corrected |
| Document against `SECURITY.md` | `SECURITY.md` takes precedence for security behavior (`AG-DOC-005`) unless verified code contradicts it |
| Two documents | The one that governs its scope (`AG-DOC-006`) prevails; the other is corrected |
| Code against a rule of `AGENTS.md` | The finding is reported to the maintainer (`AG-DOC-009`); the document names the code behavior and the rule |
| Unresolvable | Escalation with sources and verified behavior (`AG-DOC-009`) |

## 9. Section in each document

Every `docs/**/*.md` file ends with this section:

```text
## Howto audit this file

The audit procedure of this file is `docs/policy/howto-audit-documentation.md`.
```

## 10. Special deviations

The procedure is general. A file that needs a step to differ gets its own
subsection at the end of "Howto audit this file", headed "Special deviation",
that states:

| Field | Content |
| --- | --- |
| Step | The number of the step that differs |
| Reason | The property of the file that requires it |
| Replacement | The step that applies to this file |

A file without such a subsection follows the procedure unchanged.

## 11. Audit record

The commit that changes the document records:

| Field | Content |
| --- | --- |
| Audited commit | Short hash in the document marker |
| Search before and after | Files referenced by `SEARCH-BEFORE` and `SEARCH-AFTER` |
| Checks | The file referenced by `CHECKS`, with exit status per check |
| Confirmation | The sentence required by `AG-CODE-011` |

## Howto audit this file

The audit procedure of this file is section 4 of this policy, applied to this
file.
