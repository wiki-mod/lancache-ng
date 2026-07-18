#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Bats helper that loads setup.sh's prebuilt-image platform guard functions
# (assert_prebuilt_image_platform_supported, host_image_platform,
# assert_resolved_image_tag_platform_supported -- see #665) without executing
# setup.sh's install/update entrypoint. Extracts the real functions by name so
# tests exercise production logic rather than test-only copies.

load_setup_platform_helpers() {
    local repo_root="$1" helper_file="$2"

    {
        # die() normally exits the whole process, which would kill the bats
        # test runner. Stub it to return non-zero instead so `run` can assert
        # on failure the same way it does in setup-env-helpers.sh.
        printf '%s\n' 'die() { printf "%s\n" "$*" >&2; return 1; }'

        # awk script below parses setup.sh and extracts just the bodies of the
        # 3 wanted platform-guard functions by matching their declarations and
        # copying lines until a closing brace is found. This avoids sourcing
        # the entire setup.sh (which would run install/update logic and fail
        # on test runners), while ensuring tests exercise the real production
        # functions, not copies.
        awk '
            function want(name) {
                return name == "assert_prebuilt_image_platform_supported" \
                    || name == "host_image_platform" \
                    || name == "assert_resolved_image_tag_platform_supported"
            }
            !capture && /^[a-z0-9_]+\(\) \{/ {
                fname = $0
                sub(/\(\).*/, "", fname)
                if (want(fname)) { capture = 1; print; next }
            }
            capture {
                print
                if ($0 == "}") { capture = 0 }
            }
        ' "$repo_root/setup.sh"
    } > "$helper_file"

    # shellcheck source=/dev/null
    source "$helper_file"
}
