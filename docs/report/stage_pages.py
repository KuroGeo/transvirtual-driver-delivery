#!/usr/bin/env python3
"""Export only the presentation and its curated citations to a Pages artifact."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    subprocess.run(['git', 'diff', '--exit-code', 'HEAD', '--', 'docs/report'],
                   cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    dest = args.destination.resolve()
    if dest == HERE or dest == ROOT:
        parser.error('Use a dedicated export directory.')
    dest.mkdir(parents=True, exist_ok=True)
    for name in ['index.html', 'collaboration.json', 'commit-show.txt', 'ai-usage.md']:
        (dest / name).write_bytes((HERE / name).read_bytes())
    history = json.loads((HERE / 'history.json').read_text())
    public_history = {
        'snapshot': history['snapshot'],
        'scope': 'Curated merged PR index. Full PR bodies, raw chats and private email attachments are not exported.',
        'pull_requests': [
            {key: item[key] for key in ['number', 'title', 'url', 'mergedAt', 'mergeCommit']} |
            {'file_count': len(item['files'])}
            for item in history['pull_requests']
        ],
    }
    (dest / 'history.json').write_text(json.dumps(public_history, ensure_ascii=False, indent=2) + '\n')
    (dest / '.nojekyll').write_text('')
    files = ['index.html', 'collaboration.json', 'history.json', 'commit-show.txt', 'ai-usage.md', '.nojekyll']
    manifest = {
        'source_repository': 'KuroGeo/transvirtual-driver-delivery',
        'source_commit': source,
        'application_history_snapshot': history['snapshot'],
        'public_site': 'https://kurogeo.github.io/transvirtual-driver-delivery/',
        'scope': 'Interview presentation only; not a Flutter app deployment.',
        'files': [
            {'path': name, 'bytes': (dest / name).stat().st_size,
             'sha256': hashlib.sha256((dest / name).read_bytes()).hexdigest()}
            for name in files
        ],
    }
    (dest / 'publication.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'destination': str(dest), 'source_commit': source, 'files': len(files)}, indent=2))


if __name__ == '__main__':
    main()
