#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Regression guard for bug-hunt #849 finding #3: CERT_DIR
# (/etc/nginx/ssl/certs, entrypoint.sh's per-domain wildcard cert directory)
# had no named volume in either deploy/prod or deploy/quickstart, only the
# Dockerfile's own anonymous VOLUME fallback -- every `down && up`/recreate
# silently lost every generated cert. This greps the real, checked-in
# Compose files directly (not a copy) so a future edit that removes the
# named volume fails this suite immediately. Docker Compose YAML validity
# itself (`docker compose config`) is a separate, already-required check per
# AG-VAL-009 -- this file only asserts the specific mount/volume-name
# pairing this finding is about.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    prod_compose="$repo_root/deploy/prod/docker-compose.yml"
    quickstart_compose="$repo_root/deploy/quickstart/docker-compose.yml"
}

@test "deploy/prod mounts a real named volume (not the Dockerfile's anonymous one) at CERT_DIR" {
    grep -qE '^\s+- proxy-certs:/etc/nginx/ssl/certs$' "$prod_compose"
}

@test "deploy/prod declares the proxy-certs volume in its top-level volumes: block" {
    grep -qE '^  proxy-certs:$' "$prod_compose"
}

@test "deploy/quickstart mounts the same named volume at CERT_DIR" {
    grep -qE '^\s+- proxy-certs:/etc/nginx/ssl/certs$' "$quickstart_compose"
}

@test "deploy/quickstart declares the proxy-certs volume in its top-level volumes: block" {
    grep -qE '^  proxy-certs:$' "$quickstart_compose"
}

# deploy/secondary and deploy/full-setup deliberately do NOT get this
# volume: secondary has no proxy service at all, and full-setup is an
# ephemeral CI validation harness torn down after each run (it doesn't even
# mount the CA volume itself, so cert persistence across runs was never its
# goal) -- confirmed directly rather than assumed.
@test "deploy/secondary has no proxy service to need this volume" {
    secondary_compose="$repo_root/deploy/secondary/docker-compose.yml"
    ! grep -qE '^  proxy:$' "$secondary_compose"
}
