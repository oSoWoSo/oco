#!/usr/bin/env python3
"""Synchronize root Manual.md, then render it with the site's Pandoc dependency.

Usage: gen-manual.py ROOT OUTPUT [ARCH ...]
       gen-manual.py --sync-only ROOT
Local source: $XBPS_DISTDIR/Manual.md when present; otherwise upstream master.
No stale-source fallback is allowed. The downloaded Markdown is also published
unchanged as Manual.md next to the generated HTML.
"""

import hashlib
import html
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.request import Request, urlopen

UPSTREAM = 'https://raw.githubusercontent.com/void-linux/void-packages/master/Manual.md'


def synchronize(root):
    destination = Path(root).resolve() / 'Manual.md'
    distdir = os.environ.get('XBPS_DISTDIR')
    local = Path(distdir).expanduser() / 'Manual.md' if distdir else None
    if local is not None and local.is_file():
        content = local.read_bytes()
    else:
        with urlopen(Request(UPSTREAM, headers={'User-Agent': 'oco-manual-generator'}), timeout=30) as response:
            if response.status != 200:
                raise RuntimeError(f'Manual fetch returned HTTP {response.status}')
            content = response.read()
    if not content.strip():
        raise ValueError('Manual source is empty; refusing stale-source fallback')
    digest = hashlib.sha256(content).digest()
    if destination.exists() and hashlib.sha256(destination.read_bytes()).digest() == digest:
        return content
    temporary = None
    try:
        # Same directory/filesystem makes os.replace atomic.
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix='.Manual.md.', delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.chmod(0o644)
        os.replace(temporary, destination)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return content


def inline_text(value):
    if isinstance(value, list):
        return ''.join(inline_text(item) for item in value)
    if not isinstance(value, dict):
        return ''
    kind, content = value['t'], value.get('c')
    if kind == 'Str':
        return content
    if kind in ('Space', 'SoftBreak', 'LineBreak'):
        return ' '
    if kind in ('Code', 'Math'):
        return content[1]
    if kind in ('Link', 'Image', 'Span'):
        return inline_text(content[1])
    return inline_text(content)


def render(root, output, architectures):
    original = synchronize(root)
    output = Path(output)
    template = Path(__file__).with_name('manual-index-template.html').read_text()
    document = json.loads(subprocess.check_output(
        ['pandoc', '--from=gfm', '--to=json'], input=original))
    groups, current = [], []
    title, level = 'The XBPS source packages manual', 1
    for block in document['blocks']:
        if block['t'] == 'Header':
            if current:
                groups.append((title, level, current))
            level, _, inlines = block['c']
            title = inline_text(inlines).strip()
            current = []
        current.append(block)
    if current:
        groups.append((title, level, current))
    if not groups:
        raise ValueError('Manual contains no renderable content')

    # Retain every source block, heading ID and explicit HTML anchor.
    wrappers, toc = [], ['<ol>']
    for index, (title, level, blocks) in enumerate(groups):
        identifier = f'manual-section-{index + 1}'
        wrappers.append({'t': 'Div', 'c': [
            [identifier, ['manual-section'], [['data-title', title]]], blocks]})
        toc.append(f'<li class="manual-depth-{min(level, 6)}"><a href="#{identifier}">{html.escape(title)}</a></li>')
    toc.append('</ol>')
    document['blocks'] = wrappers
    content = subprocess.check_output(
        ['pandoc', '--from=json', '--to=html5', '--wrap=none'],
        input=json.dumps(document).encode()).decode()
    content = content.replace('href="./CONTRIBUTING.md"',
        'href="https://github.com/void-linux/void-packages/blob/master/CONTRIBUTING.md"')
    navigation = '\n'.join(
        f'<li><a data-package-arch="{html.escape(arch, quote=True)}" href="{html.escape(arch, quote=True)}/">{html.escape(arch)}</a></li>'
        for arch in architectures)
    replacements = {
        '__NAV_ARCH_LINKS__': navigation,
        '__MANUAL_TOC__': '\n'.join(toc),
        '__MANUAL_CONTENT__': content,
    }
    for marker, value in replacements.items():
        template = template.replace(marker, value)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(template)
    (output.parent / 'Manual.md').write_bytes(original)


if __name__ == '__main__':
    try:
        if len(sys.argv) == 3 and sys.argv[1] == '--sync-only':
            synchronize(sys.argv[2])
        elif len(sys.argv) >= 3:
            render(sys.argv[1], sys.argv[2], sys.argv[3:])
        else:
            sys.exit(__doc__)
    except Exception as error:
        sys.exit(f'Manual generation failed: {error}')
