#!/usr/bin/env python3
"""A tiny stand-in for Jira Cloud's REST API, for testing GitTree's ticket statuses without real
credentials. Every request is logged to stderr with the number of keys it asked for.

    python3 scripts/mock-jira.py 8899
    # then launch a Debug build with -GTJiraSite http://127.0.0.1:8899

Keys starting with PRO- (not PROJ-) are treated as unknown: bulk fetch leaves them out (reporting
them in issueErrors), and JQL search fails with 400 like real Jira. Pass --search-only to answer
bulk fetch with 404, to exercise GitTree's fallback to search.
"""
import json
import re
import sys
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATUSES = [
    ("To Do", "new"),
    ("In Progress", "indeterminate"),
    ("In Review", "indeterminate"),
    ("Done", "done"),
    ("Done", "done"),
]
requests = 0


class Handler(BaseHTTPRequestHandler):
    # Idle connections (URLSession opens some ahead of time) must not block other requests.
    timeout = 10

    def reply(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/rest/api/3/myself"):
            self.reply(200, {"displayName": "Mock Jira User", "emailAddress": "test@example.com"})
        else:
            self.reply(404, {"errorMessages": ["Not found"]})

    def do_POST(self):
        global requests
        requests += 1
        length = int(self.headers.get("Content-Length", 0))
        query = json.loads(self.rfile.read(length) or b"{}")
        bulk = self.path.startswith("/rest/api/3/issue/bulkfetch")
        if bulk and SEARCH_ONLY:
            print(f"request {requests}: bulk fetch refused (404)", file=sys.stderr, flush=True)
            self.reply(404, {"errorMessages": ["Not found"]})
            return
        keys = query.get("issueIdsOrKeys", []) if bulk else re.findall(r"[A-Z][A-Z0-9]+-\d+", query.get("jql", ""))
        kind = "bulk fetch" if bulk else "search"
        print(f"request {requests}: {kind}, {len(keys)} keys", file=sys.stderr, flush=True)
        missing = [key for key in keys if key.startswith("PRO-")]
        if missing and not bulk:
            self.reply(400, {"errorMessages": ["An issue with key 'PRO-…' does not exist for field 'key'."]})
            return
        issues = []
        for key in [key for key in keys if key not in missing]:
            name, category = STATUSES[zlib.crc32(key.encode()) % len(STATUSES)]
            issues.append({
                "key": key,
                "fields": {
                    "summary": f"Mock summary for {key}",
                    "status": {"name": name, "statusCategory": {"key": category}},
                    "issuetype": {"name": "Story"},
                    "assignee": {"displayName": "Mock Person"},
                    "fixVersions": [{"name": "2.12"}],
                },
            })
        errors = [{"issueIdOrKey": key, "errorMessages": ["Issue does not exist"]} for key in missing]
        self.reply(200, {"issues": issues, "issueErrors": errors} if bulk else {"issues": issues, "isLast": True})

    def log_message(self, *args):
        pass


SEARCH_ONLY = "--search-only" in sys.argv

if __name__ == "__main__":
    numbers = [arg for arg in sys.argv[1:] if arg.isdigit()]
    port = int(numbers[0]) if numbers else 8899
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
