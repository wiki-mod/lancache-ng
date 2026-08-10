#!/usr/bin/env python3
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Temporary source hotfix for the one-shot CI 1.1 patcher."""
from pathlib import Path

path = Path(__file__).with_name("ci-1.1-apply.py")
text = path.read_text()
start_marker = '        old = """            ghcr_retry ghcr.io'
if start_marker not in text:
    start_marker = '        pattern = (\n'
end_marker = '        if trusted:\n'
start = text.find(start_marker)
if start < 0:
    raise SystemExit("hotfix: manifest matcher source not found")
end = text.find(end_marker, start)
if end < 0:
    raise SystemExit("hotfix: trusted branch marker not found")

replacement = r'''        lines = step.splitlines(keepends=True)
        marker_indexes = [
            i for i, line in enumerate(lines)
            if 'docker buildx imagetools create -t "$target_image" "$amd64_image" "$arm64_image"' in line
        ]
        if len(marker_indexes) != 1:
            fail(f"merge exact child digests: expected one imagetools source line, found {len(marker_indexes)}")
        marker_index = marker_indexes[0]
        ghcr_index = marker_index - 1
        if ghcr_index < 0 or "ghcr_retry ghcr.io" not in lines[ghcr_index]:
            fail("merge exact child digests: preceding ghcr_retry line not found")
        digest_lines = """            amd64_digest="$(digest_for_image "$amd64_image")"
            arm64_digest="$(digest_for_image "$arm64_image")"
            [[ "$amd64_digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || { echo "::error::Invalid amd64 digest for $service: $amd64_digest"; exit 1; }
            [[ "$arm64_digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || { echo "::error::Invalid arm64 digest for $service: $arm64_digest"; exit 1; }
            amd64_ref="ghcr.io/${REPOSITORY}/${service}@${amd64_digest}"
            arm64_ref="ghcr.io/${REPOSITORY}/${service}@${arm64_digest}"

"""
        lines.insert(ghcr_index, digest_lines)
        marker_index += 1
        source_line = lines[marker_index]
        replaced_line = source_line.replace(
            '"$amd64_image" "$arm64_image"',
            '"$amd64_ref" "$arm64_ref"',
        )
        if replaced_line == source_line:
            fail("merge exact child digests: source arguments were not replaced")
        lines[marker_index] = replaced_line
        step = ''.join(lines)
'''
text = text[:start] + replacement + text[end:]

old = '        "          matrix:\\n            service: [proxy, dns, watchdog, dhcp, dhcp-proxy, ntp, ui, build-tools]\\n",\n'
new = '        "        service: [proxy, dns, watchdog, dhcp, dhcp-proxy, ntp, ui, build-tools]\\n",\n'
if text.count(old) != 1:
    raise SystemExit(f"hotfix: release SBOM source literal expected once, found {text.count(old)}")
text = text.replace(old, new)
old = '        "          matrix:\\n            service: [proxy, dns, watchdog, dhcp, dhcp-proxy, ntp, syslog, ui, build-tools]\\n",\n'
new = '        "        service: [proxy, dns, watchdog, dhcp, dhcp-proxy, ntp, syslog, ui, build-tools]\\n",\n'
if text.count(old) != 1:
    raise SystemExit(f"hotfix: release SBOM replacement literal expected once, found {text.count(old)}")
text = text.replace(old, new)

path.write_text(text)
print("hotfix: patcher source aligned")
