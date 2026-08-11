#!/usr/bin/env python3
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

from pathlib import Path

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
body.unlink()
exec(compile(text, '.github/cdx-1522-service-metadata-body.py', 'exec'))
