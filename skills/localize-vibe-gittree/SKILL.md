---
name: localize-vibe-gittree
description: "Translate Vibe GitTree's interface into its 20 languages: write the code so its text is localizable, sync the String Catalog (GitTree/Localizable.xcstrings) with it, export what each language misses, have lighter-model subagents translate it, validate and import their work, check, build. Use whenever a change adds or changes text the app shows (a feature isn't done until every language has it), and when asked to add translations or a language, or to review or fix one."
---

# Localize Vibe GitTree

## Overview

Every string the app shows is in `GitTree/Localizable.xcstrings`, with English as the source and
20 translations: the most spoken languages macOS runs in (`LANGUAGES` in `scripts/localization.py`:
zh-Hans, hi, es, ar, fr, pt-BR, ru, id, de, ja, vi, tr, ko, zh-Hant, it, th, pl, uk, ms, nl). The
build compiles the catalog into the app; macOS picks the language (System Settings › General ›
Language & Region, also per app). `scripts/localization.py` does the bookkeeping; subagents on a
lighter model do the translating, with `translator-brief.md` (next to this file) as their brief and
`scripts/localization-glossary.json` keeping their words consistent from one feature to the next.

A change that adds or changes text the app shows ships with its translations, in the same commit:
`scripts/localization.py check` passes.

## Writing localizable code

- SwiftUI literals are localized as they are: `Text("…")`, `Button("…")`, `Label("…", systemImage:)`,
  `Toggle`, `Picker`, `Section`, `Menu`, `TextField` and its prompt, `.help("…")`,
  `.accessibilityLabel("…")`, `ContentUnavailableView`, `LabeledContent`, `.confirmationDialog`,
  `WindowGroup` titles, including a literal ternary (`Button(pinned ? "Unpin" : "Pin to Top")`).
  So is a literal passed to your own view's `LocalizedStringKey` parameter.
- Text that becomes a `String` first goes through `String(localized: "…")`: a model's progress or
  error message, an enum's `title`, a custom view's `title: String` given a literal, a tooltip or
  `help` built in code, `NSMenuItem`, `NSAlert`, `NSOpenPanel` prompts, table column titles. AppKit
  helpers can take a `String.LocalizationValue` parameter (literals passed to it are extracted)
  and call `String(localized:)` inside.
- Data stays as it is: branch and tag names, paths, commit messages, people, Jira statuses and
  summaries, git's own output. `Text(verbatim:)` for literal punctuation like `"·"`, and for
  strings made only of data.
- Whole sentences with interpolations, never English pieces glued together:
  `String(localized: "Released \(date)")`, not `"Released " + date`, and no `"\(a) " + verb`.
  Separators between independent phrases (`" · "`) are fine.
- Counts are `Int` interpolations, `"\(count) commits"` (not `count.formatted()`, which can't vary
  by plural); the number is grouped for the locale either way. Give the English singular with
  `scripts/localization.py plural "%lld commits" "%lld commit"` when the words change with the
  number. One count per string: a sentence with two counts puts one inside the other
  (`let commits = String(localized: "\(n) commits")`, then `"\(commits) on \(days) days"`).
- Numbers that aren't quantities (pull request numbers, years, line numbers, HTTP statuses) go in as
  `String(number)`; as an `Int` they'd be grouped, `#8,161`.
- A word used in two senses gets a key of its own with the English as its value:
  `String(localized: "Commit.button", defaultValue: "Commit", comment: "Button: commits the staged files")`.
  Add a `comment:` to anything a translator could read two ways (a lone word, a placeholder whose
  content isn't obvious). Translators also see the line of code that shows each string.
- Never change an enum's `rawValue` to translate it (they're saved, and some are debug launch
  arguments): add a `title`.
- `App/UpdateCheck.swift` is the same file in Vibe Notepad and Vibe Clean: its messages are put into
  words in `AppUpdater.swift` instead.
- Brand names, example URLs and placeholders that stay the same in every language: `scripts/localization.py dnt "<key>"`.

## Workflow

1. `scripts/localization.py sync` builds (Debug), adds the code's new strings to the catalog, drops
   the ones no longer used, and prints what each language misses and which strings with a number
   have only one English form.
2. English singulars for those whose words change (`plural`), `dnt` for names.
3. `scripts/localization.py export <folder>` (the session's scratchpad) writes `<language>.json`
   per language: each missing string with its English, comment, the code that shows it, and the
   language's glossary and plural categories.
4. Translate with subagents (Agent tool, `subagent_type: general-purpose`), never the main model:
   - A few strings (up to about 30 per language): one agent on `model: haiku` for all 20 languages,
     one output file per language.
   - More: one agent per language on `model: sonnet`, all launched in one message so they run at
     the same time.

   The prompt, per agent (adjust for one agent doing every language):

   > Translate Vibe GitTree's interface strings (a macOS git history app) into <language name>,
   > language code <code>.
   > 1. Read the brief first and follow it exactly: <repository>/skills/localize-vibe-gittree/translator-brief.md
   > 2. Input: <folder>/<code>.json (read it in chunks if it's long).
   > 3. Write your translations to <folder>/out/<code>.json (parts `.part1.json`, `.part2.json`…
   >    of about 225 strings when there are many), and your glossary to <folder>/out/<code>.glossary.json.
   > 4. From <repository> run `python3 scripts/localization.py import --dry-run <your files>`; fix
   >    what it reports and repeat until it reports no problems and nothing missing. Never run
   >    import without --dry-run, and change no other file: other translators work at the same time.
   >
   > Reply in under 120 words: the dry run's final line, then any strings whose meaning was unclear
   > or where you made a judgment call worth a second look (key and your choice).

5. When every agent is done: `scripts/localization.py import <folder>/out/*.part*.json` (or
   `<folder>/out/<code>.json`), then `scripts/localization.py glossary <folder>/out/*.glossary.json`.
   Read the judgment calls the agents reported and fix any that are wrong (edit their file, import it
   again).
6. `scripts/localization.py check` must pass. Build with the usual command, and look at the new UI in
   one or two languages: debug launch arguments take `-AppleLanguages "(de)"` (Arabic, `ar`, for
   right-to-left; German for long words). Commit the catalog, the glossary and the code together.

Adding a language: add it to `LANGUAGES` and `PLURALS` in `scripts/localization.py` and to
`knownRegions` in `GitTree.xcodeproj/project.pbxproj`, then export (it misses every string),
translate and import as above.

Fixing a translation found wrong: when the English could be read two ways, add a `comment:` in the
code and sync; then `scripts/localization.py review "<key>" --lang <codes>` marks those
translations to redo, and export lists them again (with the current one and the comment) for the
usual translate, import and check.

Reviewing a language: `export --all --lang <code>` lists every string with its current translation;
a reviewer agent corrects what's wrong and writes only those to its output file.
