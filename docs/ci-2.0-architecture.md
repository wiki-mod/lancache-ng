# LanCache-NG CI 2.0 Architecture Plan

Status: design document, not yet implemented. Tracked by issue #1683 ("CI 1.2
Re-Write & all thematics around it"), which links here for the full text and
carries day-to-day status/progress notes. This file is the durable,
version-controlled home for the architecture itself.

Authored by the maintainer, refined in review with Claude Code across
issue #1683 and this document. Original design in German; translated to
English per this repository's AG-GH-001 (GitHub-bound content is English).
Diagrams and section numbering (1-92) are preserved from the original for
traceability; sections 93+ and "Open Decisions" were added during review to
capture refinements made after the original 92 sections were written.

`build-push.yml` is not a template for CI 2.0. It is a source of existing
requirements, a collection of historically grown guards, a record of real
failure classes that occurred in production, and a source of existing
release/security/validation invariants. Its implementation structure is not
carried forward.

## 1. Goal

CI 2.0 replaces today's organically grown CI architecture with a
content-based, state-oriented pipeline.

CI should not ask:

```text
What did GitHub just trigger?
```

but instead:

```text
What desired state follows from this content?

Does that state already exist?

If yes:
    do nothing, or reuse the existing result.

If no:
    perform only the work that is actually missing.
```

Principle:

```text
A CI run is not an order to build.

A CI run determines whether any work is required
to reach the desired verified state.
```

## 2. Non-negotiable core rules

```text
DEFAULT = NOOP

BUILD = DISACK

UNKNOWN != BUILD
```

These three rules take precedence over every optimization that follows.

### 2.1 DEFAULT = NOOP

A new CI run authorizes no work at all by default.

Default state:

```text
NOOP
```

Not: `BUILD`. Not: `REUSE`. Not: `SCAN`. Not: `TEST`. Not: `RETAG`.

Every additional unit of work requires a demonstrable reason.

### 2.2 BUILD = DISACK

A build is forbidden by default.

```text
BUILD = DISACK
```

Only a proven semantic impact on the desired build result may create a build
candidate. After that, it must additionally be established that no already
accepted artifact satisfies exactly this desired state. Only then:

```text
BUILD = ACK
```

### 2.3 UNKNOWN != BUILD

Uncertainty is never a license to build. The following states must be
handled separately:

```text
PRESENT_ACCEPTED
MISSING_CONFIRMED
BUILD_IN_PROGRESS
PRODUCED_UNVERIFIED
MISMATCH
UNKNOWN
```

Only `MISSING_CONFIRMED`, reached after a semantic `BUILD_ACK` has already
been established, may trigger a build.

Examples:

```text
Registry unreachable
-> UNKNOWN
-> retry registry operation
-> possibly BLOCK/FAIL
-> NO BUILD

Authentication failed
-> UNKNOWN
-> renew auth
-> retry
-> NO BUILD

Digest lookup timeout
-> UNKNOWN
-> retry lookup
-> NO BUILD

Build already running on another runner
-> BUILD_IN_PROGRESS
-> wait / re-resolve
-> NO second build

Build succeeded, but registry readback
does not find it yet
-> PRODUCED_UNVERIFIED
-> check publish/index/registry
-> NO second build

Digest does not match
-> MISMATCH
-> FAIL
-> NO replacement build
```

## 3. Priority order

CI 2.0 always decides in this order:

```text
1. NOOP
2. cheap semantic content check
3. reuse an existing ACCEPTED result
4. only the tests/validations actually required
5. BUILD only on proven necessity
6. use maximum cache within the build
7. publish an immutable result
8. read the published result back
9. verify exactly this digest
10. ACCEPT or REJECT the artifact
11. ASSEMBLE the full candidate
12. VALIDATE the full candidate
13. PROMOTE atomically
14. CONSUME
```

## 4. Target structure

CI-specific business logic is reduced to two central files:

```text
scripts/
└── ci/
    ├── ci.sh
    └── ci.bats
```

Meaning:

```text
ci.sh
-> the single authoritative CI implementation

ci.bats
-> the single authoritative CI regression suite
```

File size is explicitly not a criterion for splitting. A large file with one
coherent responsibility is allowed.

### 4.1 ci.sh

`ci.sh` centrally contains: service inventory, service dependencies,
semantic impact detection, build identity, test identity, validation
identity, build admission, artifact resolver, artifact acceptance, build
locking, retry classification, registry operations, build operations, test
selection, scan selection, multi-arch assembly, stack assembly, stack
validation, promotion, nightly, release, GC decisions, cache configuration,
runner/platform metadata, central error classification.

### 4.2 ci.bats

`ci.bats` centrally tests: core invariants, NOOP, comment-only changes,
service impact, dependency impact, build identity, test identity, artifact
resolver, UNKNOWN behavior, retry behavior, build admission, cache fallback,
registry errors, digest validation, assembly, promotion, GC, service-specific
rules, historical regressions.

## 5. No more CI logic in YAML

`.github/workflows/*.yml` become thin orchestrators. YAML only answers:

```text
When does something start?
Which runner is needed?
Which permissions are needed?
Which job does this job depend on?
Which ci.sh command is executed?
```

YAML no longer decides: whether DNS really needs to be built, whether proxy
is affected, whether a registry error produces a build, which digest is
accepted, which service is reusable, which retry makes sense, which files
are build inputs, which test is necessary.

These decisions belong exclusively in `scripts/ci/ci.sh`.

## 6. Target workflows

CI-related workflows should be reduced to roughly these roles:

```text
.github/workflows/

ci.yml
nightly.yml
release.yml
gc.yml
codeql.yml
```

Administrative GitHub workflows such as labeler, project automation, or
first-interaction bots are not part of the actual build pipeline and may
remain separate.

### 6.1 ci.yml

Responsibility: PR, push, or manual CI run -> plan -> required jobs -> final
required check.

### 6.2 nightly.yml

Responsibility: `current_dev` -> determine the desired nightly state -> use
existing ACCEPTED artifacts -> produce only the missing ones -> validate the
full stack -> move `nightly` atomically.

### 6.3 release.yml

Responsibility: release -> determine the exact accepted candidate ->
re-validate if release policy requires it -> NO unnecessary rebuild ->
atomic promotion -> GitHub Release -> SBOM/VEX/provenance.

### 6.4 gc.yml

Responsibility: determine reachability -> protected artifacts ->
unreferenced artifacts -> cache lifecycle -> safe deletion.

## 7. Central service list

There is exactly one authoritative service list.

Current members:

```bash
CI_SERVICES=(
    proxy
    dns
    watchdog
    dhcp
    dhcp-proxy
    ntp
    syslog
    ui
    build-tools
    utilities
)
```

No workflow contains a second list. No scan contains a second list. No
release contains a second list. No GC contains a second list. No multi-arch
job contains a second list. No full-setup job contains a second list.

> **Open decision (found during review, not yet resolved):** `services/netdata/Dockerfile`
> exists as a first-party Dockerfile but is currently **not** in
> `CI_BUILD_SERVICES` on `current_dev`. This must be decided deliberately
> before the service list is frozen for CI 2.0 — either "netdata is part of
> the CI 2.0 artifact pipeline" or "netdata is explicitly out of scope" —
> and recorded here. It must not stay missing by accident, which is exactly
> the drift class this single-authoritative-list mechanism exists to
> prevent.

## 8. Central service metadata

`ci.sh` has exactly one service definition.

Conceptually:

```text
service:
    name
    build context
    external build contexts
    platforms
    runner class
    compiler class
    build dependencies
    runtime dependencies
    test domains
    validation domains
    artifact repository
```

Example:

```text
proxy:
    context = services/proxy
    external-context = services/dns
    platforms = amd64,arm64
    runner = light

dns:
    context = services/dns
    platforms = amd64,arm64
    runner = heavy
    rust = true

utilities:
    context = services/utilities
    platforms = amd64,arm64
    runner = heavy
    c-compile = true
```

GitHub matrices are generated from this. Not the other way around.

## 9. Central CLI contract

Example:

```bash
./scripts/ci/ci.sh plan
./scripts/ci/ci.sh impact
./scripts/ci/ci.sh identity proxy
./scripts/ci/ci.sh resolve proxy linux/amd64
./scripts/ci/ci.sh test proxy
./scripts/ci/ci.sh build proxy linux/amd64
./scripts/ci/ci.sh publish proxy linux/amd64
./scripts/ci/ci.sh verify proxy <digest>
./scripts/ci/ci.sh assemble proxy
./scripts/ci/ci.sh validate
./scripts/ci/ci.sh promote nightly
./scripts/ci/ci.sh promote latest
./scripts/ci/ci.sh gc
```

For GitHub:

```bash
./scripts/ci/ci.sh plan --json
```

returns machine-readable state.

## 10. Planner

The planner is always the first CI stage. It builds nothing. It scans no
containers. It retags nothing. It does not need a heavy runner.

### 10.1 Planner input

```text
event
base full SHA
head full SHA
branch
PR metadata
repository state
```

Git commit identifiers must always be full-length.

### 10.2 Planner output

Example:

```json
{
  "global": {
    "state": "WORK_REQUIRED"
  },
  "services": {
    "proxy": {
      "state": "NOOP"
    },
    "dns": {
      "state": "TEST_REQUIRED",
      "build_ack": false
    },
    "ui": {
      "state": "ARTIFACT_REQUIRED",
      "build_ack": false
    }
  }
}
```

A planner may never directly convert `changed = true` into `build = true`.

## 11. Semantic impact detection

`git diff` is only the cheap first filter.

```text
git diff
-> determine candidates
-> check semantically
-> determine actual impact
```

Git paths are never the final truth.

### 11.1 Example: comment change

```text
services/dns/entrypoint.sh

# explanation changed

-> shell semantics identical
-> build identity identical
-> test identity identical
-> NOOP
```

### 11.2 YAML comment

```text
docker-compose.yml

# wording changed

-> YAML data structure identical
-> runtime identity identical
-> NOOP
```

### 11.3 Bats comment

```text
ci.bats

# explanation changed

-> test code semantically identical
-> test identity identical
-> NOOP
```

### 11.4 Real test change

```text
ci.bats
-> test logic changed
-> test identity changed
-> run tests
-> NO automatic container build
```

## 12. Semantic normalization

For each file type, the relevant semantics are normalized.

Concept:

```text
input
  |
  v
parser
  |
  v
strip comments / formatting
  |
  v
keep semantically relevant directives
  |
  v
canonical representation
  |
  v
SHA256
```

Do not use `SHA256(raw_file_bytes)` when pure formatting or comments are
irrelevant.

### 12.1 Shell / Bats

Ignore: ordinary comments, blank lines, formatting.

Keep: commands, arguments, variables, here-docs, control flow,
ShellCheck/tool directives if they change the behavior of the relevant
check.

### 12.2 YAML

Canonicalize: parse YAML -> strip comments -> keep key/value semantics ->
canonical representation.

### 12.3 Dockerfile

Consider: `FROM`, `RUN`, `COPY`, `ADD`, `ARG`, `ENV`, `WORKDIR`, build
context, named context, parser directives, all build-relevant instructions.

BuildKit's `docker buildx build --call check` is additionally used as a
Dockerfile linter.

### 12.4 Markdown

Markdown is `NOOP` by default, unless the specific file is demonstrably a
real build, runtime, test, or release input.

### 12.5 Phase-1 scope (added during review)

Full semantic-equivalence normalization for four different grammars (shell,
YAML, Dockerfile, Markdown) is a real implementation project, not a helper
script — this repository's own `AG-VAL-036` exists precisely because a
single `FROM`-line matcher in one format needed four review rounds for four
grammar variations of one construct. Combined with `AG-REL-001` (no new
runtime languages; Rust/shell only), a robust semantic YAML/Dockerfile
normalizer in bash is nontrivial.

Phase 1 therefore starts with a deliberately narrow v1, not full AST
equivalence:

```text
v1:
- ignore pure comment lines
- ignore blank lines
- normalize CRLF/LF
- ignore known non-semantic formatting differences

later:
- add real parsers/canonicalization where they have a demonstrated payoff
```

This keeps normalization from blocking the start of CI 2.0.

## 13. Dependency graph

CI 2.0 knows real dependencies. Example from the current project:

```text
services/dns/cdn-domains.txt
        |
        +-> dns
        |
        +-> proxy
            because proxy consumes this content
            through a named build context
```

Therefore: file path != service boundary. The build graph is authoritative.

## 14. Identity domains

At least the following identities are kept separate.

### 14.1 Git Identity

```text
full Git SHA
```

Meaning: where did the change come from? Not: what must be built?

### 14.2 Build Identity

Meaning: which semantic inputs determine the artifact?

### 14.3 Test Identity

Meaning: which tests and test inputs apply?

### 14.4 Validation Identity

Meaning: under which security/validation policy was this specific digest
checked?

### 14.5 Artifact Identity

```text
sha256:<64 hex>
```

Meaning: which exact OCI bytes were produced?

### 14.6 Assembly Identity

Meaning: which complete set of accepted service digests makes up this
stack?

## 15. Full SHA only

CI 2.0 forbids shortened SHA values.

Allowed:

```text
sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

Forbidden:

```text
abcdef1
12345678
sha-deadbeef
```

Rule:

```text
All Git object identifiers and OCI digests used for
identity, lookup, provenance, validation, publication,
logging, cache keys, candidate records, or promotion
MUST use their complete canonical representation.
```

## 16. Build Identity

Conceptually:

```text
BUILD_IDENTITY =
SHA256(
    service source semantics
  + Dockerfile semantics
  + complete build context semantics
  + named build contexts
  + generated source inputs
  + generator inputs
  + lock files
  + build scripts
  + build arguments
  + architecture
  + toolchain identity
  + resolved base image digests
  + shared build dependencies
  + external pinned inputs
)
```

Branch name does NOT belong in it. PR number does NOT belong in it. Workflow
run ID does NOT belong in it. Timestamp does NOT belong in it.

## 17. External build inputs

Mutable external inputs such as `rust:latest`, `golang:latest`, base images,
tool downloads, are resolved to full digests before a dedicated dependency
refresh.

Example: `rust:latest -> sha256:...`. The full digest becomes part of the
build identity.

An ordinary README PR does not needlessly re-resolve such external inputs.
Dependency refresh happens in a controlled way, for example: nightly, manual
dependency refresh, a Dependabot/update event, or an explicitly relevant
change.

## 18. Artifact Resolver

Resolver question: does an ACCEPTED artifact with exactly this build
identity already exist?

Possible answers:

```text
PRESENT_ACCEPTED
MISSING_CONFIRMED
BUILD_IN_PROGRESS
PRODUCED_UNVERIFIED
MISMATCH
UNKNOWN
```

## 19. Build Admission

Flow:

```text
CHANGE
  |
  v
PLAN
  |
  +--------------------------+
  |                          |
NO RELEVANT IMPACT      RELEVANT IMPACT
  |                          |
  v                          v
NOOP                   BUILD = DISACK
                             |
                             v
                    semantic verification
                             |
                   +---------+---------+
                   |                   |
             no build impact      build impact
                   |                   |
                   v                   v
              TEST / REUSE          RESOLVE
                                       |
                       +---------------+---------------+
                       |                               |
                PRESENT_ACCEPTED               MISSING_CONFIRMED
                       |                               |
                       v                               v
                     REUSE                         BUILD = ACK
```

UNKNOWN is not a branch toward BUILD.

## 20. Build Lock

Before a real build starts:

```text
lock key =
service
+ platform
+ build identity
```

Example: `dns/linux-amd64/<build-identity>`.

If two runners simultaneously need the same result:

```text
Runner A
-> acquires lock
-> builds

Runner B
-> BUILD_IN_PROGRESS
-> waits
-> re-resolves
-> uses runner A's result
```

Not: runner A builds, runner B builds the same thing.

## 21. Build once

After BUILD ACK, an artifact is produced exactly once.

```text
BUILD
  |
  v
immutable platform artifact
```

Retrying the build itself is not the normal recovery path.

## 22. Publish separate from Build

The critical distinction: `BUILD != PUBLISH`.

If the build succeeded but the push fails:

```text
BUILD SUCCESS
PUSH FAILURE
```

then: retry PUSH. Not: retry BUILD + PUSH.

The goal is: one build, one produced digest, as many publish retries as
needed, always the same result.

## 23. Post-Build Readback

After publish:

```text
BUILD
  |
  v
PUBLISH IMMUTABLE
  |
  v
REGISTER
  |
  v
READ BACK
  |
  v
VERIFY IDENTITY
```

Only after this may the artifact enter validation.

### 23.1 Success

`expected digest == registry digest` -> continue.

### 23.2 Not found

```text
build completed
registry artifact missing
-> publish/index/registry failure
-> FAIL/BLOCK
-> do NOT rebuild
```

### 23.3 Wrong digest

`expected != observed -> MISMATCH -> FAIL`.

## 24. Two ACK stages

There are two distinct approvals.

### 24.1 BUILD ACK

```text
This service genuinely needs to be built.
```

### 24.2 ARTIFACT ACK

```text
This specific digest has been fully verified
and may be reused.
```

A successful build never automatically produces ARTIFACT ACK.

## 25. Artifact Lifecycle

```text
MISSING_CONFIRMED
        |
        v
BUILD_ACK
        |
        v
BUILT
        |
        v
PUBLISHED
        |
        v
DISCOVERED
        |
        v
IDENTITY_VERIFIED
        |
        v
SECURITY_SCANNED
        |
        v
SERVICE_TESTED
        |
        v
ARTIFACT_ACK
        |
        v
ACCEPTED
```

Failure path: `REJECTED`. A `REJECTED` artifact must never become a reuse
source.

## 26. Truth model and the Acceptance Ledger (revised during review)

The original draft proposed a single git-ref-CAS "Acceptance Index" as the
authoritative mapping for every service/platform/build-identity triple. That
would have made a single, high-traffic distributed-CAS structure the
authority everything else trusts — the riskiest new piece of infrastructure
in the whole plan. It was replaced with an explicit three-truths model, kept
that way through review:

```text
Git
= Source Truth

GHCR / OCI digest
= Artifact Truth
= which bytes actually exist?

Acceptance Ledger
= Policy Truth
= which exact digest was accepted under
  which Build/Test/Validation Identity?

SQLite (per host)
= disposable materialized view
  over the three truths above
```

The reason a ledger is still needed at all, distinct from GHCR: GHCR alone
can confirm that `sha256:ABC...` exists, but not reliably whether that
digest has already received `ARTIFACT ACK`, or is only
`PRODUCED_UNVERIFIED` / `REJECTED`.

```text
INDEX UNKNOWN
!=
ARTIFACT MISSING
```

An unreadable, stale, or lost index must never automatically produce
`BUILD = ACK`.

### 26.1 What the git-ref-CAS mechanism is now scoped to

The existing, already-proven cross-host CAS-lock pattern (`promote-lock.sh`)
is kept, but deliberately shrunk. Git-ref-CAS is explicitly **not**: a build
cache, an artifact database, a resolver database, or a lifecycle database.

Git-ref-CAS is only:

1. coordination / build lock
2. a small Acceptance Ledger

And, critically: not every matrix job writes to it.

```text
build jobs
    |
    +-> result.json
    +-> result.json
    +-> result.json
    |
    v
single aggregator
    |
    +-> verifies digests
    +-> verifies acceptance
    +-> ONE atomic ledger write
```

This turns "~20 CAS writes per pipeline run" into "1 workflow -> 1 acceptance
commit/CAS update" — a large reduction in how hard the CAS primitive is
pushed. `promote-lock.sh` has been proven safe at roughly one write per
promotion; one ledger write per workflow keeps the mechanism within that
already-validated envelope, rather than multiplying its write volume by the
size of the build matrix. This was the single riskiest open item from the
first review pass and is considered resolved by this design, subject to the
open item in §26.4 below.

### 26.2 SQLite as materialized index, not truth

SQLite is explicitly **not** the source of truth for anything. It exists
purely to avoid repeatedly re-querying GHCR/GitHub for cheap, frequent
questions:

```text
artifacts

service
platform
build_identity
artifact_digest
source_full_sha
state
created_at
published_at
accepted_at
last_seen_at
last_used_at
validation_identity
validation_at
parent_digest
```

Possible states: `BUILDING`, `PRODUCED`, `PUBLISHED`, `DISCOVERED`,
`VERIFIED`, `ACCEPTED`, `REJECTED`, `ORPHAN_CANDIDATE`, `GC_CANDIDATE`,
`DELETED`.

Plus, for example:

```text
builds

service
platform
build_identity
started_at
finished_at
result
artifact_digest
```

A planner can then cheaply answer "have I seen build identity X before?
Which digest? Was it ACCEPTED? When was it last used? Is its validation
still current? Is it already a GC candidate?" from local SQLite first, and
only fall back to the actual source of truth on a miss:

```text
SQLite HIT
-> verify result if required
-> proceed quickly

SQLite MISS
-> check GHCR / OCI / Git
-> populate index

SQLite broken/lost
-> rebuild index
-> NO BUILD just because the DB is missing
```

### 26.3 Where SQLite lives: self-hosted vs. hosted-fallback

**Self-hosted (persistent disk available, e.g. `codex-lxc`):** each host
keeps its own **local** `ci-index.sqlite`. There is no global SQLite.

```text
Self-hosted Host 1 -> local ci-index.sqlite
Self-hosted Host 2 -> local ci-index.sqlite
Self-hosted Host 3 -> local ci-index.sqlite
```

These three databases may be differently "warm" — that's fine, they are
only a cache. A host that doesn't know an entry checks the Acceptance
Ledger, then GHCR, and populates its own local SQLite. A host that already
knows it gets a fast hit. If multiple runners on the same host share the
local file: `WAL` mode, short transactions, and `busy_timeout`, so many
readers can work concurrently and writes stay brief. This mirrors the
already-decided persistent-`buildkitd`-per-host topology elsewhere in this
document (§34) — same axis, same reasoning: persistent local disk removes a
class of problems that a shared/networked store would otherwise have.

**Hosted-fallback runners (no persistent disk):** GitHub Actions Cache is
used, but **not** as a shared read/write file every matrix job touches.
`actions/cache` entries are immutable per key — GitHub documents that an
existing cache entry's content cannot be changed; a cache must be saved
under a new key. This makes "every matrix job restores the same DB file,
writes its own rows, and saves it back" architecturally impossible as a
merge: whichever job's save lands under that key wins, and every other
job's rows are silently dropped. That is not a race to watch for, it is a
guaranteed silent data-loss pattern under exactly the workload the index
exists for.

The correct shape, reusing the same single-aggregator pattern as §26.1:

```text
                    matrix jobs
                  /      |      \
                 /       |       \
          result A   result B   result C
                 \       |       /
                  \      |      /
                     AGGREGATOR
                         |
                         v
                    merge results
                         |
                         v
                     SQLite TX
                         |
                         v
                   SQLite snapshot
                         |
                         v
                  actions/cache save (NEW key)
```

Each matrix job only ever produces a small result, e.g.:

```json
{
  "service": "dns",
  "platform": "linux/amd64",
  "build_identity": "...",
  "digest": "sha256:...",
  "state": "ACCEPTED"
}
```

Only the aggregator merges them, writes one SQLite transaction, and saves
the resulting snapshot under a fresh cache key. Hosted runners on a later
run restore the latest snapshot for read acceleration only; they never
write back directly.

On cache retention limits: GitHub's documented defaults are 7 days without
access and 10 GB per repository, but retention and size are
repository-/org-configurable (public repositories can raise retention up to
90 days, and cache size above the free 10 GB can be configured at
additional cost). CI 2.0 must not write these numbers into the design as
hard constants, and — more importantly — **correctness must never depend on
this retention window**:

```text
Actions Cache lost
-> performance loss

Acceptance Ledger lost/corrupted
-> CI blocked / deliberately reconstructed

GHCR digest missing
-> artifact genuinely missing

Compile fails
-> no persistent artifact

Scan fails
-> no ACCEPTED artifact

One matrix job fails
-> other successful results remain valid
```

### 26.4 Open item: aggregator idempotency contract

The aggregator writes two things: the Acceptance Ledger CAS commit and the
SQLite snapshot. If it dies between the two, a retry of the aggregator step
must land in the same end state as a clean run — this needs an explicit
idempotency contract (safe to reprocess the same set of `result.json`
inputs) before Phase 3 implements it. This is not a correctness hole in the
design: the fail-safe direction is already right (no acceptance recorded
yet means the artifacts in question stay `PRODUCED_UNVERIFIED` and become
GC candidates, i.e. `DISACK`-by-default keeps working as intended even on a
partial aggregator failure). It is a "define before building" item, not an
open risk.

## 27. Reuse

Reuse means: desired build identity -> an ACCEPTED digest exists -> use that
digest.

Reuse does **not** mean: create a new commit tag, rebuild, re-resolve the
same digest again, automatically re-scan, or automatically re-attest.

## 28. No commit version per unchanged service

Today, an unchanged service is sometimes still referenced again under
`sha-<new commit>`. CI 2.0 does not need this.

Example:

```text
Commit A
DNS Build Identity = X
-> DNS digest = Y

Commit B
only changes README

DNS Build Identity = X
-> DNS digest stays Y
-> no new DNS artifact
-> no new DNS commit tag needed
```

Provenance can still document which original input an artifact came from.
An artifact is not artificially relabeled to look like it was built from a
later commit.

## 29. Test Identity

Tests are independent of the container build.

```text
test code changed
-> TEST IDENTITY changed
-> re-run tests
-> build identity identical
-> NO build
```

```text
README changed
-> build identity identical
-> test identity identical
-> NOOP
```

## 30. Validation Identity

Security scans are likewise kept separate.

```text
container digest unchanged
Trivy policy unchanged
validation still valid
-> no scan
```

New security data, however, can cause:

```text
digest identical
validation identity changed
-> RESCAN
-> NO BUILD
```

## 31. Security revalidation separate from normal commit CI

Newly published CVEs are not a reason to scan every unchanged image on
every commit. Instead of every push scanning 10 services across 2
platforms, security refresh is handled separately:

```text
scheduled security validation
        |
        v
accepted digests
        |
        v
only expired validation identities
        |
        v
rescan exact digest
```

No containers are rebuilt because of this.

## 32. Caching baseline rule

```text
CACHE HIT
!=
REUSE
```

Reuse: a finished ACCEPTED artifact exists -> no build. Cache: a build has
already been proven necessary -> make that build as cheap as possible.

## 33. Cache hierarchy

```text
NOOP
  |
  v
REUSE ACCEPTED RESULT
  |
  v
BUILD genuinely necessary
  |
  +-> BuildKit host cache
  |
  +-> BuildKit registry cache
  |
  +-> BuildKit cache mounts
  |
  +-> sccache local
  |
  +-> sccache Redis
  |
  +-> ccache local
  |
  +-> ccache Redis
  |
  +-> Cargo caches
  |
  +-> Go caches
  |
  +-> package proxy
  |
  v
compute only the remaining work
```

## 34. BuildKit

Goal:

```text
Host 01
├── persistent buildkitd
├── Runner 01
├── Runner 02
├── Runner 03
├── Runner 04
└── Runner 05

Host 02
└── persistent buildkitd

Host 03
└── persistent buildkitd
```

Runners on one host thereby share: layers, content store, base images,
intermediate stages, cache mounts, build-graph results.

## 35. Shared BuildKit cache

```text
BuildKit Host 01 ─┐
BuildKit Host 02 ─┼── OCI BuildKit Cache Registry
BuildKit Host 03 ─┘
```

Concept: `cache-from = registry`, `cache-to = registry`, `mode = max`. No
global `cache:latest` write contention. Scopes at least per service. Many
readers, one controlled writer.

## 36. sccache

```text
rustc
  |
  v
sccache
  |
  +-> L0 local disk
  |
  +-> L1 Redis
```

A Redis outage must not break the build. If Redis fails: fall back to local
cache, or compile. Not: CI broken.

## 37. ccache

```text
C/C++ compiler
  |
  v
ccache
  |
  +-> L0 local
  |
  +-> L1 Redis storage helper
```

No remote-only operation. Local cache stays the fallback.

## 38. Go

Go uses its native cache mechanisms: `GOMODCACHE`, `GOCACHE`. Local and
persistent per host/runner. For dependency downloads: a central `GOPROXY`.
No home-grown Redis wrapper for `GOCACHE` unless a demonstrably suitable,
robust official mechanism exists for it.

## 39. Cargo

Use: Cargo registry cache, Cargo git cache, sccache. Not: one globally
writable `target/` shared by 15 runners. `target/` stays local/per-job.

## 40. Package download cache

```text
Runner
  |
  v
LAN package proxy
  |
  v
Internet
```

Possible contents: APT, APK, Cargo, Go, npm, pip, Maven, Gradle, OCI pulls.

## 41. No universal NFS cache

Not:

```text
/mnt/shared-cache/
├── cargo
├── target
├── buildkit
├── sccache
├── ccache
├── go
└── docker
```

with all 15 runners as parallel writers. Instead: local cache plus a
purpose-built shared backend service.

## 42. Cache failure

Cache is an optimization. Therefore:

```text
Redis down
-> local compiler cache
-> compile

Registry cache down
-> local BuildKit
-> build

Package proxy miss
-> upstream

all build caches miss
-> normal build
```

But only once `BUILD = ACK` has already been granted.

## 43. Multi-architecture build

amd64 and arm64 are platform variants of the same build target. They use
the same central build decision. Not: amd64 decides for itself, arm64
decides separately. Instead:

```text
ci.sh plan service
        |
        v
BUILD ACK
        |
        +-> linux/amd64
        |
        +-> linux/arm64
```

## 44. Platform artifacts

Each platform delivers: service, platform, build identity, digest.

```text
dns
linux/amd64
ID X
sha256:A

dns
linux/arm64
ID X
sha256:B
```

## 45. Multi-arch assembly

Only once both platforms are ACCEPTED:

```text
amd64 ACCEPTED
        +
arm64 ACCEPTED
        |
        v
OCI INDEX ASSEMBLE
        |
        v
INDEX DIGEST
        |
        v
VERIFY
        |
        v
ACCEPTED
```

A missing platform does not trigger a rebuild of the successful platform.

## 46. Service failure domains

Each service is its own failure domain.

```text
proxy       ACCEPTED
dns         ACCEPTED
watchdog    FAILED
dhcp        ACCEPTED
dhcp-proxy  ACCEPTED
ntp         ACCEPTED
syslog      ACCEPTED
ui          ACCEPTED
build-tools ACCEPTED
utilities   ACCEPTED
```

Result: watchdog's candidate failed; the other nine results stay valid,
stay ACCEPTED, and may be reused on the next run.

## 47. Stack assembly

A complete stack consists exclusively of ACCEPTED digests.

```text
proxy digest
dns digest
watchdog digest
dhcp digest
dhcp-proxy digest
ntp digest
syslog digest
ui digest
build-tools digest
utilities digest
        |
        v
STACK CANDIDATE
```

## 48. Stack Candidate

Contains exact digests. No moving service tags.

```text
proxy=sha256:...
dns=sha256:...
watchdog=sha256:...
...
```

## 49. Stack Validation

Full setup uses exclusively these exact digests.

```text
STACK CANDIDATE
        |
        v
compose override
        |
        v
start
        |
        v
health
        |
        v
integration tests
        |
        v
client simulation
        |
        v
STACK ACCEPTED
```

## 50. Promotion stays atomic

Builds are per-service independent. Promotion is stack-atomic.

```text
10/10 service digests ACCEPTED
+
stack validation SUCCESS
        |
        v
PROMOTE
```

At `9/10`: `NO PROMOTION`. The nine successful artifacts stay ACCEPTED
regardless.

## 51. Promotion never builds

`promote` may exclusively move references. Forbidden: `PROMOTE -> build`.
Allowed:

```text
PROMOTE
-> verify candidate digests
-> acquire lock
-> move channel refs
-> verify readback
-> release lock
```

## 52. Promotion Lock

The existing, already-proven cross-host CAS lock approach can be reused, or
integrated into `ci.sh`. A global promotion lock is not necessary for
mutually independent builds.

## 53. Promotion Readback

After promotion:

```text
expected channel digest
        |
        v
registry readback
        |
        +-> match -> SUCCESS
        |
        +-> mismatch -> rollback/fail
        |
        +-> unknown -> retry/block
```

## 54. Nightly

Semantics: `current_dev -> nightly`. Nightly is a development channel.
Nightly does **not** mean rebuilding everything every night.

### 54.1 Nightly flow

```text
scheduled nightly
        |
        v
resolve current_dev desired state
        |
        v
PLAN
        |
        +-> everything already ACCEPTED
        |       |
        |       v
        |   no builds
        |
        +-> genuinely missing results
                |
                v
            targeted builds
        |
        v
STACK VALIDATE
        |
        v
atomic promote nightly
```

### 54.2 Unchanged nightly

If `current_dev desired stack == current nightly accepted stack`, then: `NO
BUILD`, `NO RETAG`. Depending on security policy, a separate security
revalidation run may still be necessary — that is not a build.

## 55. master

Semantics: `master` = the current stable release state. Not `master =
nightly`. Not `master = current_dev`.

## 56. Release

Release follows `BUILD ONCE`, `PROMOTE MANY`. If the desired release
candidate is already exactly ACCEPTED: `Release -> 0 builds`.

### 56.1 Release flow

```text
release request/tag
        |
        v
resolve exact accepted stack
        |
        v
verify release policy
        |
        v
atomic promotion
        |
        v
GitHub Release
        |
        +-> SBOM
        +-> VEX
        +-> Provenance
```

## 57. SBOM

SBOM is bound to the exact artifact digest. If a valid SBOM already exists
for a digest: `REUSE SBOM`. Release does not need to rescan the same image
just to regenerate the same SBOM.

## 58. VEX

VEX is generated from the exact release policy/input state. It is not
treated as a reason to rebuild a container.

## 59. Provenance

Provenance always references the exact digest:

```text
artifact digest
+
source provenance
+
build identity
+
toolchain identity
```

No mutable tag identity.

## 60. PR behavior

```text
PLAN
  |
  +-> NOOP
  |
  +-> TEST ONLY
  |
  +-> REUSE accepted baseline
  |
  +-> BUILD candidate if proven necessary
```

PR artifacts must never automatically write a protected ACCEPTED baseline.
Protected branches control acceptance.

## 61. Fork PR

Fork: no secrets, no protected registry writes. But planner, tests, and
local builds where genuinely needed are allowed to run as far as technically
possible.

## 62. Required Check

A required check must always appear, even for `README.md only`.

```text
CI 2.0 / result
```

```text
planner
-> NOOP
-> final result = SUCCESS
```

Not: `paths-ignore -> workflow never starts -> required check missing`.

## 63. Docs-only desired state

```text
README.md changed
        |
        v
planner
        |
        v
no relevant impact
        |
        v
NOOP
        |
        v
CI 2.0 / result = SUCCESS
```

With: 0 container builds, 0 Trivy scans, 0 registry writes, 0 retags, 0
heavy runners.

## 64. Change to ci.sh itself

A central file must not become the new global blast-radius file. Therefore:
`ci.sh changed != build every service`.

### 64.1 Comment in ci.sh

```text
comment changed
-> semantically identical
-> NOOP
```

### 64.2 Resolver function changed

```text
registry resolver changed
-> resolver tests
-> possibly an integration test
-> NO automatic container build
```

### 64.3 DNS build-identity function changed

```text
dns build-input logic changed
-> re-evaluate DNS build identity
-> only DNS is affected
```

### 64.4 Shared build function changed

Only services that genuinely consume this function, and whose build
semantics actually change because of it, become candidates. Not
automatically all services.

## 65. ci.sh internal structure

```bash
# ============================================================
# CONSTANTS / EXIT HANDLING
# ============================================================

# ============================================================
# SERVICE INVENTORY
# ============================================================

# ============================================================
# SEMANTIC PARSERS
# ============================================================

# ============================================================
# IMPACT ENGINE
# ============================================================

# ============================================================
# IDENTITY ENGINE
# ============================================================

# ============================================================
# ARTIFACT RESOLVER
# ============================================================

# ============================================================
# ACCEPTANCE INDEX
# ============================================================

# ============================================================
# RETRY CLASSIFIER
# ============================================================

# ============================================================
# CACHE CONFIGURATION
# ============================================================

# ============================================================
# BUILD ENGINE
# ============================================================

# ============================================================
# VERIFY / TEST / SCAN
# ============================================================

# ============================================================
# ASSEMBLY
# ============================================================

# ============================================================
# PROMOTION
# ============================================================

# ============================================================
# NIGHTLY / RELEASE
# ============================================================

# ============================================================
# GC
# ============================================================

# ============================================================
# DISPATCH
# ============================================================
```

## 66. ci.bats internal structure

```bash
# ============================================================
# CORE INVARIANTS
# ============================================================

# ============================================================
# SEMANTIC IMPACT
# ============================================================

# ============================================================
# SERVICE DEPENDENCIES
# ============================================================

# ============================================================
# BUILD IDENTITIES
# ============================================================

# ============================================================
# RESOLVER STATES
# ============================================================

# ============================================================
# RETRY CLASSIFICATION
# ============================================================

# ============================================================
# BUILD ADMISSION
# ============================================================

# ============================================================
# CACHE FALLBACK
# ============================================================

# ============================================================
# REGISTRY / PUBLISH / READBACK
# ============================================================

# ============================================================
# ASSEMBLY
# ============================================================

# ============================================================
# PROMOTION
# ============================================================

# ============================================================
# GC
# ============================================================

# ============================================================
# HISTORICAL REGRESSIONS
# ============================================================
```

## 67. Retry model

Retry happens at the operation level, not the workflow level.

### 67.1 Retry allowed

Examples: HTTP 5xx, registry transport timeout, transient 401 after session
aging, DNS/network errors, transient Git ref lookup, non-fast-forward push
under CAS, a known transient BuildKit lock.

### 67.2 Retry not allowed

Compiler error, shell syntax error, test failure, digest mismatch, policy
violation, invalid config, missing required input.

### 67.3 Retry state

Every attempt starts with fresh, temporary output. Not: attempt-1 partial
output + attempt-2 output = an apparently successful combined result.

## 68. Exit status

Every wrapper explicitly records the real exit status of the operation it
ran. No construction may allow "command fails, wrapper returns 0."

## 69. Postcondition, not just exit 0

`command returned 0 != desired state exists`.

```text
publish returned 0
-> digest readback required
```

```text
cleanup returned 0
-> verify actual state of critical resources
```

## 70. Runner Admission

Heavy runners are requested only after plan/admission. Not: workflow starts
-> 20 heavy matrix jobs -> each decides later that it has nothing to do.
Instead: cheap planner -> the build matrix contains only real BUILD ACKs ->
only those get heavy runners.

## 71. Dynamic Matrix

Planner returns, for example:

```json
{
  "build_matrix": [
    {
      "service": "dns",
      "platform": "linux/amd64",
      "runner": "heavy"
    },
    {
      "service": "dns",
      "platform": "linux/arm64",
      "runner": "arm64"
    }
  ]
}
```

If no build is needed: `{"build_matrix": []}`. No build runner starts.

## 72. Hosted Fallback

Hosted/self-hosted differ only in execution location, not CI semantics.
Wrong:

```text
self-hosted implementation A
hosted fallback implementation B
```

Right:

```text
ci.sh check X
        |
        +-> self-hosted runner
        |
        +-> hosted runner

same function
same decision
same semantics
```

### 72.1 Fallback means sequential, not parallel (added during review)

Same semantics is necessary but not sufficient. The current CI runs the
self-hosted and hosted-fallback variant of a check **concurrently, always**
-- not "self-hosted first, hosted only if self-hosted fails or is
unavailable." That is not a fallback; it is unconditional duplicate work on
both a shared self-hosted runner pool and GitHub-hosted minutes, for every
run, regardless of whether the self-hosted side ever had a problem.

Confirmed with real data, not assumption: on PR #1695 (a two-line
documentation-only change), every one of 9 self-hosted/hosted-fallback job
pairs started within the same second of each other:

```text
PR template validation      | self: 07:52:59Z | fallback: 07:52:59Z
compose healthchecks        | self: 07:52:59Z | fallback: 07:52:59Z
file purpose headers        | self: 07:52:59Z | fallback: 07:52:59Z
language policy             | self: 07:54:11Z | fallback: 07:52:59Z
line endings                | self: 07:54:11Z | fallback: 07:52:59Z
shellcheck                  | self: 07:54:10Z | fallback: 07:52:59Z
test (watchdog)              | self: 07:54:10Z | fallback: 07:52:59Z
PR tracking metadata         | self: 07:54:11Z | fallback: 07:52:59Z
PR title Conventional-Commit | self: 07:54:11Z | fallback: 07:52:59Z
```

A real fallback is sequential and conditional -- and, per §72.2 below,
conditional specifically on *why* nothing usable happened, not merely on
whether it happened:

```text
self-hosted job
        |
        +-> succeeds -> DONE, hosted variant never runs
        |
        +-> runner unavailable/never picked up the job/timed out
        |       |
        |       v
        |   hosted-fallback job runs
        |
        +-> runner ran the job and it genuinely failed
                |
                v
            FAIL -- hosted variant never runs, nothing reruns elsewhere
```

Not two independently-triggered jobs that both always run, and not a
fallback that fires on any non-success outcome. In CI 2.0 this is one job
in `ci.yml` with `needs:`/`if:` gating the hosted variant on the
self-hosted attempt's actual outcome, calling the same `ci.sh` command
either way (per §72) -- never two parallel workflow jobs for the same
check.

### 72.2 Fallback triggers on infrastructure absence, never on a genuine failure (added during review)

This generalizes beyond the self-hosted/hosted pair in §72.1 -- the same
distinction applies to every fallback path CI 2.0 has, not only tests.
"The self-hosted attempt's actual outcome" in §72.1 must be read narrowly:
a fallback may trigger only when the reason nothing usable happened is that
**the runner itself was unavailable** -- offline, never picked up the job,
connection failure, timed out waiting for a runner slot to exist at all.

A fallback must never trigger because the runner picked up the job, ran it
for real, and the job itself failed on its merits (a real test failure, a
real build error, a real lint violation). Re-running the identical work on
different infrastructure in that case is not a fallback, it is exactly the
"retry silently until green" pattern already forbidden elsewhere in this
project's governance (Rule-Ref: AG-INT-002) -- it launders a genuine defect
as an infrastructure hiccup by giving it a second, unrelated environment to
maybe not reproduce in, instead of surfacing the failure.

```text
self-hosted runner never picks up the job / goes offline / times out
        |
        v
UNKNOWN (no verdict was ever produced)
        |
        v
automatic fallback to a GHCR/hosted run is correct here

self-hosted runner picks up the job and runs it
        |
        v
the job itself fails (test failure, build error, lint violation)
        |
        v
that is a real verdict -- FAIL, not UNKNOWN
never falls back and re-runs elsewhere hoping for a different result
```

This is the same `UNKNOWN != BUILD` discipline from §2.3/§18, restated for
the fallback mechanism specifically: `UNKNOWN` (no answer was produced,
because the infrastructure that would have produced one wasn't there) is
never conflated with `FAIL` (an answer was produced, and it was negative).
Only `UNKNOWN` is what a fallback exists to resolve.

## 73. CodeQL

CodeQL stays technically separate because GitHub has its own
actions/analysis mechanisms, but admission can come from `ci.sh`:

```text
ci.sh codeql-impact
-> NOOP
-> or relevant analysis
```

Cacheable: CodeQL tools, query packs, dependencies. Do not treat a finished
CodeQL DB as a generic cache when source/build identity has changed.

## 74. GC baseline rule

```text
untagged
!=
unused
```

The full OCI graph must be considered: index, platform manifests, configs,
layers, attestations, SBOM, OCI referrers.

## 75. GC Roots

Protected roots can include: `master`/`latest`, `nightly`, active release
candidates, active PR candidates, currently accepted desired states,
rollback releases, retention policy.

## 76. Reachability GC

```text
ROOTS
  |
  v
OCI reference graph
  |
  v
reachable objects
  |
  +-> KEEP
  |
unreachable
  |
  v
retention / grace policy
  |
  v
DELETE
```

## 77. Build cache GC kept separate

A build cache is not a finished artifact. Own lifecycle policy for:
BuildKit, sccache, ccache, Cargo, Go, package proxy, Trivy DB.

## 78. No age-only deletion of finished artifacts

Not: `older than 7 days -> delete`, without knowing reachability.

## 79. Observability

Every CI decision must be justified.

```text
dns:
state=NOOP
reason=no semantic input changed
```

```text
dns:
state=REUSE
build_identity=...
artifact=sha256:...
reason=accepted exact result exists
```

```text
dns:
state=BUILD_ACK
reason=services/dns/Dockerfile semantic input changed
previous_identity=...
desired_identity=...
artifact=MISSING_CONFIRMED
```

## 80. No log-spam history in YAML

Today's long `What:` / `Why:` / `From:` comments are not carried forward
into workflow YAML en masse. Historical regressions belong in `ci.bats`, and
relevant architecture rules belong in the CI 2.0 documentation. YAML stays
readable.

> **Clarification added during review:** removing the historical
> `What:`/`Why:`/`From:` narratives from workflow YAML does **not** remove
> this project's required `What:`/`Why:`/`From:` code-documentation
> convention. That convention remains applicable to `ci.sh` and `ci.bats`
> wherever `AG-CODE-012` mandates it (max 80 characters each for `What:`
> and `Why:`; `From:` may list more than one source where genuinely
> applicable). The goal of this section is removing duplicated
> implementation history from orchestration YAML, not reducing required
> implementation documentation.

## 81. Do not lose historical guards

No guard that is currently pulling its weight may simply be deleted during
the refactor. Migration:

```text
current guard
        |
        v
determine responsibility
        |
        +-> runtime check -> ci.sh
        |
        +-> regression test -> ci.bats
        |
        +-> obsolete -> remove, with proof
```

Only after that may the old YAML/script implementation be deleted.

## 82. Explicitly NOT carried over from build-push.yml

```text
default should_build=true

unclear registry resolution
-> real build

workflow touched
-> broad build

unchanged service
-> new commit retag

unchanged service
-> its own scan-matrix job on every push

amd64 has its own admission implementation

arm64 has a second admission implementation

service maps maintained in multiple places

service descriptions maintained in multiple places

large inline shell programs in YAML

YAML that structurally checks itself via grep/awk

separate hosted/self-hosted business logic

build + scan + release + promotion + GC logic
in the same workflow file

retry by re-running an entire build

resolving moving tags independently, multiple times

required checks disappearing via paths-ignore
```

## 83. What is kept from today's CI

As requirements/concepts: full SHA, exact OCI digests, native arm64,
exact-digest scanning, cross-host promotion locking, atomic stack promotion,
service failure isolation, full-stack validation, platform verification,
fork secret isolation, provenance, SBOM, VEX, Trivy retry classification,
validation subnet isolation, superseded-run detection, post-operation
verification.

## 84. Migration Strategy

CI 2.0 is built as a new architecture. The current 8,171-line file is not
incrementally reshaped into the target architecture.

### Phase 0 — Freeze

No further structural growth of `build-push.yml`. Only: critical bug fixes,
security fixes, necessary production fixes.

### Phase 1 — Central Engine

Create `scripts/ci/ci.sh` and `scripts/ci/ci.bats`. Initially: service
inventory, shared utility functions, SHA/digest validation, retry
classifier, semantic impact, identity engine.

### Phase 2 — Shadow Planner

The new CI runs `ci.sh plan` in parallel with the old CI. No build control
yet. Old decision vs. CI 2.0 decision are compared; deviations are
analyzed.

### Phase 3 — Acceptance Ledger

Introduce `build identity -> accepted digest`, initially read-only /
shadow. (See §26 for the revised truth model this now implements, and §26.4
for the aggregator idempotency contract that must be defined before this
phase goes live.)

### Phase 4 — Resolver

Activate `PRESENT_ACCEPTED`, `MISSING_CONFIRMED`, `IN_PROGRESS`,
`PRODUCED_UNVERIFIED`, `MISMATCH`, `UNKNOWN`. Still no automatic build
approval on UNKNOWN.

### Phase 5 — Build Admission

Activate `BUILD = DISACK`. A first service is fully migrated to CI 2.0,
then further services.

### Phase 6 — Build/Publish Separation

Implement `BUILD ONCE`, `PUBLISH`, `READBACK`, `VERIFY`.

### Phase 7 — Cache Architecture

In parallel or immediately after: persistent BuildKit per host, BuildKit
registry cache, sccache local + Redis, ccache local + Redis, Cargo cache, Go
cache, package proxy.

### Phase 8 — Validation Identity

Introduce Trivy/test/validation reuse. Unchanged digests are no longer
automatically re-checked on every push.

### Phase 9 — Multi-Arch Assembly

amd64/arm64 are controlled by the same engine. No more duplicated admission
code.

### Phase 10 — Stack Assembly

Assemble exact ACCEPTED service digests into a candidate.

### Phase 11 — Nightly

Move `current_dev -> nightly` onto CI 2.0.

### Phase 12 — Release

Move release onto `build once`, `promote many`.

### Phase 13 — GC

Introduce reachability GC. Wind down old commit/PR tag history in a
controlled way.

### Phase 14 — Cutover

New CI becomes the sole required pipeline.

### Phase 15 — Delete CI 1.x

Remove: old `build-push` logic, obsolete composite actions, obsolete helper
scripts, duplicate service lists, old retry wrappers, old reuse paths, old
retag paths, obsolete GC special-casing. Only after every necessary guard
has been migrated to `ci.sh` or `ci.bats`.

## 85. Acceptance tests for CI 2.0

CI 2.0 is not done until at least the following cases work.

**Test A — README only:** README changed. Expected: planner runs, final
required check runs, builds = 0, scans = 0, registry writes = 0, heavy
runners = 0.

**Test B — Shell comment:** comment in `services/dns/entrypoint.sh`
changed. Expected: semantic identity unchanged, NOOP.

**Test C — Bats comment:** comment in `ci.bats` changed. Expected: test
identity unchanged, NOOP.

**Test D — Test logic:** a real test in `ci.bats` changed. Expected:
affected tests run, container builds = 0.

**Test E — DNS source:** DNS build input changed. Expected: DNS considered,
unrelated services NOOP.

**Test F — Shared proxy dependency:** `services/dns/cdn-domains.txt`
changed. Expected: DNS impact calculated, proxy impact calculated, because
proxy consumes this real build input.

**Test G — Registry down:** desired-artifact lookup hits a registry
timeout. Expected: UNKNOWN, retry, block/fail if exhausted, builds = 0.

**Test H — Build already running:** runner A builds identity X, runner B
requests identity X. Expected: runner B waits/resolves, duplicate builds =
0.

**Test I — Publish failure:** build succeeds, push fails. Expected: retry
push of the exact produced artifact, second build = 0.

**Test J — Readback failure:** build succeeds, publish reports success,
readback fails. Expected: `PRODUCED_UNVERIFIED`, retry readback/publish
diagnosis, second build = 0.

**Test K — Digest mismatch:** expected digest != registry digest. Expected:
`MISMATCH`, FAIL, replacement build = 0.

**Test L — One service fails:** watchdog fails, other services accepted.
Expected: promotion blocked, successful service artifacts remain reusable.

**Test M — Nightly unchanged:** `current_dev` desired state unchanged.
Expected: container builds = 0.

**Test N — Release already accepted:** release points at a fully accepted
candidate. Expected: container builds = 0, atomic promotion, release assets
generated/reused.

**Test O — Full SHA:** search the entire CI for abbreviated Git SHA (must
be 0) and abbreviated OCI digest (must be 0).

## 86. Performance goals

A normal PR with no build need: seconds to a few minutes. Not 30 minutes, 1
hour, 2 hours. Heavy runners should see almost exclusively real builds or
real heavy tests.

## 87. Registry goal

Today's architecture produces tens of thousands of versions. CI 2.0 goal:
the number of registry artifacts tracks actually distinct, accepted build
results — not commits, workflow runs, PR updates, reruns, or nightly timer
events.

## 88. Success metrics

NOOP rate, REUSE rate, BUILD ACK rate, build cache hit rate, duplicate build
count, registry artifact count, average PR runtime, heavy runner
utilization, UNKNOWN count, retry count by failure class, failed publish
count, rejected artifact count, GC reclaimed objects.

## 89. Expected ideal distribution

Long-term: NOOP very frequent, REUSE frequent, TEST ONLY targeted, BUILD
rare. Not: BUILD the default.

## 90. Final architecture in one picture

```text
                         CHANGE / EVENT
                               |
                               v
                       +---------------+
                       |    PLANNER    |
                       |    ci.sh      |
                       +-------+-------+
                               |
                   +-----------+-----------+
                   |                       |
                 NOOP                 WORK REQUIRED
                   |                       |
                   v                       v
                 DONE             semantic identities
                                           |
                                           v
                                      RESOLVER
                                           |
                    +----------------------+----------------------+
                    |                      |                      |
             PRESENT_ACCEPTED      MISSING_CONFIRMED           UNKNOWN
                    |                      |                      |
                    v                      v                      v
                  REUSE              BUILD DISACK?          RETRY/BLOCK
                                           |
                                    real build impact?
                                           |
                                          YES
                                           |
                                           v
                                      BUILD = ACK
                                           |
                                           v
                                   +---------------+
                                   | BUILD CACHES  |
                                   | BuildKit      |
                                   | sccache       |
                                   | ccache        |
                                   | Cargo / Go    |
                                   +-------+-------+
                                           |
                                           v
                                         BUILD
                                           |
                                           v
                                        PUBLISH
                                           |
                                           v
                                       REGISTER
                                           |
                                           v
                                       READ BACK
                                           |
                                           v
                                  VERIFY EXACT DIGEST
                                           |
                                           v
                                  SCAN / TEST / SMOKE
                                           |
                               +-----------+-----------+
                               |                       |
                            REJECT                  ACCEPT
                                                       |
                                                       v
                                              SERVICE ARTIFACT
                                                       |
                                                       v
                                                   ASSEMBLE
                                                       |
                                                       v
                                               STACK CANDIDATE
                                                       |
                                                       v
                                                  VALIDATE
                                                       |
                                                       v
                                               ATOMIC PROMOTE
                                                       |
                                                       v
                                                   CONSUME
```

> **Documentation nit (raised during review, not a design problem):** the
> `RESOLVER -> UNKNOWN -> RETRY/BLOCK` branch in this diagram is happy-path
> shorthand for "GHCR digest missing -> artifact genuinely missing." The
> real `MISSING_CONFIRMED` vs. `UNKNOWN` split (§18, §19) already governs
> this correctly; a future revision of this diagram should add a one-line
> footnote so a reader can't collapse "confirmed missing" and "registry
> query failed" into the same box just by looking at the picture.

## 91. Short version of the CI 2.0 philosophy

```text
Do not build when nothing needs to be done.

Do not test when no relevant test state has changed.

Do not scan when no relevant validation is required.

Do not rebuild when the exact accepted result already exists.

Do not build because a registry question could not be answered.

Do not rebuild because publish or readback failed.

Do not punish every service because one of them failed.

Do not confuse cache with reuse.

Do not confuse a Git commit with a build identity.

Do not confuse tags with artifact identity.

Do not confuse a successful command with a verified state.

BUILD is the last resort, not the first.
```

## 92. Three top-level rules

These three lines should govern every implementation decision:

```text
DEFAULT = NOOP

BUILD = DISACK

UNKNOWN != BUILD
```

## 93. Additional invariants (added during review)

Beyond the three core rules in §92, the following were added while working
through the truth-model and lifecycle refinements in §26 and below:

```text
DEFAULT = NOOP

BUILD = DISACK

UNKNOWN != BUILD

INDEX UNKNOWN != ARTIFACT MISSING

BUILT != ACCEPTED

UNTAGGED != UNUSED

FAILED COMPILE -> NO PERSISTENT ARTIFACT

REJECTED -> NEVER REUSE
```

## 94. Retention as a first-class part of the lifecycle

Retention is not a cleanup script bolted on afterward — it is part of the
Artifact Lifecycle (§25) from the start. Three separate classes:

### 94.1 Transient artifacts

`BUILDING`, `PRODUCED`, `PUBLISHED`, `REJECTED`, `ORPHAN_CANDIDATE`. These
need only a short grace period — hours, not weeks or months.

### 94.2 ACCEPTED artifacts

These are kept as long as they are, for example: referenced by nightly,
referenced by `latest`/`master`, part of a release, a rollback root, needed
by an active candidate, within the desired history policy, or still needed
as a valid reuse result.

### 94.3 Build caches

Completely separate retention for BuildKit, sccache, ccache, Cargo, Go,
Trivy, package proxy. These have nothing to do with the lifetime of
finished artifacts.

## 95. No persistent artifact for a failed build

A hard CI 2.0 rule:

```text
FAILED COMPILE
-> no registry artifact
-> no sha-<commit> tag
-> no ACCEPTED record
```

If the compile already fails locally, nothing may persist in GHCR at all.

## 96. Push-by-digest before tagging

Preferred shape:

```text
BUILD
  |
  v
push-by-digest
  |
  v
sha256:...
```

The produced candidate artifact does not initially receive a permanent
commit tag. Then: `READBACK -> SCAN -> TEST -> VERIFY`. Only after a
successful `ARTIFACT ACK` does it become part of an accepted state.

Worked example:

```text
amd64
-> BUILD SUCCESS
-> sha256:AAAA

arm64
-> COMPILE FAILED
```

Then the following must NOT be created: `sha-<commit>-amd64`,
`sha-<commit>`, `nightly`, `latest`. Instead:

```text
sha256:AAAA
-> PRODUCED_UNVERIFIED
-> ORPHAN_CANDIDATE
-> deletable after grace period,
   if nothing references it
```

If both succeed:

```text
amd64 -> sha256:AAAA -> ACCEPTED
arm64 -> sha256:BBBB -> ACCEPTED
```

only then: `ASSEMBLE -> multiarch sha256:CCCC -> VERIFY -> ACCEPTED`.

## 97. GC may only use SQLite as a candidate source

SQLite may say "this artifact looks deletable," never, by itself, "this
artifact may be deleted." Before any real delete:

```text
SQLite
  |
  v
GC_CANDIDATE
  |
  v
check GHCR / OCI
  |
  v
check reference graph
  |
  v
check protected roots
  |
  +------------------+
  |                  |
REFERENCED        UNREACHABLE
  |                  |
KEEP             DELETE
```

## 98. Checks must be scoped to the PR, not the repository, unless the check's own semantics require otherwise

A check that re-scans/re-searches the entire repository on every run, when
its actual purpose only concerns the files a PR touches, silently
reintroduces the same "everything is a candidate by default" failure mode
this whole document exists to remove — just at the level of a single check
instead of the whole build. Every check migrated into `ci.sh`/`ci.bats`
must be explicitly justified as either PR/diff-scoped (the default
expectation) or genuinely repository-wide (an explicit, named exception,
e.g. a full reachability GC pass or a cross-service dependency-graph
check that cannot be answered from a diff alone).

Two real examples already found in this repository's current CI, kept here
as concrete evidence rather than a hypothetical:

```text
.github/actions/shellcheck-and-standing-guards/action.yml
-> find . \( -name "*.sh" -o -name "*.bats" \) | xargs shellcheck
-> unconditional, repository-wide, no diff-scoping at all

build-push.yml's shellcheck-hosted job
-> no `if:` condition whatsoever, not even the docs_only check
   its self-hosted twin has
-> verified live against PR #1648 (a single-file AGENTS.md-only PR):
   self-hosted shellcheck correctly reported "skipping",
   the hosted fallback still ran a full 3m7s repo-wide scan anyway
```

Migrating a check like this into CI 2.0 is not just "move the shell script
into `ci.sh`" — it must also gain the same semantic-impact gate every build
decision gets (§11): does this specific check's rationale actually require
looking beyond the changed files, or is repo-wide scope just how it happened
to be written the first time. Every check inherited from `build-push.yml`
during migration (§81) should carry an explicit note recording which of the
two it is, not silently keep whatever scope it already had.

## 99. Implementation-process rules for building ci.sh/ci.bats itself (added during review)

Hard rules for whoever (human or agent) actually implements CI 2.0, not
rules about the CI's own runtime behavior:

**Verification depth has no line-count shortcut.** Before starting
implementation work on any part of `ci.sh`/`ci.bats`, or before relying on
an existing file's current behavior, read the real source in full -- never
truncate a verification read to an arbitrary line count and generalize
from the partial result. When a single read would exceed a practical
limit, read in sequential chunks of up to ~24,999 tokens each and keep
going, chunk after chunk, until the entire file/document has actually been
covered. A conclusion drawn from a partial read is not verification, it is
a guess wearing verification's clothes.

**Bash tools before API calls, always.** Matches `AG-VAL-005`, restated
here because `ci.sh` implementation work leans on shell tooling by its
nature: prefer a native local command (`grep`, `sed`, `awk`, `find`,
`git`, etc.) over an API call at any time, instead of and/or before
reaching for an API call. An API call is for the case with no local
equivalent, not the default first move.

**Bulk operations over one-by-one edits.** Wherever a change genuinely
applies uniformly across multiple lines or files, use a bulk/batch tool
(`sed` and equivalents) instead of many individual edits. This is about
using the right tool for a uniform transformation, not a license to apply
a blind, unreviewed find-and-replace across semantically different call
sites -- the semantic-impact discipline in §11/§12 still governs whether a
given change is actually uniform in the first place.

## Open decisions

These are explicitly open, not resolved by this document:

1. **`netdata` service-list membership** (§7). `services/netdata/Dockerfile`
   exists but is not in `CI_BUILD_SERVICES` today. Verified as a live drift
   finding, not a hypothetical — needs a deliberate in/out decision before
   the service list is frozen.
2. **Aggregator idempotency contract** (§26.4). Must be defined — safe
   reprocessing of the same `result.json` set — before Phase 3 goes live.
3. **Whether the git-ref-CAS Acceptance Ledger needs anything beyond the
   build lock and the small ledger described in §26.1**, now that GHCR/OCI
   is explicitly the Artifact Truth and SQLite is explicitly disposable.
4. **`actions/cache` retention/size numbers** (§26.3) — stated as current
   documented defaults, explicitly not to be relied on for correctness, but
   not independently re-verified line-by-line against the cache action's
   own documentation in this review pass (the 10 GB/7-day figures were
   verified for the BuildKit `type=gha` backend specifically, not the
   general-purpose cache action).
