#!/usr/bin/env python3
"""Bootstrap inventory; source-public declarations are not reachable API proofs."""
import argparse
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import subprocess
import tempfile


class Headings(HTMLParser):
    def __init__(self):
        super().__init__()
        self.rows = []
        self.current = None

    def handle_starttag(self, tag, attrs):
        if re.fullmatch(r'h[1-6]', tag):
            self.current = {'level': int(tag[1]), 'id': dict(attrs).get('id'), 'text': ''}

    def handle_data(self, data):
        if self.current is not None:
            self.current['text'] += data

    def handle_endtag(self, tag):
        if self.current is not None and tag == f"h{self.current['level']}":
            self.current['text'] = ' '.join(self.current['text'].split())
            self.rows.append(self.current)
            self.current = None


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run(*args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(f"{args[0]} {args[1]} exited {result.returncode}: {result.stderr.decode(errors='replace')[:4000]}")
    return result.stdout


def env_field(text, name):
    match = re.search(r'\.' + re.escape(name) + r'\s*=\s*("(?:[^"\\]|\\.)*")', text)
    if not match:
        raise ValueError(f'zig env omitted {name}')
    return json.loads(match[1])


def commands(text):
    section = text.split('Commands:', 1)[1].split('General Options:', 1)[0]
    return [{'name': m[1], 'description': m[2]} for line in section.splitlines()
            if (m := re.fullmatch(r'\s{2}(\S+)\s{2,}(.*)', line))]


def inventory(zig):
    version = run(zig, 'version').decode().strip()
    env = run(zig, 'env').decode()
    std_dir = Path(env_field(env, 'std_dir'))
    lib_dir = Path(env_field(env, 'lib_dir'))
    executable = Path(env_field(env, 'zig_exe'))
    langref = lib_dir.parent / 'doc' / 'langref.html'
    help_bytes = run(zig, '--help')
    targets = run(zig, 'targets')
    source_files = sorted(std_dir.rglob('*.zig'))
    helper = Path(__file__).with_name('zig-stdlib-inventory.zig')
    with tempfile.TemporaryDirectory(prefix='cell-zig-parity-', dir='/private/tmp') as scratch:
        binary = str(Path(scratch) / 'inventory')
        run(zig, 'build-exe', str(helper), '-O', 'ReleaseSafe', '-femit-bin=' + binary)
        rows = []
        # Keep each argv bounded while preserving source order.
        for start in range(0, len(source_files), 100):
            raw = run(binary, *(str(p) for p in source_files[start:start + 100]))
            rows.extend(json.loads(line) for line in raw.splitlines())
    for row in rows:
        path = Path(row['path'])
        row['path'] = path.relative_to(std_dir).as_posix()
        row['sha256'] = digest(path.read_bytes())
    parser = Headings()
    langref_bytes = langref.read_bytes()
    parser.feed(langref_bytes.decode())
    manifest = [{'path': row['path'], 'sha256': row['sha256']} for row in rows]
    return {
        'schema_version': 1,
        'purpose': 'bootstrap development tooling; not Cell self-hosting',
        'coverage': {
            'stdlib': 'AST public function/constant/variable declarations in all std .zig files, including nested and unreachable declarations',
            'reachable_api': 'not evaluated; imports, aliases, comptime branches and generated types require semantic analysis',
            'language': 'local language-reference headings, not a complete capability or builtin inventory',
            'targets': 'verbatim zig targets ZON; availability does not prove target execution',
        },
        'zig': {'version': version, 'executable_sha256': digest(executable.read_bytes())},
        'stdlib': {'manifest_sha256': digest(json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()),
                   'file_count': len(rows), 'declaration_count': sum(len(r['declarations']) for r in rows), 'files': rows},
        'language_reference': {'sha256': digest(langref_bytes), 'headings': parser.rows},
        'commands': {'help_sha256': digest(help_bytes), 'entries': commands(help_bytes.decode())},
        'targets': {'sha256': digest(targets), 'zon': targets.decode()},
        'extractor_sha256': digest(helper.read_bytes()),
        'driver_sha256': digest(Path(__file__).read_bytes()),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', default='zig')
    args = parser.parse_args()
    print(json.dumps(inventory(args.zig), sort_keys=True, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
