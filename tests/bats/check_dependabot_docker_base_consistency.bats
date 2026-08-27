#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Exercises scripts/untracked/check-dependabot-docker-base-consistency.sh against
# small, throwaway fixture trees rather than only this repo's own real
# tree, so both the passing and failing path are proven -- per AG-VAL-024,
# a check that only ever runs against an already-green tree never actually
# proves its fail-closed path is reachable.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/untracked/check-dependabot-docker-base-consistency.sh"
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
    # Dockerfile instruction names are case-insensitive, so a valid
    # Dockerfile may use `from`/`From` and/or indent the instruction -- a
    # case-sensitive `^FROM ` match finds nothing for these, which under
    # set -o pipefail aborts the whole script with no diagnostic instead
    # of comparing base images.
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
    # `package-ecosystem: "docker"` and quoted directory strings are valid,
    # equivalent YAML to the unquoted forms write_dependabot_docker_block
    # uses -- a parser that only matches the unquoted spelling silently
    # finds zero directories for this equally-valid form.
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

@test "accepts a trailing YAML comment on the package-ecosystem and directory lines" {
    # `package-ecosystem: docker # runtime services` and `- /services/a #
    # primary` are both valid YAML (a comment is legal after any scalar) --
    # a parser anchored on end-of-line right after the value finds neither
    # block, silently reporting zero directories.
    cat > "$fixture_root/.github/dependabot.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: docker # runtime services
    directories:
      - /services/a # primary service
      - /services/b
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
    [[ "$output" == *"OK"* ]] || fail "did not tolerate a trailing YAML comment: $output"
}

@test "resolves an ARG-substituted FROM line and still catches a genuine divergence" {
    # `FROM ${RUNTIME_BASE}` is identical text in both Dockerfiles below,
    # but each declares a different ARG default before its own final FROM
    # line -- comparing the raw, unsubstituted text would report both as
    # "the same image" despite their effective bases actually diverging.
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    cat > "$fixture_root/services/a/Dockerfile" <<'EOF'
ARG RUNTIME_BASE=alpine:3.24
FROM ${RUNTIME_BASE}
EOF
    cat > "$fixture_root/services/b/Dockerfile" <<'EOF'
ARG RUNTIME_BASE=debian:12-slim
FROM ${RUNTIME_BASE}
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"alpine:3.24"* && "$output" == *"debian:12-slim"* ]] || \
        fail "did not resolve ARG defaults before comparing, or did not report both resolved images: $output"
}

@test "resolves an ARG-substituted FROM line and passes when the resolved images genuinely match" {
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    cat > "$fixture_root/services/a/Dockerfile" <<'EOF'
ARG RUNTIME_BASE=alpine:3.24
FROM ${RUNTIME_BASE}
EOF
    cat > "$fixture_root/services/b/Dockerfile" <<'EOF'
ARG RUNTIME_BASE=alpine:3.24
FROM ${RUNTIME_BASE}
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]] || fail "flagged two Dockerfiles resolving to the identical ARG-substituted image: $output"
}

@test "ignores stage-local ARG redeclarations when resolving a later FROM" {
    # Only ARG declarations before the first FROM have global scope and can
    # supply a later FROM image. A same-named declaration inside the first
    # stage must not replace that global default for the final stage.
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    cat > "$fixture_root/services/a/Dockerfile" <<'EOF'
ARG RUNTIME_BASE=alpine:3.24
FROM busybox:1.37 AS builder
ARG RUNTIME_BASE=debian:12-slim
RUN echo "$RUNTIME_BASE"
FROM ${RUNTIME_BASE}
EOF
    cat > "$fixture_root/services/b/Dockerfile" <<'EOF'
ARG RUNTIME_BASE=alpine:3.24
FROM ${RUNTIME_BASE}
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]] || fail "treated a stage-local ARG as the later FROM default: $output"
}

@test "stage-local ARG defaults cannot hide divergent global FROM defaults" {
    # Matching stage-local defaults do not affect later FROM instructions;
    # the different global defaults remain the effective final images and
    # therefore must still be reported as a divergence.
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    cat > "$fixture_root/services/a/Dockerfile" <<'EOF'
ARG RUNTIME_BASE=alpine:3.24
FROM busybox:1.37 AS builder
ARG RUNTIME_BASE=ubuntu:24.04
FROM ${RUNTIME_BASE}
EOF
    cat > "$fixture_root/services/b/Dockerfile" <<'EOF'
ARG RUNTIME_BASE=debian:12-slim
FROM busybox:1.37 AS builder
ARG RUNTIME_BASE=ubuntu:24.04
FROM ${RUNTIME_BASE}
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"alpine:3.24"* && "$output" == *"debian:12-slim"* ]] || \
        fail "let matching stage-local ARG defaults hide divergent global defaults: $output"
}

@test "fails closed on a FROM line referencing an ARG with no discoverable default" {
    # No ARG declaration precedes this FROM line at all (e.g. the value is
    # only ever supplied via --build-arg at build time, invisible to this
    # guard) -- cannot prove the effective base image either way, so this
    # must fail closed with a clear diagnostic rather than silently
    # comparing the literal, unresolved ${RUNTIME_BASE} text.
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    cat > "$fixture_root/services/a/Dockerfile" <<'EOF'
FROM ${RUNTIME_BASE}
EOF
    cat > "$fixture_root/services/b/Dockerfile" <<'EOF'
FROM alpine:3.24
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not resolve"* ]] || fail "did not fail closed on an unresolvable ARG reference: $output"
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

@test "resolves a final-stage alias to its originating external image" {
    # Stage aliases are local labels, so equal alias text does not prove the
    # external images behind those labels are equal.
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    cat > "$fixture_root/services/a/Dockerfile" <<'EOF'
FROM alpine:3.24 AS runtime_base
FROM runtime_base
EOF
    cat > "$fixture_root/services/b/Dockerfile" <<'EOF'
FROM debian:12-slim AS runtime_base
FROM runtime_base
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"alpine:3.24"* && "$output" == *"debian:12-slim"* ]] || \
        fail "did not resolve stage aliases before comparison: $output"
}

@test "ends Docker directory collection at a commented non-Docker update block" {
    # Comment prose must not influence which ecosystem owns the directories
    # in a subsequent update block.
    cat > "$fixture_root/.github/dependabot.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: docker
    directories:
      - /services/a
  - package-ecosystem: cargo # coordinated after docker
    directories:
      - /cargo
EOF
    mkdir -p "$fixture_root/services/a"
    printf 'FROM alpine:3.24\n' > "$fixture_root/services/a/Dockerfile"

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" != *"cargo/Dockerfile"* ]] || fail "collected a non-Docker block's directory: $output"
}

@test "substitutes complete unbraced ARG tokens with prefix-related names" {
    # Docker recognizes the longest variable-name token; replacing a shorter
    # argument name inside it can conceal different effective images.
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    cat > "$fixture_root/services/a/Dockerfile" <<'EOF'
ARG BASE=wrong
ARG BASE_TAG=alpine:3.24
FROM $BASE_TAG
EOF
    cat > "$fixture_root/services/b/Dockerfile" <<'EOF'
ARG BASE=wrong
ARG BASE_TAG=debian:12-slim
FROM $BASE_TAG
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"alpine:3.24"* && "$output" == *"debian:12-slim"* ]] || \
        fail "performed prefix substitution instead of token substitution: $output"
}

@test "accepts lowercase global ARG instructions without awk-specific extensions" {
    # Dockerfile instructions are case-insensitive, so parsing must not rely
    # on an awk implementation's optional case-folding extensions.
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    cat > "$fixture_root/services/a/Dockerfile" <<'EOF'
arg RUNTIME_BASE=alpine:3.24
from $RUNTIME_BASE
EOF
    cat > "$fixture_root/services/b/Dockerfile" <<'EOF'
ARG RUNTIME_BASE=alpine:3.24
FROM $RUNTIME_BASE
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]] || fail "did not parse lowercase global ARG: $output"
}

@test "joins a continued FROM instruction before extracting its image" {
    # Docker permits physical-line continuation in an instruction, so the
    # operand must be read from the completed logical line.
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    printf 'FROM \\\n  alpine:3.24\n' > "$fixture_root/services/a/Dockerfile"
    printf 'FROM \\\n  debian:12-slim\n' > "$fixture_root/services/b/Dockerfile"

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"alpine:3.24"* && "$output" == *"debian:12-slim"* ]] || \
        fail "did not compare continued FROM operands: $output"
}

@test "fails closed on an unsupported ARG modifier in a FROM image" {
    # Unsupported variable-expression syntax must never compare equal as
    # literal text because its effective image has not been established.
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    printf 'ARG BASE=alpine:3.24\nFROM ${BASE:-busybox:1.37}\n' > "$fixture_root/services/a/Dockerfile"
    printf 'ARG BASE=debian:12-slim\nFROM ${BASE:-busybox:1.37}\n' > "$fixture_root/services/b/Dockerfile"

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unsupported or unresolved ARG expression"* ]] || \
        fail "did not fail closed on an ARG modifier: $output"
}

@test "ignores FROM-like text inside a Dockerfile heredoc" {
    # Heredoc payload is data belonging to its parent instruction, not a
    # sequence of Dockerfile stages.
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    cat > "$fixture_root/services/a/Dockerfile" <<'EOF'
FROM alpine:3.24
RUN <<SCRIPT
FROM debian:12-slim
SCRIPT
EOF
    cat > "$fixture_root/services/b/Dockerfile" <<'EOF'
FROM alpine:3.24
RUN <<SCRIPT
FROM ubuntu:24.04
SCRIPT
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]] || fail "treated heredoc payload as a FROM instruction: $output"
}

@test "does not enter heredoc mode for heredoc-looking text in a comment" {
    # Dockerfile comments have no payload, so an unmatched marker described
    # by a comment must not hide the real final-stage FROM instruction.
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    cat > "$fixture_root/services/a/Dockerfile" <<'EOF'
FROM busybox:1.37 AS builder
# Prefer RUN <<EOF for generated configuration.
FROM alpine:3.24
EOF
    cat > "$fixture_root/services/b/Dockerfile" <<'EOF'
FROM busybox:1.37 AS builder
# Prefer RUN <<EOF for generated configuration.
FROM debian:12-slim
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"alpine:3.24"* && "$output" == *"debian:12-slim"* ]] || \
        fail "let heredoc-looking comment text hide divergent final images: $output"
}

@test "does not continue a standalone comment ending in a backslash" {
    # Docker ignores continuation markers on standalone comments, so the
    # next physical line must remain an independently parsed instruction.
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    cat > "$fixture_root/services/a/Dockerfile" <<'EOF'
FROM busybox:1.37 AS builder
# Explain the runtime choice \
FROM alpine:3.24
EOF
    cat > "$fixture_root/services/b/Dockerfile" <<'EOF'
FROM busybox:1.37 AS builder
# Explain the runtime choice \
FROM debian:12-slim
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"alpine:3.24"* && "$output" == *"debian:12-slim"* ]] || \
        fail "let a comment continuation marker hide divergent final images: $output"
}

@test "does not enter heredoc mode for heredoc-looking LABEL text" {
    # Only RUN and COPY instructions accept Dockerfile heredocs; prose in a
    # different instruction must not hide later stages.
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    cat > "$fixture_root/services/a/Dockerfile" <<'EOF'
FROM busybox:1.37 AS builder
LABEL usage="Use <<EOF in docs"
FROM alpine:3.24
EOF
    cat > "$fixture_root/services/b/Dockerfile" <<'EOF'
FROM busybox:1.37 AS builder
LABEL usage="Use <<EOF in docs"
FROM debian:12-slim
EOF

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"alpine:3.24"* && "$output" == *"debian:12-slim"* ]] || \
        fail "let LABEL text hide divergent final images: $output"
}

@test "honors a backtick Dockerfile escape parser directive" {
    # The escape parser directive changes the continuation character, so a
    # logical FROM instruction must follow that declared syntax.
    write_dependabot_docker_block
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b"
    printf '# escape=`\nFROM `\n  alpine:3.24\n' > "$fixture_root/services/a/Dockerfile"
    printf '# escape=`\nFROM `\n  debian:12-slim\n' > "$fixture_root/services/b/Dockerfile"

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"alpine:3.24"* && "$output" == *"debian:12-slim"* ]] || \
        fail "did not honor the configured backtick escape: $output"
}

@test "parses flow-style directories in every Docker update block" {
    # YAML flow sequences are equivalent to block sequences and must not
    # let a later Docker block escape validation.
    cat > "$fixture_root/.github/dependabot.yml" <<'EOF'
version: 2
updates:
  - package-ecosystem: docker
    directory: /services/a
  - package-ecosystem: docker
    directories: [/services/b, "/services/c"]
EOF
    mkdir -p "$fixture_root/services/a" "$fixture_root/services/b" "$fixture_root/services/c"
    printf 'FROM busybox:1.37\n' > "$fixture_root/services/a/Dockerfile"
    printf 'FROM alpine:3.24\n' > "$fixture_root/services/b/Dockerfile"
    printf 'FROM debian:12-slim\n' > "$fixture_root/services/c/Dockerfile"

    run bash "$script" "$fixture_root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"alpine:3.24"* && "$output" == *"debian:12-slim"* ]] || \
        fail "did not validate the flow-style Docker block: $output"
}
