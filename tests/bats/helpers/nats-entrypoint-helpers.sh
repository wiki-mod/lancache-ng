#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Extraction helper for nats_conf_entrypoint_idempotence.bats.
#
# Unlike the DNS/proxy/dhcp-proxy services, the `nats` container runs the
# upstream nats:2-alpine image directly -- there is no Dockerfile to COPY a
# services/nats/entrypoint.sh into, so its static-nats.conf generator lives
# inline in each deploy/*/docker-compose.yml `nats:` service `command:` block.
# That inline placement is exactly why the config generation could not be
# reached by this project's other entrypoint idempotence suites (which source a
# real services/<svc>/entrypoint.sh). This helper closes that gap by extracting
# the REAL shipping command block and materializing it as a runnable script, so
# the suite drives the actual bytes twice rather than a re-implementation -- the
# same "test the real function, not a copy" discipline
# dns_config_snapshot_idempotence.bats follows.
#
# Two of the three transformations below faithfully reproduce what the
# container's `/bin/sh -c` actually receives, so the extracted script behaves
# byte-for-byte like the shipping entrypoint:
#
#   1. YAML block-scalar dedent -- the `command: - |` literal block is indented
#      8 spaces in the compose file; the YAML parser strips that block
#      indentation before the shell ever sees it. Without stripping it here the
#      heredoc's column-0 `EOF` terminator would not match its indented body and
#      the heredoc would never close, so the "real bytes" would not even run.
#   2. Docker Compose `$$` -> `$` -- Compose un-escapes doubled dollar signs
#      (used in the compose file so `$JS.API.*` subjects and shell `$var`
#      references survive Compose's own interpolation) before invoking the shell.
#
# The third transformation is the ONLY test-time deviation from the shipping
# bytes: it relocates the three hardcoded absolute write targets
# (/etc/nats, /var/log/lancache-nats, /tmp/nats.conf.template) under a sandbox
# root so the script runs hermetically as an unprivileged bats user. It rewrites
# mount points only -- never the heredoc template content, the env-var `sed`
# substitution, or the never-overwrite `if [ ! -e .../auth_callout.conf ]`
# branch, which are the actual convergence logic under test (the never-overwrite
# branch is the property that keeps issue #811's auth_callout clobber fixed).

# extract_nats_entrypoint_command <compose_file> <sandbox_root> <out_script>
# Materialize the nats service's inline entrypoint command as a runnable script
# at <out_script>, with absolute write targets relocated under <sandbox_root>.
# Fails (non-zero) if the compose file is missing, the `nats:` command block
# cannot be located, or the extracted script no longer contains the expected
# config-generator anchors -- so a future compose refactor that moves or renames
# this logic surfaces as a red test here instead of a silently-empty extraction
# that would trivially "pass".
extract_nats_entrypoint_command() {
    local compose="$1" sandbox_root="$2" out="$3"

    if [ ! -f "$compose" ]; then
        printf 'extract_nats_entrypoint_command: compose file not found: %s\n' "$compose" >&2
        return 1
    fi

    # Capture the `nats:` service's `command:` literal block. `in_nats` latches
    # on the `  nats:` service header and clears at the next top-level (2-space)
    # service key; `in_cmd` latches on that service's `    command:` line and
    # clears at the next 4-space key (e.g. `    volumes:`), which bounds the
    # 8-space-indented block-scalar body. The `      - |` block-scalar marker
    # line itself is dropped.
    awk '
        /^  nats:/ { in_nats = 1 }
        in_nats && /^  [a-z][a-z0-9_-]*:$/ && !/^  nats:/ { in_nats = 0 }
        in_nats && /^    command:/ { in_cmd = 1; next }
        in_cmd && /^    [a-z]/ { in_cmd = 0 }
        in_cmd {
            if ($0 ~ /^      - \|/) next
            print
        }
    ' "$compose" \
        | sed -e 's/^        //' \
              -e 's/\$\$/$/g' \
              -e "s#/etc/nats#${sandbox_root}/etc/nats#g" \
              -e "s#/var/log/lancache-nats#${sandbox_root}/var/log/lancache-nats#g" \
              -e "s#/tmp/nats.conf.template#${sandbox_root}/tmp/nats.conf.template#g" \
        > "$out"

    if ! grep -q 'exec nats-server -c' "$out" \
        || ! grep -q 'cat > .*nats.conf.template' "$out"; then
        printf 'extract_nats_entrypoint_command: extracted script from %s is missing the expected nats config-generator anchors (compose layout changed?)\n' "$compose" >&2
        return 1
    fi
}

# run_nats_entrypoint <script> <sandbox_root> <stub_bin>
# Run an extracted entrypoint script once. Pre-creates the sandbox `/tmp`
# (always present in the real container, but the script only mkdir -p's its
# /etc/nats and /var/log targets, not /tmp) and puts the stub `nats-server` /
# `chown` ahead of PATH: `exec nats-server` is the script's final line, so a
# no-op stub lets the generation complete and return 0 without a real server,
# and `chown 10001:10001` (the real-container ownership handoff to the Admin UI
# user) would otherwise fail for the unprivileged bats user.
run_nats_entrypoint() {
    local script="$1" sandbox_root="$2" stub_bin="$3"
    mkdir -p "$sandbox_root/tmp"
    PATH="$stub_bin:$PATH" sh "$script"
}
