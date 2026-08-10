#!/usr/bin/env python3
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Temporary guarded migration of stack-image CI assertions to digest identity."""
from pathlib import Path

path = Path('scripts/validate-stack-images.sh')
text = path.read_text()

def replace(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected one source block, found {count}')
    text = text.replace(old, new)

replace(
'''require_grep 'docker buildx imagetools inspect "\\$source_image"' \\
  .github/workflows/build-push.yml \\
  'promotion must verify every sha-* source image before moving a public channel'
''',
'''require_grep 'source_tag_digest="\\$\\(digest_for_image "\\$source_tag_image"\\)"' \\
  .github/workflows/build-push.yml \\
  'promotion must verify the sha-* record still resolves to the exact producer digest before moving a public channel'
''',
'promotion source identity guard',
)

replace(
'''require_grep 'bash scripts/require-image-platforms\\.sh "ghcr\\.io/\\$\\{REPOSITORY\\}/\\$\\{service\\}:\\$\\{source_tag\\}" "\\$REQUIRED_PLATFORMS"' \\
  .github/workflows/build-push.yml \\
  'promotion must verify every sha-* service image platform before moving public tags'
''',
'''require_grep 'bash scripts/require-image-platforms\\.sh "ghcr\\.io/\\$\\{REPOSITORY\\}/\\$\\{service\\}@\\$\\{expected_digest\\}" "\\$REQUIRED_PLATFORMS"' \\
  .github/workflows/build-push.yml \\
  'promotion must verify every exact service digest platform before moving public tags'
''',
'promotion exact platform guard',
)

replace(
'''require_grep 'stack_pointer_image="ghcr\\.io/\\$\\{REPOSITORY\\}/stack:\\$\\{source_tag\\}"' \\
  .github/workflows/build-push.yml \\
  'promotion must create an immutable stack pointer image for the source commit'
''',
'''require_grep 'stack_pointer_image="ghcr\\.io/\\$\\{REPOSITORY\\}/stack@\\$\\{STACK_DIGEST\\}"' \\
  .github/workflows/build-push.yml \\
  'promotion must consume the immutable stack BOM digest created before validation'
require_grep 'COPY stack-bom\\.json /stack-bom\\.json' \\
  .github/workflows/build-push.yml \\
  'the immutable stack artifact must record an explicit stack BOM alongside stack.env'
''',
'stack BOM guard',
)

insert_after = '''require_grep 'subject-digest: \\$\\{\\{ steps\\.build\\.outputs\\.digest \\$\\}\\}' \\
  .github/workflows/build-push.yml \\
  'provenance attestations must bind to the pushed image digest'
'''
addition = '''require_grep 'uses: \\./\\.github/actions/trivy-scan-exact-digest' \\
  .github/workflows/build-push.yml \\
  'candidate security scans must consume the immutable digest produced by the build job'
require_grep 'image-ref: ghcr\\.io/\\$\\{\\{ github\\.repository \\$\\}\\}/\\$\\{\\{ matrix\\.service \\$\\}\\}@\\$\\{\\{ steps\\.build\\.outputs\\.digest \\$\\}' \\
  .github/workflows/build-push.yml \\
  'candidate security scans must bind to the exact build output digest'
'''
if text.count(insert_after) != 1:
    raise SystemExit(f'exact scan insertion point: expected one source block, found {text.count(insert_after)}')
text = text.replace(insert_after, insert_after + addition)

path.write_text(text)
print('stack-image guards migrated to exact digest identity')
