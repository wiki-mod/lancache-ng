#!/usr/bin/env python3
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Temporary source hotfix for the one-shot CI 1.1 patcher."""
from pathlib import Path

path = Path(__file__).with_name("ci-1.1-apply.py")
text = path.read_text()
start_marker = '        old = """            ghcr_retry ghcr.io'
end_marker = '        if trusted:\n'
start = text.find(start_marker)
if start < 0:
    raise SystemExit("hotfix: old exact manifest matcher not found")
end = text.find(end_marker, start)
if end < 0:
    raise SystemExit("hotfix: trusted branch marker not found")

replacement = r'''        pattern = (
            r'(?m)^            ghcr_retry ghcr\.io .*?-- \\s*$\n'
            r'^              docker buildx imagetools create -t "\$target_image" "\$amd64_image" "\$arm64_image" \\s*$\n'
        )
        new = """            amd64_digest="$(digest_for_image "$amd64_image")"
            arm64_digest="$(digest_for_image "$arm64_image")"
            [[ "$amd64_digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || { echo "::error::Invalid amd64 digest for $service: $amd64_digest"; exit 1; }
            [[ "$arm64_digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || { echo "::error::Invalid arm64 digest for $service: $arm64_digest"; exit 1; }
            amd64_ref="ghcr.io/${REPOSITORY}/${service}@${amd64_digest}"
            arm64_ref="ghcr.io/${REPOSITORY}/${service}@${arm64_digest}"

            ghcr_retry ghcr.io "$GHCR_RETRY_USERNAME" "$GHCR_RETRY_PASSWORD" -- \\
              docker buildx imagetools create -t "$target_image" "$amd64_ref" "$arm64_ref" \\
"""
        step = replace_regex(step, pattern, new, label="merge exact child digests")
'''
path.write_text(text[:start] + replacement + text[end:])
print("hotfix: patcher manifest matcher updated")
