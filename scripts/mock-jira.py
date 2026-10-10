#!/usr/bin/env python3
"""A tiny stand-in for Jira Cloud's REST API, for testing GitTree's ticket statuses, epics and fix
versions without real credentials. Every request is logged to stderr with what it asked for.

    python3 scripts/mock-jira.py 8899
    # then launch a Debug build with -GTJiraSite http://127.0.0.1:8899

Every ticket gets a made-up status, type and fix version. Most belong to one of four mock epics
(PROJ-90001…90004); a quarter are sub-tasks of mock tasks (PROJ-80000…80004), whose parents are
the epics, like in a real project. Every project it has answered tickets for lists six unreleased
fix versions, Android and iOS ones, each with two extra tickets that no commit mentions; other
projects get 404 (--projects=A,B names the projects instead).

Keys starting with PRO- (a near miss of PROJ-; --unknown=PREFIX picks another) are treated as
unknown: bulk fetch leaves them out (reporting them in issueErrors), and JQL search fails with 400
like real Jira. Pass --search-only to answer bulk fetch with 404, to exercise GitTree's fallback to
search, and --no-parent-epic to reject `parentEpic` queries, to exercise its fallback to `parent`.
"""
import json
import re
import sys
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATUSES = [
    ("To Do", "new"),
    ("In Progress", "indeterminate"),
    ("In Review", "indeterminate"),
    ("Done", "done"),
    ("Released", "done"),
]
EPICS = {
    "PROJ-90001": ("[Search] Faster search", ("In Progress", "indeterminate")),
    "PROJ-90002": ("[Checkout] One-page checkout", ("To Do", "new")),
    "PROJ-90003": ("[Onboarding] Sign-up flow", ("Done", "done")),
    "PROJ-90004": ("[Tech Debt] UI tests for every screen", ("In Progress", "indeterminate")),
}
EPIC_KEYS = sorted(EPICS)
# Tasks that sub-tasks belong to; each one is in an epic.
TASKS = {f"PROJ-8000{i}": EPIC_KEYS[i % len(EPIC_KEYS)] for i in range(5)}
# Unreleased fix versions: id, name, release date.
VERSIONS = [
    ("10001", "Android 2.12", "2026-10-13"),
    ("10002", "iOS 2.12", "2026-10-13"),
    ("10005", "Payments (Android)", "2026-10-22"),
    ("10003", "Android 2.13", "2026-10-28"),
    ("10004", "iOS 2.13", "2026-10-28"),
    ("10006", "Android bug fixes", None),
]
# What tickets with commits get: mostly Android versions, some already released.
TICKET_VERSIONS = ["Android 2.11", "Android 2.12", "Android 2.13", "Payments (Android)",
                   "Android 2.10", "Android 2.11", "Android 2.12"]
UNRELEASED = {name for _, name, _ in VERSIONS}
seen = set()
requests = 0


def crc(key):
    return zlib.crc32(key.encode())


def status_of(key):
    if key in EPICS:
        return EPICS[key][1]
    return STATUSES[crc(key) % len(STATUSES)]


def version_of(key):
    """The fix version of a ticket; each version also has two tickets no commit mentions."""
    for version_id, name, _ in VERSIONS:
        if key in extra_tickets(version_id):
            return name
    return TICKET_VERSIONS[crc(key) % len(TICKET_VERSIONS)]


def extra_tickets(version_id):
    return [f"PROJ-99{version_id[-1]}01", f"PROJ-99{version_id[-1]}02"]


def kind_of(key):
    """(type name, hierarchy level, parent key) for a ticket."""
    if key in EPICS:
        return "Epic", 1, None
    if key in TASKS:
        return "Task", 0, TASKS[key]
    h = crc(key)
    if h % 6 == 0:
        return ("Bug", 0, None) if h % 2 else ("Story", 0, None)
    if h % 4 == 0:
        return "Sub-task", -1, f"PROJ-8000{h % 5}"
    return ["Story", "Task", "Bug"][h % 3], 0, EPIC_KEYS[h % len(EPIC_KEYS)]


def summary_of(key):
    if key in EPICS:
        return EPICS[key][0]
    if key in TASKS:
        return f"[Android] Mock task {key}"
    return f"Mock summary for {key}"


def issuetype(name, level):
    return {"name": name, "subtask": level < 0, "hierarchyLevel": level}


def status_json(key):
    name, category = status_of(key)
    return {"name": name, "statusCategory": {"key": category}}


def issue_json(key):
    name, level, parent = kind_of(key)
    fields = {
        "summary": summary_of(key),
        "status": status_json(key),
        "issuetype": issuetype(name, level),
        "assignee": {"displayName": "Mock Person"},
        "fixVersions": [] if level == 1 else [{"name": version_of(key), "released": version_of(key) not in UNRELEASED}],
    }
    if parent:
        parent_name, parent_level, _ = kind_of(parent)
        fields["parent"] = {
            "key": parent,
            "fields": {"summary": summary_of(parent), "status": status_json(parent), "issuetype": issuetype(parent_name, parent_level)},
        }
    return {"key": key, "fields": fields}


def epic_of(key):
    _, level, parent = kind_of(key)
    if level == 1:
        return key
    if parent in TASKS:
        return TASKS[parent]
    return parent


def known_keys():
    return seen | set(TASKS) | set(EPICS)


def tickets_in(name):
    """Tickets in a fix version: epics aren't in fix versions, their tickets are."""
    return sorted(key for key in known_keys() if key not in EPICS and version_of(key) == name)


def is_project(key):
    """Projects named on the command line, or else every project it has answered tickets for."""
    if PROJECTS:
        return key in PROJECTS
    return any(ticket.rsplit("-", 1)[0] == key for ticket in seen)


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
        global requests
        if self.path.startswith("/rest/api/3/myself"):
            self.reply(200, {"displayName": "Mock Jira User", "emailAddress": "test@example.com"})
            return
        project = re.match(r"/rest/api/3/project/([A-Z][A-Z0-9]*)/version", self.path)
        if project:
            requests += 1
            if not is_project(project.group(1)):
                log(f"request {requests}: versions of {project.group(1)}, not a project (404)")
                self.reply(404, {"errorMessages": [f"No project could be found with key '{project.group(1)}'."]})
                return
            log(f"request {requests}: versions of {project.group(1)} ({self.path.split('?', 1)[-1]})")
            values = []
            for version_id, name, date in VERSIONS:
                keys = tickets_in(name) + extra_tickets(version_id)
                counts = {"toDo": 0, "inProgress": 0, "done": 0, "unmapped": 0}
                for key in keys:
                    category = status_of(key)[1]
                    counts[{"new": "toDo", "indeterminate": "inProgress", "done": "done"}[category]] += 1
                values.append({
                    "id": version_id, "name": name, "description": f"Mock release {name}", "archived": False,
                    "released": False, "releaseDate": date, "overdue": bool(date and date < time.strftime("%Y-%m-%d")),
                    "issuesStatusForFixVersion": counts,
                })
            self.reply(200, {"values": values, "isLast": True, "startAt": 0, "maxResults": 100, "total": len(values)})
            return
        self.reply(404, {"errorMessages": ["Not found"]})

    def do_POST(self):
        global requests
        requests += 1
        length = int(self.headers.get("Content-Length", 0))
        query = json.loads(self.rfile.read(length) or b"{}")
        bulk = self.path.startswith("/rest/api/3/issue/bulkfetch")
        if bulk and SEARCH_ONLY:
            log(f"request {requests}: bulk fetch refused (404)")
            self.reply(404, {"errorMessages": ["Not found"]})
            return
        jql = query.get("jql", "")
        keys = self.list_for(jql)
        if keys is None:
            return
        if keys == "search":
            keys = query.get("issueIdsOrKeys", []) if bulk else re.findall(r"[A-Z][A-Z0-9]+-\d+", jql)
            seen.update(key for key in keys if not key.startswith(UNKNOWN))
            log(f"request {requests}: {'bulk fetch' if bulk else 'search'}, {len(keys)} keys")
        missing = [key for key in keys if key.startswith(UNKNOWN)]
        if missing and not bulk:
            self.reply(400, {"errorMessages": [f"An issue with key '{missing[0]}' does not exist for field 'key'."]})
            return
        issues = [issue_json(key) for key in keys if key not in missing]
        errors = [{"issueIdOrKey": key, "errorMessages": ["Issue does not exist"]} for key in missing]
        self.reply(200, {"issues": issues, "issueErrors": errors} if bulk else {"issues": issues, "isLast": True})

    def list_for(self, jql):
        """The tickets a list query asks for, "search" for plain key searches, None when answered with an error."""
        version = re.search(r'fixVersion = (?:"([^"]+)"|(\d+))', jql)
        if version:
            name = version.group(1) or next((n for i, n, _ in VERSIONS if i == version.group(2)), version.group(2))
            version_id = next((i for i, n, _ in VERSIONS if n == name), None)
            keys = tickets_in(name) + (extra_tickets(version_id) if version_id else [])
            log(f"request {requests}: fixVersion {name}, {len(keys)} tickets")
            return keys
        epic = re.search(r"parentEpic = ([A-Z][A-Z0-9]*-\d+)", jql)
        if epic:
            if NO_PARENT_EPIC:
                log(f"request {requests}: parentEpic {epic.group(1)} refused (400)")
                self.reply(400, {"errorMessages": ["Field 'parentEpic' does not exist."]})
                return None
            keys = sorted(key for key in known_keys() if epic_of(key) == epic.group(1))
            log(f"request {requests}: parentEpic {epic.group(1)}, {len(keys)} tickets")
            return keys
        parents = re.search(r"parent in \(([^)]*)\)", jql)
        if parents:
            wanted = {key.strip() for key in parents.group(1).split(",")}
            keys = sorted(key for key in known_keys() if kind_of(key)[2] in wanted)
            log(f"request {requests}: parent in {len(wanted)} tickets, {len(keys)} tickets")
            return keys
        return "search"

    def log_message(self, *args):
        pass


def option(name, default):
    """The value of --name=value, or the default."""
    return next((arg.split("=", 1)[1] for arg in sys.argv if arg.startswith(f"--{name}=")), default)


SEARCH_ONLY = "--search-only" in sys.argv
NO_PARENT_EPIC = "--no-parent-epic" in sys.argv
PROJECTS = [key for key in option("projects", "").split(",") if key]
UNKNOWN = option("unknown", "PRO") + "-"


def log(message):
    """Every request on stderr with the time, so pacing is easy to check."""
    print(f"{time.strftime('%H:%M:%S')} {message}", file=sys.stderr, flush=True)

if __name__ == "__main__":
    numbers = [arg for arg in sys.argv[1:] if arg.isdigit()]
    port = int(numbers[0]) if numbers else 8899
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
