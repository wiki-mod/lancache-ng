#!/usr/bin/env python3
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

from pathlib import Path
import subprocess
import tempfile

body = Path('.github/cdx-1522-service-metadata-body.py')
text = body.read_text(encoding='utf-8')
text = text.replace(
    "if build.count(f'&ci-description-{service}') != 1:\n",
    "if build.count(f'&ci-description-{service} \\\"') != 1:\n",
)
text = text.replace(
    "if build.count(f'*ci-description-{service}') != 1:\n",
    "if build.count(f'*ci-description-{service}\\n') != 1:\n",
)
with tempfile.NamedTemporaryFile('w', suffix='.py', delete=False, encoding='utf-8') as handle:
    handle.write(text)
    fixed_transformer = handle.name
subprocess.run(['python3', fixed_transformer], check=True)
Path(fixed_transformer).unlink()
body.unlink()

guard_path = Path('scripts/check-workflow-service-lists.sh')
guard = guard_path.read_text(encoding='utf-8')
replacements = {
    'if (line ~ /^\\".*\\"$/) {': 'if (line ~ /^".*"$/) {',
    'sub(/^\\"/, "", line)': 'sub(/^"/, "", line)',
    'sub(/\\"$/, "", line)': 'sub(/"$/, "", line)',
    'sub(/^\\"/, "", value)': 'sub(/^"/, "", value)',
    'sub(/\\"$/, "", value)': 'sub(/"$/, "", value)',
    'build-push.yml plus the 3 additional real files above': 'build-push.yml plus the additional real files below',
    '# The matrix-source file itself always requires at least one services=(...)\n# copy (this is build-push.yml\'s own long-standing invariant, preserved\n# exactly for the single-file bats-fixture invocation too). It is not itself\n# required to declare full_setup_services=(...) -- a bats fixture testing\n# only the services=(...) equality case has no reason to include one.\n': '# The production workflow uses CI_BUILD_SERVICES; legacy synthetic fixtures may\n# still use services=(...). full_setup_services=(...) remains optional here.\n',
}
for old, new in replacements.items():
    if old not in guard:
        raise SystemExit(f'guard cleanup pattern missing: {old!r}')
    guard = guard.replace(old, new)
guard_path.write_text(guard, encoding='utf-8')
