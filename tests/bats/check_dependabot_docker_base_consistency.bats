#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Exercises scripts/check-dependabot-docker-base-consistency.sh against
# small, throwaway fixture trees rather than only this repo's own real
# tree, so both the passing and failing path are proven -- per AG-VAL-024,
# a check that only ever runs against an already-green tree never actually
# proves its fail-closed path is reachable.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/check-dependabot-docker-base-consistency.sh"
    fixture_root="$(mktemp -d)"
    mkdir -p "$fixture_root/.github"
}

teardown() {
    rm -rf "$fixture_root"
}

fail() {
    echo "$1" >&2
    return 1
}

write_dependabot_docker_block() {
    cat > "$fixture_root/.github/dependabot.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
  - package-ecosystem: docker
    directories:
      - /services/a
      - /services/b
    target-branch: current_dev
    schedule:
      interval: weekly
    groups:
      docker-base-images:
        patterns: ["*"]
EOF
}

@test "passes when every listed Dockerfile's final stage shares one base image" {
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    cat > "$fixture_root/services/a/Dockerfile" <<'EOF'
FROM golang:1.24 AS builder
RUN go build ./...
FROM alpine:3.24
COPY --from=builder /app /app
EOF
    cat > "$fixture_root/services/b/Dockerfile" <<'EOF'
FROM alpine:3.24
COPY . /app
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]] || fail "did not report a clean pass: $output"
}

@test "fails when one listed Dockerfile's final stage uses a different base image" {
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    cat > "$fixture_root/services/a/Dockerfile" <<'EOF'
FROM alpine:3.24
COPY . /app
EOF
    cat > "$fixture_root/services/b/Dockerfile" <<'EOF'
FROM debian:12-slim
COPY . /app
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"do not"* ]] || fail "did not report the divergence: $output"
    [[ "$output" == *"alpine:3.24"* ]] || fail "did not name the alpine image: $output"
    [[ "$output" == *"debian:12-slim"* ]] || fail "did not name the debian image: $output"
}

@test "only compares each Dockerfile's LAST FROM line, not an earlier builder stage" {
    # Reproduces the real shape this project's own service Dockerfiles use:
    # a builder stage on an unrelated image, then a final stage on the
    # shared base -- the builder-stage difference must not be flagged.
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    cat > "$fixture_root/services/a/Dockerfile" <<'EOF'
FROM rust:latest AS builder
RUN cargo build --release
FROM alpine:3.24
COPY --from=builder /app /app
EOF
    cat > "$fixture_root/services/b/Dockerfile" <<'EOF'
FROM golang:1.24 AS builder
RUN go build ./...
FROM alpine:3.24
COPY --from=builder /app /app
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]] || fail "flagged a builder-stage-only difference: $output"
}

@test "treats a named final stage as equal to an unnamed one for the same image" {
    # FROM alpine:3.24 AS runtime and FROM alpine:3.24 ship the identical
    # image -- comparing the raw FROM line text (including the stage alias)
    # would false-positive on the name alone.
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    cat > "$fixture_root/services/a/Dockerfile" <<'EOF'
FROM golang:1.24 AS builder
RUN go build ./...
FROM alpine:3.24 AS runtime
COPY --from=builder /app /app
EOF
    cat > "$fixture_root/services/b/Dockerfile" <<'EOF'
FROM alpine:3.24
COPY . /app
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]] || fail "flagged a named-vs-unnamed final stage as a divergence: $output"
}

@test "accepts a lowercase 'from' instruction and leading whitespace, not only 'FROM '" {
    # Real Codex finding: Dockerfile instruction names are case-insensitive,
    # so a valid Dockerfile may use `from`/`From` and/or indent the
    # instruction -- a case-sensitive `^FROM ` match found nothing for
    # these, which under set -o pipefail aborted the whole script with no
    # diagnostic instead of comparing base images.
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    cat > "$fixture_root/services/a/Dockerfile" <<'EOF'
FROM golang:1.24 AS builder
RUN go build ./...
   from alpine:3.24
COPY --from=builder /app /app
EOF
    cat > "$fixture_root/services/b/Dockerfile" <<'EOF'
FROM alpine:3.24
COPY . /app
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]] || fail "did not recognize a lowercase/indented 'from' line as equivalent: $output"
}

@test "fails closed, with a diagnostic, when a Dockerfile has no FROM instruction at all" {
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    cat > "$fixture_root/services/a/Dockerfile" <<'EOF'
RUN echo "no FROM line at all"
EOF
    cat > "$fixture_root/services/b/Dockerfile" <<'EOF'
FROM alpine:3.24
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no FROM instruction found"* ]] || fail "did not emit a clear diagnostic for a FROM-less Dockerfile: $output"
}

@test "accepts quoted YAML scalars for package-ecosystem and directory entries" {
    # Real Codex finding: `package-ecosystem: "docker"` and quoted directory
    # strings are valid, equivalent YAML to the unquoted forms
    # write_dependabot_docker_block uses, but the original line-based parse
    # matched only the unquoted spelling and silently found zero directories.
    cat > "$fixture_root/.github/dependabot.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
  - package-ecosystem: "docker"
    directories:
      - "/services/a"
      - '/services/b'
    target-branch: current_dev
    schedule:
      interval: weekly
EOF
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    cat > "$fixture_root/services/a/Dockerfile" <<'EOF'
FROM alpine:3.24
EOF
    cat > "$fixture_root/services/b/Dockerfile" <<'EOF'
FROM alpine:3.24
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]] || fail "did not parse quoted package-ecosystem/directory scalars: $output"
}

@test "validates two docker-ecosystem blocks independently, not merged together" {
    # Reproduces this guard's own documented remediation: splitting a
    # diverged directory into its own separate dependabot.yml block must
    # actually make the check pass again, proving each block's own grouped-
    # PR premise on its own terms rather than comparing across block
    # boundaries.
    cat > "$fixture_root/.github/dependabot.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: docker
    directories:
      - /services/a
      - /services/b
    schedule:
      interval: weekly
    groups:
      docker-base-images:
        patterns: ["*"]
  - package-ecosystem: docker
    directories:
      - /services/c
    schedule:
      interval: weekly
    groups:
      docker-base-images-c:
        patterns: ["*"]
EOF
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b" "$fixture_root/services/c"
    cat > "$fixture_root/services/a/Dockerfile" <<'EOF'
FROM alpine:3.24
EOF
    cat > "$fixture_root/services/b/Dockerfile" <<'EOF'
FROM alpine:3.24
EOF
    # services/c is a deliberately different image, in its OWN block --
    # this must not be compared against block #1's alpine:3.24 at all.
    cat > "$fixture_root/services/c/Dockerfile" <<'EOF'
FROM debian:12-slim
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]] || fail "compared across separate blocks instead of validating each independently: $output"
}

@test "fails closed when a listed directory has no Dockerfile at all" {
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a"
    cat > "$fixture_root/services/a/Dockerfile" <<'EOF'
FROM alpine:3.24
EOF
    # services/b deliberately has no Dockerfile.

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"services/b/Dockerfile"* ]] || fail "did not name the missing Dockerfile: $output"
}

@test "fails closed when dependabot.yml has no docker-ecosystem directories at all" {
    cat > "$fixture_root/.github/dependabot.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"found no docker-ecosystem directories"* ]] || fail "did not report the missing-block case: $output"
}

@test "fails closed when dependabot.yml itself is missing" {
    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]] || fail "did not report the missing file: $output"
}

@test "the real repository passes this guard against its own dependabot.yml and Dockerfiles" {
    # Defense-in-depth self-check: the real dependabot.yml's docker-ecosystem
    # block and its real Dockerfiles must actually satisfy this guard today,
    # so a future edit that reintroduces the drift this guard exists to
    # catch is caught by this suite too, not only by the CI guard step.
    run bash "$script" "$repo_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]] || fail "the real repository tree did not pass: $output"
}
