#!/bin/bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Cross-host, cross-workflow mutual exclusion for `build-push.yml`'s
# `promote` job and `backfill-stack-latest.yml`'s `backfill-latest` job
# (issue #897). Both jobs move mutable GHCR channel tags for the SAME set of
# images and must never run their tag-moving critical section at the same
# time as each other, regardless of which ref/tag/channel each one is
# working on -- that "any promote vs. any backfill, any ref" exclusion is
# exactly what issue #777 already fixed once, and this file's whole job is
# to keep providing it without reintroducing #777 while ALSO closing #897.
#
# WHY THIS EXISTS INSTEAD OF A HOST-LOCAL FLOCK: this project already has an
# established, working pattern for "GitHub Actions' own primitives aren't
# enough, build a real mutex" -- scripts/lib/reserve-validation-subnet.sh's
# flock-on-a-well-known-/tmp-path idiom (issues #703/#820/#832). That pattern
# is NOT reusable here as-is: its own header comments scope it explicitly to
# coordinating concurrent jobs "on the same self-hosted host", because a
# flock is a kernel-local primitive -- it only serializes processes that can
# see the same file. Checked directly against this repository's real runner
# fleet (`gh api repos/wiki-mod/lancache-ng/actions/runners`, issue #897):
# the `lancache-heavy` label (which `promote` and `backfill-latest` both run
# on) is currently held by runners on at least four distinct physical hosts
# (`a-lancache-runner-240-*`, `b-lancache-runner-229-1`,
# `lancache-runner-228*`, `d-lancache-runner-241-1`). Two concurrent
# `promote`/`backfill-latest` runs can genuinely land on two different
# hosts, so a `/tmp`-based flock would give each host its own, independently
# "uncontested" lock -- no real exclusion at all. Per AG-CI-003 (never build
# CI correctness on a hidden single-host/LAN-only assumption), the lock here
# is instead backed by a resource every runner host reaches identically: the
# git remote (GHCR-adjacent, already checked out and already
# credentialed in both jobs) that both workflows already push images to.
#
# THE ACTUAL PRIMITIVE: a dedicated, non-branch/non-tag ref
# ($PROMOTE_LOCK_REF, under refs/promote-lock/ -- deliberately outside
# refs/heads/* and refs/tags/*, so it can never match a branch-protection
# ruleset, this workflow's own `push:` trigger filters, or any other
# workflow's ref-based trigger). Git's server-side ref update is atomic:
# creating a ref that does not yet exist either succeeds outright or fails
# because someone else's create already landed first (never both), and
# `--force-with-lease=<ref>:<expected-old-sha>` gives the same atomic
# compare-and-swap guarantee for updating/deleting a ref that already
# exists. This is the same "check-then-act must be a single atomic
# server-side operation, not a separate read then a separate write" property
# flock gives locally -- just backed by the git remote instead of a local
# file, so it holds regardless of which host either job runs on.
#
# WHY THIS REPLACES `promote`'s job-level `concurrency:` block rather than
# living alongside it (see issue #897's own discussion): GitHub's
# concurrency-group primitive can cancel a job that is still QUEUED --
# before any of its steps, including this file's own acquire step, have run
# at all. A lock acquired from inside the job's steps cannot protect a job
# that never reaches its first step. The only way to stop GitHub from
# silently dropping an older pending `promote`/`backfill-latest` run is to
# stop asking GitHub's concurrency primitive to gate admission for these two
# jobs in the first place, and to provide the actual mutual exclusion here
# instead -- every job instance gets to start and run its own wait loop,
# and NONE of them get cancelled while merely queued.
#
# Pure functions, no top-level executable code, mirroring
# scripts/lib/reserve-validation-subnet.sh's and scripts/lib/ghcr-retry.sh's
# convention: sourced directly by both workflows' `run:` steps and by
# tests/bats/promote_lock.bats (which exercises the real git CAS semantics
# against a local bare repo standing in for the GitHub remote -- these
# functions only ever call plain `git`, so a local bare repo is a faithful,
# Docker-free substitute for the real GHCR-adjacent remote).
#
# Deliberately NOT `set -euo pipefail` at the top level, same reasoning as
# ghcr-retry.sh: this file only defines functions for a caller to invoke
# under the caller's own shell options.

# Single, global, well-known lock location. "Global" is deliberate, not an
# oversight: #897 explicitly rejected re-scoping the underlying concurrency
# boundary per-ref (that would reintroduce #777, a promotion racing
# backfill-stack-latest.yml's own tag move for a DIFFERENT ref). Keeping one
# shared constant here (rather than letting each caller pass its own ref
# name) is what makes that global scope structurally impossible to
# accidentally narrow -- there is only ever one lock for both workflows to
# disagree about.
PROMOTE_LOCK_REF="refs/promote-lock/global"

# The well-known empty tree object hash (`git hash-object -t tree /dev/null`
# on any repo -- this is a fixed constant of the SHA-1 object format, not
# something this repository generated). Every lock commit points at this
# tree: the lock carries no file content, only a commit message (the holder
# note) and a committer timestamp (staleness), so there is no blob/tree to
# construct per attempt.
PROMOTE_LOCK_EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

# promote_lock_holder_note <run_id> <run_attempt> <runner_name>
# Builds the single-line commit message identifying a lock holder. Kept as
# its own function so both the acquire path (writing the note) and the
# release path (comparing the current holder against this same string
# before deleting) always construct it identically.
promote_lock_holder_note() {
    local run_id="$1" run_attempt="$2" runner_name="${3:-unknown}"
    printf 'promote-lock holder run=%s attempt=%s runner=%s' "$run_id" "$run_attempt" "$runner_name"
}

# promote_lock_remote_sha <remote> <lock_ref>
# Prints the lock ref's current remote SHA on stdout. Exit status: 0 = ref
# exists (SHA printed), 1 = ref does not exist (lock free), 2 = the query
# itself failed (network/auth/transient). Callers must treat 2 as "unknown",
# never as "free": misreading a transient ls-remote failure as an absent
# lock would let two callers both attempt to "create" the ref, defeating the
# whole point of checking first.
promote_lock_remote_sha() {
    local remote="$1" lock_ref="$2" output status

    output="$(git ls-remote --exit-code "$remote" "$lock_ref" 2>/dev/null)"
    status=$?

    if [[ "$status" -eq 0 ]]; then
        printf '%s\n' "${output%%$'\t'*}"
        return 0
    elif [[ "$status" -eq 2 ]]; then
        return 1
    else
        return 2
    fi
}

# promote_lock_try_acquire <remote> <lock_ref> <holder_note> <stale_after_seconds>
# Single, non-blocking attempt to acquire the lock. Return codes:
#   0 = acquired (caller now holds the lock and must release it)
#   1 = held by someone else and not stale -- caller should back off normally
#   2 = lost a create/takeover race to a concurrent attempt -- the lock is
#       moving right now, caller should retry almost immediately
#   3 = a real (non-contention) failure querying/writing the ref -- caller
#       should treat this the same as case 1 for backoff purposes, but it is
#       reported separately so a persistent case 3 (vs. transient case 1/2)
#       is distinguishable in logs
promote_lock_try_acquire() {
    local remote="$1" lock_ref="$2" holder_note="$3" stale_after="$4"
    local current_sha commit_sha committed_at previous_note now age

    if current_sha="$(promote_lock_remote_sha "$remote" "$lock_ref")"; then
        : # ref exists; staleness handling below
    else
        case $? in
            1)
                # Lock ref does not exist yet -- attempt to CREATE it. A
                # plain push of a brand-new ref only succeeds if the ref is
                # STILL absent at the moment the server applies the update
                # (git's ref-creation push is a compare-against-zero
                # operation), so two simultaneous creators can never both
                # win.
                commit_sha="$(git commit-tree "$PROMOTE_LOCK_EMPTY_TREE" -m "$holder_note" 2>/dev/null)" || return 3
                if git push "$remote" "${commit_sha}:${lock_ref}" >/dev/null 2>&1; then
                    return 0
                fi
                return 2
                ;;
            *)
                echo "::warning::promote-lock: could not query $lock_ref (transient?); treating as unavailable this attempt." >&2
                return 3
                ;;
        esac
    fi

    # The ref already exists -- fetch the commit itself (not just its SHA)
    # so staleness can be judged from its real committer timestamp, and so
    # the holder note is available for both the log message and (in
    # promote_lock_release) the ownership check.
    if ! git fetch --quiet --depth=1 "$remote" "$lock_ref" >/dev/null 2>&1; then
        echo "::warning::promote-lock: could not fetch $lock_ref to inspect the current holder; treating as unavailable this attempt." >&2
        return 3
    fi

    committed_at="$(git log -1 --format=%ct FETCH_HEAD 2>/dev/null)"
    # Defensive fallback: FETCH_HEAD was just fetched successfully above, so
    # `git log` should never come back empty here -- but treating an
    # unexpectedly empty read as "timestamp 0" (maximally stale) rather than
    # letting the arithmetic below fail on an empty operand means a genuine
    # anomaly degrades to "attempt a safe takeover" instead of crashing this
    # function outright.
    committed_at="${committed_at:-0}"
    previous_note="$(git log -1 --format=%s FETCH_HEAD 2>/dev/null)"
    now="$(date +%s)"
    age=$(( now - committed_at ))

    if (( age < stale_after )); then
        return 1
    fi

    # Stale: the previous holder never released (crashed run, killed
    # runner, ...). Take over via force-with-lease keyed on the SHA we just
    # read -- if another waiter's takeover lands first, our expected-old-sha
    # will no longer match and this push fails safely instead of clobbering
    # the new, legitimate holder.
    commit_sha="$(git commit-tree "$PROMOTE_LOCK_EMPTY_TREE" -m "$holder_note" 2>/dev/null)" || return 3
    if git push --force-with-lease="${lock_ref}:${current_sha}" "$remote" "${commit_sha}:${lock_ref}" >/dev/null 2>&1; then
        echo "::warning::promote-lock: took over a stale lock (previous holder: '${previous_note}', age ${age}s >= ${stale_after}s threshold)." >&2
        return 0
    fi
    return 2
}

# promote_lock_acquire_with_retry <remote> <holder_note> <max_attempts> <backoff_seconds> <stale_after_seconds>
# Retries promote_lock_try_acquire against the single shared
# $PROMOTE_LOCK_REF until it succeeds or <max_attempts> is exhausted.
# Contention losses (return 2: someone else is actively creating/taking over
# the lock right now) retry almost immediately since the state is already
# changing; a currently-held, non-stale lock (return 1) or a query failure
# (return 3) sleeps the full <backoff_seconds> before the next attempt.
# Fails closed: exhausting every attempt without acquiring returns 1 and
# prints an ::error::, so a caller under `set -euo pipefail` stops rather
# than proceeding to promote/backfill without holding the lock -- silently
# continuing unlocked here would reopen #777.
promote_lock_acquire_with_retry() {
    local remote="$1" holder_note="$2" max_attempts="$3" backoff_seconds="$4" stale_after_seconds="$5"
    local attempt=1 result

    while (( attempt <= max_attempts )); do
        if promote_lock_try_acquire "$remote" "$PROMOTE_LOCK_REF" "$holder_note" "$stale_after_seconds"; then
            return 0
        else
            result=$?
        fi

        if (( attempt >= max_attempts )); then
            break
        fi

        if (( result == 2 )); then
            echo "promote-lock: lost a contention race on attempt ${attempt}/${max_attempts}; retrying shortly." >&2
            sleep 2
        else
            echo "promote-lock: lock held or unavailable on attempt ${attempt}/${max_attempts}; waiting ${backoff_seconds}s." >&2
            sleep "$backoff_seconds"
        fi
        attempt=$((attempt + 1))
    done

    echo "::error::promote-lock: could not acquire $PROMOTE_LOCK_REF after ${max_attempts} attempts. Failing closed rather than promoting/backfilling without the lock (see issue #777)." >&2
    return 1
}

# promote_lock_release <remote> <holder_note>
# Releases the lock, but only if it is still actually held by <holder_note>
# -- a real (if unlikely, given promote/backfill's short runtime relative to
# any sane stale_after threshold) safety check against deleting a DIFFERENT
# job's lock, in case this job's own hold was judged stale and taken over by
# another waiter while this job was still finishing its work. Always safe to
# call even if the lock is already gone (a no-op, not an error) -- release
# is meant to run from an `if: always()` step regardless of whether
# acquisition or the promotion work itself succeeded.
promote_lock_release() {
    local remote="$1" holder_note="$2"
    local current_sha current_note

    if ! current_sha="$(promote_lock_remote_sha "$remote" "$PROMOTE_LOCK_REF")"; then
        # Absent (case 1) or unqueryable (case 2) -- either way there is
        # nothing this call can safely delete right now.
        return 0
    fi

    if ! git fetch --quiet --depth=1 "$remote" "$PROMOTE_LOCK_REF" >/dev/null 2>&1; then
        echo "::warning::promote-lock: could not fetch $PROMOTE_LOCK_REF to verify ownership before release; leaving it in place for the next acquirer's staleness check to recover." >&2
        return 1
    fi
    current_note="$(git log -1 --format=%s FETCH_HEAD 2>/dev/null)"

    if [[ "$current_note" != "$holder_note" ]]; then
        echo "::warning::promote-lock: current holder ('${current_note}') does not match ours ('${holder_note}'); not releasing a lock we no longer hold." >&2
        return 0
    fi

    if git push --force-with-lease="${PROMOTE_LOCK_REF}:${current_sha}" "$remote" ":${PROMOTE_LOCK_REF}" >/dev/null 2>&1; then
        return 0
    fi

    echo "::warning::promote-lock: failed to delete $PROMOTE_LOCK_REF (it may already have been taken over as stale by another waiter); a later acquirer's staleness check will still recover it." >&2
    return 1
}
