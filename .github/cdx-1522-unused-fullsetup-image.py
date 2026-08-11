#!/usr/bin/env python3
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

from pathlib import Path
import re


def remove_named_step(text: str, name: str, expected: int = 1) -> str:
    pattern = re.compile(rf"(?ms)^      - name: {re.escape(name)}\n.*?(?=^      - name: |^  [A-Za-z0-9_-]+:\n|\Z)")
    matches = list(pattern.finditer(text))
    if len(matches) != expected:
        raise SystemExit(f"{name}: expected {expected} step, got {len(matches)}")
    return pattern.sub("", text, count=expected)


build_path = Path('.github/workflows/build-push.yml')
build = build_path.read_text(encoding='utf-8')
build = remove_named_step(build, 'Build full-setup validation image')
cleanup_pattern = re.compile(
    r"(?ms)^      - name: Clean up image\n"
    r"        if: always\(\)\n"
    r"        run: \|\n"
    r"          docker rmi lancache-ng-full-setup:validation \|\| true\n"
    r"          rm -f deploy/full-setup/\.ci-exact-digests\.yml\n"
)
if len(cleanup_pattern.findall(build)) != 1:
    raise SystemExit('build-push cleanup: expected exactly one full-setup validation-image cleanup block')
build = cleanup_pattern.sub(
    "      - name: Clean up exact-digest override\n"
    "        if: always()\n"
    "        run: rm -f deploy/full-setup/.ci-exact-digests.yml\n",
    build,
    count=1,
)
build_path.write_text(build, encoding='utf-8')

sims_path = Path('.github/workflows/full-setup-sims.yml')
sims = sims_path.read_text(encoding='utf-8')
sims = remove_named_step(sims, 'Build full-setup validation image')
sims = remove_named_step(sims, 'Clean up image')
sims_path.write_text(sims, encoding='utf-8')
