#!/usr/bin/env python3
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

from pathlib import Path
import re
import subprocess

PATH = Path('.github/workflows/build-push.yml')

REPLACEMENTS = [
    (
        'Daily stable-channel refresh (issues #1035, #1056;',
        [
            'Daily default-branch refresh keeps the stable `latest` channel from going stale.',
            '`nightly` is refreshed separately by nightly-refresh.yml; 01:00 UTC is intentional across DST.',
        ],
    ),
    (
        "Issue #1095 Part 1: mirrors the pull_request trigger's own paths-ignore below",
        [
            'Skip a push only when every changed path is documentation-only; mixed changes still run.',
            'Release tags are unaffected, and CHANGELOG.md remains included for the direct-edit guard.',
        ],
    ),
    (
        'Issue #1203 added a trigger-level `paths-ignore` (docs-only) here to spare light',
        [
            'Do not use PR-level paths-ignore: required checks must exist even for docs-only PRs.',
            'Job-level gates post real skipped conclusions; metadata events rerun metadata policy without rebuilding unchanged content.',
            'Keep this event set aligned with the content-event gates below.',
        ],
    ),
    (
        "Workflow-level floor for pull-requests: a job's own `permissions:` block",
        [
            'Job-level permissions can only narrow this workflow-level grant; PR-reading jobs need this floor.',
        ],
    ),
    (
        'Push/tag events use a run_id-suffixed key instead of the old `{workflow}-publish` one',
        [
            'Push/tag runs use unique groups so publication runs cannot cancel each other mid-promotion.',
            'PR runs share a ref group but do not cancel: metadata events may race for the same commit.',
            'Heavy per-job groups below reclaim superseded PR work without cancelling the whole run.',
        ],
    ),
    (
        'Change classification for PR path-scoping and (as of #1095, extended to',
        [
            'Classify PR and push diffs once; uncertain push ancestry fails safe to all-changed.',
            'Build-affecting workflow/action changes count as runtime changes; build-tools stays tied to its own inputs.',
            'Per-service push reuse is decided separately by determine-push-reuse-scope using image revision, ancestry, and content diff.',
        ],
    ),
    (
        'Diff-scoped, not repo-wide: the whole-repo call above stays soft on AG-HDR-008',
        [
            'AG-HDR-008 is hard-failed only for files changed by this PR; the repository-wide backfill remains soft.',
            'Run inside the pinned build-tools image and fetch the exact base SHA so long-lived PRs remain deterministic.',
        ],
    ),
    (
        'AG-GH-008 requires every PR to carry a milestone. Dependabot cannot set its own',
        [
            'Dependabot cannot set its own milestone, so assign the catch-all milestone before the authoritative metadata check.',
            'The write is idempotent and uses PROJECT_AUTOMATION_PAT; missing credentials leave the later gate to fail clearly.',
        ],
    ),
    (
        'Cheap repository hygiene gate (issue #601). .gitattributes already normalizes line',
        [
            'Required `line endings` check also hosts content-agnostic governance and CHANGELOG guards.',
            'Do not rename this required-check context; docs-only PRs must still execute these guards.',
            'Verification runs in the selected build-tools image rather than host-local tooling.',
        ],
    ),
    (
        'GitHub-hosted fallback is deliberately limited to cheap lint/policy jobs with no LAN',
        [
            'Hosted fallback covers only checks that do not depend on LAN/self-hosted build infrastructure.',
            'ci_scope_policy cannot have a meaningful hosted fallback until its Rust dependencies do.',
        ],
    ),
    (
        'Issue #1245: this is the load-bearing self-skip in this workflow. On a pull_request',
        [
            'Docs-only PRs skip this heavy lint bundle at job level so required checks still exist.',
            'Governance and CHANGELOG checks live in line-endings because they must run for every PR.',
        ],
    ),
    (
        "Job-level concurrency (#891 follow-up): cancel-in-progress is pull_request-only --",
        [
            'validate-compose is a hard publish-path gate, so only superseded PR copies may be cancelled.',
            'Push copies must finish because downstream publication requires its successful build-tools output.',
        ],
    ),
    (
        'A fixed validation subnet collided repeatedly across different, concurrent workflow',
        [
            'Derive a per-run validation subnet candidate; actual collision-safe reservation still happens in the stack-start helper.',
            'This job stays unconditional because full-setup validation also runs on push.',
        ],
    ),
    (
        'On a pull_request event, `promote` never runs at all -- there is no channel image',
        [
            'Wait for merge-manifests so PR validation consumes this PR staging manifest, not stale base-channel content.',
            'Trusted non-PR validation likewise waits for the exact merged sha-* candidate before promotion.',
        ],
    ),
    (
        'None of VALIDATION_SUBNET/GATEWAY/*_IP, COMPOSE_PROJECT_NAME, or VALIDATION_UI_PORT',
        [
            'Do not set validation network/project values at job scope: reservation retries must be able to overwrite them via GITHUB_ENV.',
            'The locked reservation helper owns the collision-safe values used by later steps.',
        ],
    ),
    (
        '`latest` is contractually a stable-release-only channel (see',
        [
            'Resolve validation tags using the same branch/channel contract as promotion.',
            'Same-repo PRs use their own staging tag; fork/Dependabot PRs fall back to a readable base channel.',
        ],
    ),
    (
        'deploy/full-setup/docker-compose.yml uses one LANCACHE_IMAGE_TAG for every service,',
        [
            'Full-Setup uses one tag for the suite; untouched PR services are registry-side backfilled from a verified base commit image.',
            'Touched services must already have their PR staging image and fail closed if it is missing.',
        ],
    ),
    (
        'A service detect-changes says THIS PR touched (or any service other than',
        [
            'Touched services must have a PR staging image after merge-manifests; never hide a missing candidate with base-content fallback.',
            'Only genuinely untouched services may use the verified base-commit backfill path.',
        ],
    ),
    (
        'Central policy reconciliation for PR path filtering. Individual jobs may skip for',
        [
            'Reconcile path-scoped Rust job results so PR-required work stays strict while intentional skips remain valid.',
            'Push runs may also see skipped/cancelled results from path reuse or per-job supersession cancellation.',
            'Rust quality jobs remain strict on push because they have no legitimate cancellation path.',
            'build/build-arm64 require this policy job to succeed; this job itself is never cancelled on push.',
        ],
    ),
    (
        'Never runs on `pull_request` (see `if:` below) -- PRs exercise Dockerfiles via',
        [
            'Changed candidates are scanned by build/build-arm64 using their exact pushed digests; this job must not rebuild them.',
            'For a proven-unchanged push, scan the immutable reused channel digest instead.',
            'determine-push-reuse-scope may legitimately skip outside branch pushes; validate-compose and push-supersession-check remain hard root gates.',
        ],
    ),
    (
        'Job-level concurrency (#888): keyed per matrix row (service + platform) and per',
        [
            'Cancel superseded PR scan rows only; push scans are publication gates and must survive.',
            'Dispatch/rerun keys include run_id so manual attempts cannot cancel each other.',
        ],
    ),
    (
        "Runner selector kept aligned with build/build-arm64's own per-arch split even",
        [
            'Keep scan runner tiers aligned with the corresponding real build architecture.',
        ],
    ),
    (
        'Post-G8-fix timing: a changed service ("should-scan == true") only runs the cheap',
        [
            'Changed rows only decide reuse here; unchanged rows may pull and Trivy-scan a channel digest.',
            'The 60-minute bound covers cold image/DB fetches without inheriting full build time.',
        ],
    ),
    (
        'G8 fix (issue #1095): this job no longer builds anything, so `context`,',
        [
            'This matrix carries only scan-time service/platform/runner data; build metadata belongs to the canonical build matrix.',
        ],
    ),
    (
        'Step 3 (issue #1095): generalizes what used to be build-tools-only',
        [
            'Use the same determine-push-reuse-scope decision as build/build-arm64 so scan and build cannot disagree.',
            'A failed/unavailable reuse decision fails safe to the real candidate scan path.',
        ],
    ),
    (
        'Step 4 (issue #1095): decides, once per push (not once per build/build-arm64/',
        [
            'Decide push reuse once with full git history, then share the result with both architecture builds and container-scan.',
            'Reuse requires a pinned channel digest plus matching image revision, real git ancestry, and a clean service-content diff.',
            'Release tags never reuse branch-channel artifacts.',
        ],
    ),
    (
        '#1095 F-21: the exact immutable manifest-list digest this job pinned',
        [
            'Export the exact digest verified for every reuse=true service so downstream jobs never re-resolve a mutable channel tag.',
        ],
    ),
    (
        'Step 4 (issue #1095): generalized to whichever service this matrix row is',
        [
            'For reuse=true, retag this architecture from determine-push-reuse-scope\'s already-verified immutable digest.',
            'container-scan consumes the same decision/digest, so the retag-only path cannot bypass scanning.',
            'Superseded pushes skip this step because they may intentionally have no pinned reuse digest.',
        ],
    ),
    (
        'Uses github.sha (the actual checked-out/built commit), NOT docker/metadata-action\'s',
        [
            'Key PR staging tags by github.sha, the actual synthetic merge commit that was built.',
            'This prevents two events for the same PR head but different base states from overwriting one staging tag.',
        ],
    ),
    (
        'actions/attest is a standalone action step, so it cannot run inside the bash loops',
        [
            'Attestation actions cannot run inside the manifest loop, so each emitted merged digest has an explicit gated step.',
            'Digest-bound attestation caching avoids re-attesting unchanged merged identities.',
        ],
    ),
    (
        'Promotion is intentionally separate from image build. It moves coherent channel',
        [
            'Promote only after merged candidates and pre-promotion Full-Setup validation succeed.',
            'Use an explicit status function because GitHub implicit success() also considers transitively skipped dependencies.',
            '`!cancelled()` additionally prevents publication after an operator cancels the run.',
        ],
    ),
    (
        "Real runs: 17s-3.6min for this job's own promotion work, but",
        [
            '45 minutes covers the cross-workflow promote-lock retry budget plus normal registry work.',
        ],
    ),
    (
        'Promote only repoints already-built, already-pushed sha-* images at mutable',
        [
            'Do not use GitHub concurrency as the promotion mutex: it can discard queued jobs.',
            'scripts/lib/promote-lock.sh provides the cross-host, cross-workflow git-ref lock shared with latest backfill.',
            'Top-level push groups remain unique so an in-progress promotion is never cancelled by a newer run.',
        ],
    ),
    (
        'Widened from `contents: read` (#897): the promote-lock mechanism',
        [
            'contents:write is required only for the dedicated refs/promote-lock/global compare-and-swap lock.',
        ],
    ),
    (
        'Real, cross-host mutual exclusion for the tag-moving work below (issue #897 -- see',
        [
            'Acquire the shared remote promote lock before any GHCR tag move; exhaustion fails closed.',
        ],
    ),
]


def scalar_membership(lines):
    inside = [False] * len(lines)
    scalar_indent = None
    for i, raw in enumerate(lines):
        text = raw.rstrip('\n')
        stripped = text.lstrip(' ')
        indent = len(text) - len(stripped)
        if scalar_indent is not None:
            if stripped and indent <= scalar_indent:
                scalar_indent = None
            else:
                inside[i] = True
                continue
        if re.search(r':\s*[|>]([+-]?\d*)?\s*(?:#.*)?$', text):
            scalar_indent = indent
    return inside


def projection(text):
    return ''.join(line for line in text.splitlines(keepends=True) if not line.lstrip().startswith('#'))


text = PATH.read_text(encoding='utf-8')
original_projection = projection(text)
lines = text.splitlines(keepends=True)

for marker, replacement in REPLACEMENTS:
    if text.count(marker) != 1:
        raise SystemExit(f'{marker!r}: expected exactly one occurrence, got {text.count(marker)}')

    external = subprocess.run(
        ['git', 'grep', '-F', marker, '--', ':!.github/workflows/build-push.yml', ':!.github/cdx-*', ':!.github/workflows/cdx-*'],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if external.returncode == 0:
        raise SystemExit(f'{marker!r}: referenced outside build-push.yml:\n{external.stdout}')
    if external.returncode not in (0, 1):
        raise SystemExit(f'git grep failed for {marker!r}: {external.stderr}')

    membership = scalar_membership(lines)
    matches = [i for i, line in enumerate(lines) if marker in line]
    if len(matches) != 1:
        raise SystemExit(f'{marker!r}: expected one line match, got {len(matches)}')
    start = matches[0]
    if membership[start]:
        raise SystemExit(f'{marker!r}: target is inside a YAML block scalar; refusing to edit')
    if not lines[start].lstrip().startswith('#'):
        raise SystemExit(f'{marker!r}: target line is not a YAML comment')

    end = start
    while end < len(lines) and lines[end].lstrip().startswith('#') and not membership[end]:
        end += 1

    indent = lines[start][: len(lines[start]) - len(lines[start].lstrip(' '))]
    replacement_lines = [f'{indent}# {item}\n' for item in replacement]
    lines[start:end] = replacement_lines
    text = ''.join(lines)

if projection(text) != original_projection:
    raise SystemExit('Non-comment projection changed; refusing to write result')

PATH.write_text(text, encoding='utf-8')
print(f'Compressed {len(REPLACEMENTS)} YAML comment blocks without changing non-comment content.')
