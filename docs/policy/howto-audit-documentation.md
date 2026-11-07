# How to Audit Documentation

This policy defines how every document under `docs/` and the files `ROADMAP.md`,
`MAINTAINERS.md`, `GOVERNANCE.md` and `CODE_OF_CONDUCT.md` are audited against the code, the tracking items and `AGENTS.md`. It applies
to each file that carries the section "Howto audit this file".

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
| Audited | Every `docs/**/*.md` file, `ROADMAP.md`, `MAINTAINERS.md`, `GOVERNANCE.md` and `CODE_OF_CONDUCT.md` |
| Reference | The code and configuration of the audited commit |
| Result | Each statement is supported by evidence or removed |

## 2. Binding rules

`AGENTS.md` is one rulebook (`AG-LAW-001`). Every applicable rule applies to
the audited change at the same time.

A rule is read in its complete text (`AG-WF-035`, `AG-WF-044`). This policy
names rules by identifier only and does not restate their content. A partial
quotation or a paraphrase of a rule does not replace reading it.

| Topic of the audit | Rules to read in full |
| --- | --- |
| Rulebook as a whole | `AG-LAW-001` to `AG-LAW-004` |
| Evidence and results | `AG-INT-001`, `AG-INT-002` |
| Documentation and precedence | `AG-DOC-001` to `AG-DOC-011` |
| Language of GitHub-visible content | `AG-GH-001` |
| Change evidence and ownership | `AG-CODE-011`, `AG-CODE-013` |
| Verification environment | `AG-VAL-016` |
| Durable record | `AG-WF-026` |
| Reading and acceptance | `AG-WF-035`, `AG-WF-044` |

## 3. Preconditions

- `AGENTS.md` is read in full, not in excerpts (`AG-WF-035`, `AG-WF-044`).
- The audit target is one commit; its full HEAD hash (40 hexadecimal digits) is
  recorded.
- The checkout is a worktree of the audit task; the base is fetched.
- Every rule cited by the document is read in its complete text.

## 4. Procedure

| Step | Action | Evidence |
| --- | --- | --- |
| 1 | Record the full HEAD hash of the audited commit and of each dependent pull request | Marker in the document |
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
| G2 | The full HEAD hash of the audited commit and of each dependent pull request is recorded | Marker in the document | 1 |
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

Each statement of the audited document has exactly one class. The class
decides the wording (`AG-INT-001`, read in full).

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

A conflict between sources is handled under the rules below, read in full. The
audit record names the conflicting sources, the verified behavior and the rule
applied.

| Conflict | Rules |
| --- | --- |
| Document against code | `AG-DOC-002`, `AG-DOC-010` |
| Document against `SECURITY.md` | `AG-DOC-002`, `AG-DOC-005` |
| Two documents | `AG-DOC-004` to `AG-DOC-007` |
| Code against a rule of `AGENTS.md` | `AG-DOC-008`, `AG-DOC-009` |
| Not resolvable from the sources | `AG-DOC-009` |

## 9. Section in each document

Every `docs/**/*.md` file, `ROADMAP.md`, `MAINTAINERS.md`, `GOVERNANCE.md` and
`CODE_OF_CONDUCT.md` end with this section:

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
| Audited commit | Full HEAD hash in the document marker |
| Search before and after | Files referenced by `SEARCH-BEFORE` and `SEARCH-AFTER` |
| Checks | The file referenced by `CHECKS`, with exit status per check |
| Confirmation | The sentence required by `AG-CODE-011` |

## Howto audit this file

The audit procedure of this file is section 4 of this policy, applied to this
file.
