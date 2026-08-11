#!/usr/bin/env python3
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

from pathlib import Path
import re

path = Path('.github/workflows/build-push.yml')
text = path.read_text(encoding='utf-8')


def sub_once(value: str, pattern: str, replacement: str, label: str, flags: int = 0) -> str:
    updated, count = re.subn(pattern, replacement, value, count=1, flags=flags)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one match, got {count}')
    return updated


build_start = text.index('  build:\n')
arm_start = text.index('  build-arm64:\n', build_start)
merge_start = text.index('  merge-manifests:\n', arm_start)
build = text[build_start:arm_start]
arm = text[arm_start:merge_start]

build = sub_once(
    build,
    r'\A(  build:\n)(?:    #.*\n|    #\n)+(?=    needs:)',
    '  build:\n'
    '    # Same-repository candidates keep their pushed digest through scan and downstream assembly.\n'
    '    # Metadata-only PR events reuse the prior commit because they carry no new image content.\n',
    'build preamble',
)

build = sub_once(
    build,
    r'    # Per-service runner selection.*\n    #.*\n    #.*\n(?=    runs-on:)',
    '    # Compile-heavy services use heavy capacity; lighter image assembly stays on light runners.\n',
    'build runner rationale',
)

build = sub_once(
    build,
    r'(    timeout-minutes: 150\n)(?:    #.*\n|    #\n)+(?=    concurrency:\n)',
    r'\1'
    '    # Obsolete PR builds may be cancelled to reclaim runners; push/tag candidates must survive for publication.\n'
    '    # Dispatches and reruns include the run id so separate attempts cannot cancel each other.\n',
    'build concurrency rationale',
)

build = sub_once(
    build,
    r'(      matrix:\n)        include:\n(?:          #.*\n)+',
    r'\1'
    '        include: &normal-build-services\n'
    '          # Package/COPY-only images use light runners; compile-heavy services stay on heavy capacity.\n'
    '          # Re-evaluate a service tier if its Dockerfile gains real compile or link work.\n',
    'build matrix anchor',
)

build = sub_once(
    build,
    r'            # cdn-domains\.txt lives.*\n            # build context .*\n            # comment for why a named additional context is needed here\.\n',
    '            # Proxy needs DNS domain data that lives outside its own build context.\n',
    'proxy build-context rationale',
)

arm = sub_once(
    arm,
    r'\A(  build-arm64:\n)(?:    #.*\n|    #\n)+(?=    needs:)',
    '  build-arm64:\n'
    '    # Native arm64 candidates mirror the amd64 artifact contract before manifest assembly.\n'
    '    # Metadata-only PR events reuse the prior commit because they carry no new image content.\n',
    'arm64 preamble',
)

arm = sub_once(
    arm,
    r'(    timeout-minutes: 120\n)(?:    #.*\n|    #\n)+(?=    concurrency:\n)',
    r'\1'
    '    # Obsolete PR arm64 work may be cancelled; push/tag candidates must survive for manifest assembly.\n'
    '    # Dispatches and reruns use isolated concurrency keys.\n',
    'arm64 concurrency rationale',
)

arm = sub_once(
    arm,
    r'(    strategy:\n      fail-fast: false\n      matrix:\n)        include:\n.*?(?=\n    steps:\n)',
    r'\1        include: *normal-build-services\n',
    'arm64 matrix alias',
    flags=re.DOTALL,
)

text = text[:build_start] + build + arm + text[merge_start:]

if text.count('&normal-build-services') != 1:
    raise SystemExit('expected exactly one normal-build-services anchor')
if text.count('*normal-build-services') != 1:
    raise SystemExit('expected exactly one normal-build-services alias')

anchor_start = text.index('        include: &normal-build-services\n')
anchor_end = text.index('\n    steps:\n', anchor_start)
services = re.findall(r'^          - service: ([a-z0-9-]+)$', text[anchor_start:anchor_end], flags=re.MULTILINE)
expected = ['proxy', 'dns', 'watchdog', 'dhcp', 'dhcp-proxy', 'ntp', 'syslog', 'ui', 'build-tools']
if services != expected:
    raise SystemExit(f'canonical build services changed unexpectedly: {services!r}')

arm_start = text.index('  build-arm64:\n')
merge_start = text.index('  merge-manifests:\n', arm_start)
arm = text[arm_start:merge_start]
if re.search(r'^\s+- service:', arm, flags=re.MULTILINE):
    raise SystemExit('build-arm64 still contains a duplicated literal service list')
if 'matrix.runner' in arm:
    raise SystemExit('build-arm64 unexpectedly consumes the amd64-only runner field')
if '    runs-on: ubuntu-24.04-arm\n' not in arm:
    raise SystemExit('build-arm64 runner changed unexpectedly')
if '    runs-on: ${{ fromJSON(matrix.runner) }}\n' not in build:
    raise SystemExit('build runner routing changed unexpectedly')

path.write_text(text, encoding='utf-8')
