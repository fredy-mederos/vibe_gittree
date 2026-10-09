#!/usr/bin/env python3
"""Build a self-contained commit-graph page (one HTML file) for any git repository.

    python3 scripts/build.py ~/path/to/repo
    python3 scripts/build.py ~/path/to/repo -o dist/my-repo.html --title "My Repo Graph"

Runs `git log` / `git for-each-ref` on the repo, packs the result as compact JSON and
injects it into src/template.html. No dependencies beyond Python 3 and git.
"""
import argparse
import collections
import html
import json
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATE = os.path.join(ROOT, 'src', 'template.html')
SEP = '\x1f'


def git(repo, *args, check=True):
    res = subprocess.run(['git', '-C', repo, *args], capture_output=True)
    if check and res.returncode != 0:
        sys.exit(f"git {' '.join(args)} failed: {res.stderr.decode('utf-8', 'replace').strip()}")
    return res.stdout.decode('utf-8', 'replace') if res.returncode == 0 else ''


def github_info(remote_url):
    """Return (https URL, owner) for a GitHub remote, or ('', '') for anything else."""
    m = re.match(r'^(?:git@github\.com:|ssh://git@github\.com/|https://github\.com/)([^/]+)/(.+?)(?:\.git)?/?$', remote_url)
    return (f'https://github.com/{m.group(1)}/{m.group(2)}', m.group(1)) if m else ('', '')


def detect_ticket_prefixes(subjects):
    """Prefixes like PROJ in PROJ-1234 that show up often enough to be a real tracker key."""
    counts = collections.Counter()
    for s in subjects:
        counts.update(re.findall(r'\b([A-Z][A-Z0-9]{1,9})-\d{1,6}\b', s))
    threshold = max(25, int(len(subjects) * 0.005))
    return [p for p, n in counts.most_common() if n >= threshold]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('repo', help='path to a git repository (any folder inside it works)')
    ap.add_argument('-o', '--out', help='output HTML file (default: dist/<repo-name>.html)')
    ap.add_argument('--title', help='page title (default: "<repo-name> Commit Graph")')
    ap.add_argument('--jira', default='', help='Jira browse URL for ticket links, e.g. https://example.atlassian.net/browse/')
    ap.add_argument('--jira-prefixes', default='', help='comma-separated ticket prefixes that link to Jira, e.g. PROJ')
    ap.add_argument('--tickets', default=None, help='comma-separated ticket prefixes to highlight (default: auto-detect)')
    ap.add_argument('--release-tag', default=r'^v?\d+(\.\d+)+$',
                    help='regex for production release tags, used for "Shipped in" (default: plain version tags)')
    a = ap.parse_args()

    repo = git(os.path.abspath(os.path.expanduser(a.repo)), 'rev-parse', '--show-toplevel').strip()
    name = os.path.basename(repo)

    log = git(repo, 'log', '--branches', '--remotes', '--tags', '--date-order',
              '--format=%H%x1f%P%x1f%an%x1f%at%x1f%s')
    rows = [line.split(SEP) for line in log.split('\n') if line]
    if not rows:
        sys.exit(f'{repo} has no commits on any branch or tag')
    idx = {r[0]: i for i, r in enumerate(rows)}

    authors, author_idx, commits = [], {}, []
    for r in rows:
        h, parents, author, ts = r[0], r[1], r[2], int(r[3])
        subject = SEP.join(r[4:])
        if author not in author_idx:
            author_idx[author] = len(authors)
            authors.append(author)
        commits.append([h, [idx.get(p, -1) for p in parents.split()], author_idx[author], ts, subject])

    refs = []
    raw_refs = git(repo, 'for-each-ref', '--format=%(refname)%1f%(objectname)%1f%(*objectname)',
                   'refs/heads', 'refs/remotes', 'refs/tags')
    for line in raw_refs.split('\n'):
        parts = line.split(SEP)
        if len(parts) != 3 or parts[0].endswith('/HEAD'):
            continue
        refname, obj, peeled = parts
        target = idx.get(peeled or obj)
        if target is None:
            continue
        for prefix, kind in (('refs/heads/', 'local'), ('refs/remotes/', 'remote'), ('refs/tags/', 'tag')):
            if refname.startswith(prefix):
                refs.append([kind, refname[len(prefix):], target])
                break

    remote_url, owner = github_info(git(repo, 'remote', 'get-url', 'origin', check=False).strip())
    head_branch = git(repo, 'symbolic-ref', '--short', '-q', 'HEAD', check=False).strip()
    head_commit = idx.get(git(repo, 'rev-parse', 'HEAD', check=False).strip(), -1)
    tickets = ([t.strip() for t in a.tickets.split(',') if t.strip()] if a.tickets is not None
               else detect_ticket_prefixes([c[4] for c in commits]))

    data = {
        'repo': name, 'owner': owner, 'remote': remote_url,
        'jira': a.jira, 'jiraPrefixes': [p.strip() for p in a.jira_prefixes.split(',') if p.strip()],
        'tickets': tickets, 'releaseTag': a.release_tag,
        'head': head_branch, 'headCommit': head_commit, 'generated': int(time.time()),
        'authors': authors, 'commits': commits, 'refs': refs,
    }
    payload = json.dumps(data, separators=(',', ':'), ensure_ascii=False).replace('</', '<\\/')

    page = open(TEMPLATE, encoding='utf-8').read()
    for marker in ('/*__TITLE__*/', '/*__DATA__*/'):
        if page.count(marker) != 1:
            sys.exit(f'template must contain {marker} exactly once')
    page = page.replace('/*__TITLE__*/', html.escape(a.title or f'{name} Commit Graph'))
    page = page.replace('/*__DATA__*/', payload)

    out = a.out or os.path.join(ROOT, 'dist', f'{name}.html')
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, 'w', encoding='utf-8') as f:
        f.write(page)
    print(f'{out}: {len(commits):,} commits, {len(refs):,} refs, tickets {tickets or "none"}, {len(page) / 1e6:.1f} MB')


if __name__ == '__main__':
    main()
