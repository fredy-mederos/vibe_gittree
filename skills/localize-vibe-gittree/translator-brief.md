# Translating Vibe GitTree's strings

You translate the interface of Vibe GitTree, a native macOS app for exploring git history: a
commit graph with branches and tags, a commit's details and diffs, uncommitted changes and stashes
(staging, committing and stashing only when the user allows it), worktrees, GitHub pull requests
(read through the `gh` command) and Jira tickets, epics and fix versions. Its users are software
developers. The English is plain, short and precise; keep that tone.

## What you get and what you write

Your input is one JSON file (the path is in your task) for one language, from
`scripts/localization.py export`. It has:

- `language`, `languageName`: the language to write.
- `pluralCategories`, `optionalPluralCategories`, `numberMayBeLeftOutIn`: see Plurals below.
- `glossary`, `glossaryNotes`: terms already chosen for this language. Use them.
- `strings`: each with `key` (an id: copy it exactly, never translate it), `english` (the text
  to translate; an object of `one`/`other` forms when English varies by number), `comment` (what
  it is, when the code says), `canVaryByPlural`, `usedAt` (file, line and the line of Swift code
  that shows it, which tells you whether it's a button, a menu item, a tooltip (`.help`), a
  section title, a status line…) and, when there's one already, `current` (an earlier
  translation: keep it unless it's wrong). With `currentState: needs_review`, someone found it
  wrong, or the English changed: translate it again, with the comment in mind.

Write your translations as JSON with the Write tool, to the output path in your task:

```json
{"language": "de", "translations": {
  "Fetch": "Abrufen",
  "%lld commits": {"one": "%lld Commit", "other": "%lld Commits"},
  "Commit.button": "Committen"
}}
```

Every key of the input must be there, exactly as given. Long lists can go in several files
(`<path>.part1.json`, `<path>.part2.json`…), each a complete object like the one above. Then check
them with

```bash
python3 scripts/localization.py import --dry-run <your files>
```

which reads the catalog but changes nothing, and lists placeholder mistakes, plural problems and
the keys you haven't translated yet. Fix everything it reports and run it again until it reports
no problems and nothing missing. Don't run `import` without `--dry-run`, and don't edit any other
file: other translators work at the same time.

## Placeholders

`%@` (text), `%lld` (a number) and their numbered forms (`%1$@`, `%2$lld`) are filled in by the
app. Keep every one of them, as many times as the English has it. To change their order, number
them (`%2$@ … %1$@`). The comment and the code in `usedAt` show what fills them: a branch name, a
date, a count, a person, a path. Don't add or remove spaces the language doesn't need around them.

Keep as they are: `Vibe GitTree`, `GitHub`, `GitLab`, `Bitbucket`, `Jira`, `git`, `gh`, `HEAD`,
`Apple Intelligence`, `macOS`, `Xcode`, `stash@{0}`, `gittree://…` links, ticket keys and project
examples (`ABC-123`, `PROJ`), `{key}`, regular expression examples (`Android`, `^iOS`), commands
inside backticks (`` `gh auth login` ``, `` `brew install gh` ``; the backticks stay too),
keyboard shortcuts (⌘G, ⇧⌘G, ⌥⌘↑, ⌘Return) and the `›` between menu or settings names.

## Plurals

A string with `canVaryByPlural: true` has exactly one number. When the words around the number
change with it in your language, give an object with your language's `pluralCategories` (all of
them, except that `optionalPluralCategories` may be left out). When nothing changes, a plain
string is fine. Each form keeps all the placeholders, the number too, except in the categories
listed in `numberMayBeLeftOutIn` (only those stand for a single number; in Russian "one" also
means 21, in French 0). `other` is also what fractions use. Strings without `canVaryByPlural`
must be plain strings.

## Style

- Write what macOS itself and Apple's apps say in your language for the usual things: Cancel,
  OK, Done, Settings, Show in Finder, Open in Terminal, Copy, Remove…, Window, Find Next. Use the
  names macOS gives Finder, Terminal, System Settings and Apple Intelligence in your language.
- Git and GitHub terms: the words developers in your language actually use, as in git's own
  translation for your language where it has one, or the English term where that's what people
  say (many languages keep "commit", "branch" or "pull request"). One word per concept,
  everywhere: commit, branch, tag, remote, merge, rebase, cherry-pick, fetch, clone, stash, apply,
  pop, drop, stage/unstage, staged, worktree, diff, hash, upstream, ahead/behind, detached HEAD,
  pull request, draft, review, checks, stack (pull requests based on each other).
- Jira terms: ticket, epic, story, task, sub-task, fix version, release, status, To Do,
  In Progress, Done, Definition of Done. Use what Jira itself shows in your language when it has
  a translation.
- A string that names another part of the app ("Settings › General › Allow commits and stashes",
  "Repository › Compare Branches…", "Uncommitted Changes", "Group Recent Commits") uses exactly
  your translation of that part: find its own string in the list.
- Capitalization: English uses Title Case for buttons, menus and titles. Use your language's own
  rule (most capitalize only the first word).
- `…` (one character) stays where English has it: a menu item or button that opens a dialog, or
  something under way ("Loading…").
- Quotation marks around names (“main”): your language's own (« » French, „ “ German, 「」 Japanese).
- Short labels stay short: sidebar rows, toolbar buttons, column titles, segmented controls and
  status lines have little room. Tooltips and explanations can be full sentences.
- The compact ages `%lldm`, `%lldh`, `%lldd`, `%lldmo` and `%@y` (5m, 3h, 12d, 4mo, 2.5y) sit
  in narrow columns: use the shortest abbreviations your language uses for minutes, hours, days,
  months and years.
- Keys like `Commit.button`, `Stash.button` or `pulls.open` are ids for a word used in one
  particular sense: translate their `english` text with the comment in mind (a verb on a button,
  a group of open pull requests).
- Address the user the way Apple's software does in your language (formal or informal), the same
  way everywhere.

## Your glossary

Also write, next to your translations, `<language>.glossary.json`:

```json
{"language": "de", "notes": "Sie-form; git terms stay English nouns with German articles (der Commit, der Branch).",
 "terms": {"commit (noun)": "Commit", "commit (verb)": "committen", "branch": "Branch", "...": "..."}}
```

with the words you chose for: repository, commit (noun), commit (verb), branch, remote branch,
tag, remote, merge (noun), merge (verb), rebase, cherry-pick, fetch, clone, stash (noun), stash
(verb), apply, pop, drop, stage, unstage, staged, uncommitted changes, worktree, diff, hash,
author, committer, upstream, ahead, behind, detached, pull request, draft, review, checks, stack,
ticket, epic, story, task, sub-task, fix version, release, release tag, Definition of Done, To Do,
In Progress, Done, highlight, sidebar, details, graph, activity, feature, term, profile, API token,
Settings, General. Later translations of new strings use it, so the app stays consistent.
