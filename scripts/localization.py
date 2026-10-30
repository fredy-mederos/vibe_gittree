#!/usr/bin/env python3
"""Vibe GitTree's translations, kept in the String Catalog GitTree/Localizable.xcstrings.

    scripts/localization.py sync               build, add the code's new strings to the catalog, drop unused ones
    scripts/localization.py status             what each language still needs
    scripts/localization.py plural KEY ONE     English singular for a string with a count ("%lld commits" → "%lld commit")
    scripts/localization.py dnt KEY…           strings that stay the same in every language (names, examples)
    scripts/localization.py review KEY         marks a string's translations to redo (--lang some of them), for export
    scripts/localization.py export FOLDER      FOLDER/<language>.json with what each language still needs
    scripts/localization.py import FILE…       merge translated files into the catalog, checking every string
                                               (--dry-run only checks them: what a translator runs)
    scripts/localization.py check              fails when a language misses a string or a translation is broken
    scripts/localization.py glossary FILE…     add translators' <language>.glossary.json files to the shared glossary,
                                               keeping what it has (--replace revises it; --dry-run changes nothing)

export, status and check take --lang de,fr to look at some languages only; export --all lists every
string (to review translations), with the current one. The workflow is in
skills/localize-vibe-gittree/SKILL.md: sync, export, translate each file, import, check, build.

An exported file lists, per string: the English text (one/other forms when it has a count), the
translator's comment from the code, where it's used (file, line and the line of code), and the
current translation. A translated file is

    {"language": "de", "translations": {"Fetch": "Abrufen", "%lld commits": {"one": "%lld Commit", "other": "%lld Commits"}}}

Every translation keeps the English text's placeholders (%@, %lld; %1$@, %2$@ to reorder them). A
string with exactly one number can vary by plural, with the language's categories (PLURALS below).
"""
import argparse
import glob
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "GitTree" / "Localizable.xcstrings"
PROJECT = ROOT / "GitTree.xcodeproj" / "project.pbxproj"
GLOSSARY = Path(__file__).resolve().parent / "localization-glossary.json"
DERIVED_DATA = ROOT / "build" / "DerivedData"
STRINGS_DATA = DERIVED_DATA / "Build/Intermediates.noindex/GitTree.build/Debug/GitTree.build/Objects-normal"

# The 20 most spoken languages macOS itself runs in, most speakers first. Adding one: here, in
# knownRegions in the Xcode project, then export, translate and import it.
LANGUAGES = {
    "zh-Hans": "Chinese (Simplified)",
    "hi": "Hindi",
    "es": "Spanish",
    "ar": "Arabic",
    "fr": "French",
    "pt-BR": "Portuguese (Brazil)",
    "ru": "Russian",
    "id": "Indonesian",
    "de": "German",
    "ja": "Japanese",
    "vi": "Vietnamese",
    "tr": "Turkish",
    "ko": "Korean",
    "zh-Hant": "Chinese (Traditional)",
    "it": "Italian",
    "th": "Thai",
    "pl": "Polish",
    "uk": "Ukrainian",
    "ms": "Malay",
    "nl": "Dutch",
}

# CLDR's plural categories for whole numbers. "other" is also what fractions and missing categories use.
PLURALS = {
    "en": ["one", "other"],
    "zh-Hans": ["other"], "zh-Hant": ["other"], "ja": ["other"], "ko": ["other"], "vi": ["other"],
    "th": ["other"], "id": ["other"], "ms": ["other"],
    "hi": ["one", "other"], "de": ["one", "other"], "nl": ["one", "other"], "tr": ["one", "other"],
    "es": ["one", "many", "other"], "fr": ["one", "many", "other"], "it": ["one", "many", "other"],
    "pt-BR": ["one", "many", "other"],
    "ru": ["one", "few", "many", "other"], "uk": ["one", "few", "many", "other"], "pl": ["one", "few", "many", "other"],
    "ar": ["zero", "one", "two", "few", "many", "other"],
}
# "many" is only exact millions (1 000 000 commits) in these; without it they take "other".
OPTIONAL_PLURALS = {"es": {"many"}, "fr": {"many"}, "it": {"many"}, "pt-BR": {"many"}}
# Categories that stand for a single number, whose form may leave the number out ("New commit").
# Elsewhere "one" also means 21 (Russian) or 0 (French), so the number stays.
EXACT_PLURALS = {"en": {"one"}, "de": {"one"}, "nl": {"one"}, "es": {"one"}, "it": {"one"}, "tr": {"one"},
                 "pl": {"one"}, "ar": {"zero", "one", "two"}}

PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?(lld|llu|ld|lu|lf|d|i|u|f|@)|%%")
NUMBER_TYPES = {"lld", "llu", "ld", "lu", "d", "i", "u"}


# MARK: The catalog

def load():
    return json.loads(CATALOG.read_text(encoding="utf-8"))


def save(catalog):
    """Written the way Xcode writes it, so opening the catalog in Xcode changes nothing."""
    text = json.dumps(catalog, indent=2, ensure_ascii=False, separators=(",", " : "), sort_keys=True)
    # Xcode writes an empty object as an opening brace, an empty line and the closing brace.
    text = re.sub(r"^(\s*)(.*)\{\}", lambda m: f"{m.group(1)}{m.group(2)}{{\n\n{m.group(1)}}}", text, flags=re.M)
    CATALOG.write_text(text, encoding="utf-8")


def translatable(catalog):
    """The strings to translate: not marked as staying the same, and still used."""
    return {key: entry for key, entry in catalog["strings"].items()
            if entry.get("shouldTranslate", True) and entry.get("extractionState") != "stale"}


def english(key, entry):
    """The English text: the key, or the value the code gives an explicit key, or its plural forms."""
    unit = entry.get("localizations", {}).get("en", {})
    if "variations" in unit:
        return {category: form["stringUnit"]["value"] for category, form in unit["variations"]["plural"].items()}
    if "stringUnit" in unit:
        return unit["stringUnit"]["value"]
    return key


def english_other(key, entry):
    text = english(key, entry)
    return text["other"] if isinstance(text, dict) else text


def translation(entry, language):
    """A language's translation (text or plural forms) and its state, or (None, None)."""
    unit = entry.get("localizations", {}).get(language)
    if not unit:
        return None, None
    if "variations" in unit:
        forms = unit["variations"].get("plural", {})
        states = {form["stringUnit"]["state"] for form in forms.values()}
        state = "translated" if states == {"translated"} else "needs_review"
        return {category: form["stringUnit"]["value"] for category, form in forms.items()}, state
    unit = unit.get("stringUnit", {})
    return unit.get("value"), unit.get("state")


def missing(entries, language):
    return [key for key, entry in entries.items() if translation(entry, language)[1] != "translated"]


# MARK: Checking

def placeholders(text):
    """{position: type} for the format specifiers in text, and whether they're numbered (%1$@)."""
    found = {}
    numbered = set()
    following = 0
    for match in PLACEHOLDER.finditer(text):
        if match.group(0) == "%%":
            continue
        kind = "d" if match.group(2) == "i" else match.group(2)
        if match.group(1):
            position = int(match.group(1))
            numbered.add(True)
        else:
            following += 1
            position = following
            numbered.add(False)
        if found.get(position, kind) != kind:
            return None, f"argument {position} is used as two types"
        found[position] = kind
    if len(numbered) > 1:
        return None, "mixes numbered (%1$@) and plain (%@) placeholders"
    return found, None


def counted_argument(key, entry):
    """The position of a string's only number, when it has exactly one: what plural forms vary by."""
    found, _ = placeholders(english_other(key, entry))
    numbers = [position for position, kind in (found or {}).items() if kind in NUMBER_TYPES]
    return numbers[0] if len(numbers) == 1 else None


def problems(key, entry, language, value):
    """What's wrong with a translation, as sentences; empty when it's fine."""
    source, error = placeholders(english_other(key, entry))
    if error:
        return [f"the English text {error}"]
    result = []

    def compare(text, label, may_omit=None):
        if not isinstance(text, str) or not text.strip():
            result.append(f"{label}is empty")
            return
        found, error = placeholders(text)
        if error:
            result.append(f"{label}{error}")
            return
        expected = dict(source)
        if may_omit is not None and may_omit not in found:
            expected.pop(may_omit, None)
        if found != expected:
            want = " ".join(f"%{p}${t}" for p, t in sorted(expected.items())) or "none"
            have = " ".join(f"%{p}${t}" for p, t in sorted(found.items())) or "none"
            result.append(f"{label}has placeholders {have}, expected {want}")
        if "%#@" in text:
            result.append(f"{label}uses %#@…@ substitutions; give plural forms instead")
        if text.count("`") != english_other(key, entry).count("`"):
            result.append(f"{label}doesn't keep the English text's `code` marks")

    if isinstance(value, dict):
        counted = counted_argument(key, entry)
        if counted is None:
            return ["has plural forms, but only strings with exactly one number can vary by plural"]
        allowed = set(PLURALS[language])
        required = allowed - OPTIONAL_PLURALS.get(language, set())
        if set(value) - allowed:
            result.append(f"has categories {', '.join(sorted(set(value) - allowed))}; {language} uses {', '.join(PLURALS[language])}")
        if required - set(value):
            result.append(f"misses plural categories {', '.join(sorted(required - set(value)))}")
        for category, text in value.items():
            exact = category in EXACT_PLURALS.get(language, set())
            compare(text, f"its {category} form ", may_omit=counted if exact else None)
    else:
        compare(value, "")
    return result


# MARK: Commands

def sync(arguments):
    if not arguments.no_build:
        print("Building (Debug) to extract the strings…")
        build = subprocess.run(["xcodebuild", "-project", str(PROJECT.parent), "-scheme", "GitTree", "-configuration", "Debug",
                                "-derivedDataPath", str(DERIVED_DATA), "build"], cwd=ROOT, capture_output=True, text=True)
        if build.returncode != 0:
            print("\n".join(line for line in build.stdout.splitlines() if "error:" in line) or build.stdout[-3000:])
            sys.exit("The build failed; fix it and sync again.")
    sources = {path.stem for path in (ROOT / "GitTree").rglob("*.swift")}
    # Only files whose source is still there: a deleted file's strings are gone too.
    data = [path for path in glob.glob(str(STRINGS_DATA / "*" / "*.stringsdata")) if Path(path).stem in sources]
    if not data:
        sys.exit(f"No .stringsdata in {STRINGS_DATA}; build first (or drop --no-build).")
    before = set(load()["strings"])
    subprocess.run(["xcrun", "xcstringstool", "sync", str(CATALOG), "--stringsdata", *data], check=True)
    catalog = load()
    stale = sorted(key for key, entry in catalog["strings"].items() if entry.get("extractionState") == "stale")
    for key in stale:
        del catalog["strings"][key]
    save(catalog)
    added = sorted(set(catalog["strings"]) - before)
    print(f"{len(catalog['strings'])} strings: {len(added)} new, {len(stale)} no longer used (removed).")
    for key in added:
        print(f"  + {key}")
    for key in stale:
        print(f"  - {key}")
    status(arguments)


def status(arguments):
    catalog = load()
    entries = translatable(catalog)
    print(f"{len(entries)} strings to translate ({len(catalog['strings']) - len(entries)} stay the same in every language).")
    for language in selected(arguments):
        keys = missing(entries, language)
        line = f"  {language:8} {LANGUAGES[language]:22} " + ("complete" if not keys else f"{len(keys)} to translate")
        print(line + (": " + ", ".join(repr(key) for key in keys[:3]) + ("…" if len(keys) > 3 else "") if keys else ""))
    english_plurals(entries)


def english_plurals(entries):
    """Strings with one number but no English singular: fine when the words don't change ("Latest %lld")."""
    keys = [key for key, entry in entries.items()
            if counted_argument(key, entry) is not None and not isinstance(english(key, entry), dict)]
    if keys:
        print(f"Strings with a number and one English form ({len(keys)}); give a singular with "
              f"`plural KEY ONE` when the words change with the number:")
        for key in sorted(keys):
            print(f"  {key}")


def plural(arguments):
    catalog = load()
    entry = catalog["strings"].get(arguments.key)
    if entry is None:
        sys.exit(f"No string {arguments.key!r} in the catalog; sync first.")
    if counted_argument(arguments.key, entry) is None:
        sys.exit("Only strings with exactly one number have plural forms.")
    other = english_other(arguments.key, entry)
    one = arguments.one
    if "$" in other and "$" not in one:
        # Numbered like the plural form Xcode wrote: %@ has %lld → %1$@ has %2$lld.
        numbers = iter(range(1, 100))
        one = PLACEHOLDER.sub(lambda m: m.group(0) if m.group(0) == "%%" else f"%{next(numbers)}${m.group(2)}", one)
    trouble = problems(arguments.key, entry, "en", {"one": one, "other": other})
    if trouble:
        sys.exit("; ".join(trouble))
    entry.setdefault("localizations", {})["en"] = {"variations": {"plural": {
        "one": {"stringUnit": {"state": "translated", "value": one}},
        "other": {"stringUnit": {"state": "translated", "value": other}},
    }}}
    save(catalog)
    print(f"{arguments.key}: one {one!r}, other {other!r}")


def dnt(arguments):
    catalog = load()
    for key in arguments.keys:
        if key not in catalog["strings"]:
            sys.exit(f"No string {key!r} in the catalog.")
        catalog["strings"][key]["shouldTranslate"] = False
    save(catalog)


def review(arguments):
    """Translations found wrong, or whose English changed meaning: export lists them again, with
    the current translation, and the next import replaces them."""
    catalog = load()
    entry = catalog["strings"].get(arguments.key)
    if entry is None:
        sys.exit(f"No string {arguments.key!r} in the catalog.")
    for language in selected(arguments):
        unit = entry.get("localizations", {}).get(language, {})
        for form in unit.get("variations", {}).get("plural", {}).values():
            form["stringUnit"]["state"] = "needs_review"
        if "stringUnit" in unit:
            unit["stringUnit"]["state"] = "needs_review"
    save(catalog)


def locations():
    """Where each string is used: (file, line, the line of code), from the last build's .stringsdata."""
    found = {}
    for path in glob.glob(str(STRINGS_DATA / "*" / "*.stringsdata")):
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        source = Path(data.get("source", ""))
        lines = source.read_text(encoding="utf-8").splitlines() if source.exists() else []
        for entries in data.get("tables", {}).values():
            for item in entries:
                line = item.get("location", {}).get("startingLine", 0)
                code = lines[line - 1].strip() if 0 < line <= len(lines) else ""
                where = f"{source.name}:{line}  {code[:220]}"
                if where not in found.setdefault(item["key"], []):
                    found[item["key"]].append(where)
    return found


def export(arguments):
    catalog = load()
    entries = translatable(catalog)
    where = locations()
    glossary = json.loads(GLOSSARY.read_text(encoding="utf-8")) if GLOSSARY.exists() else {}
    folder = Path(arguments.folder)
    folder.mkdir(parents=True, exist_ok=True)
    for language in selected(arguments):
        keys = sorted(entries) if arguments.all else sorted(missing(entries, language))
        if not keys:
            continue
        strings = []
        for key in keys:
            entry = entries[key]
            current, state = translation(entry, language)
            item = {"key": key, "english": english(key, entry)}
            if entry.get("comment"):
                item["comment"] = entry["comment"]
            item["canVaryByPlural"] = counted_argument(key, entry) is not None
            item["usedAt"] = where.get(key, [])[:4]
            if current is not None:
                item["current"] = current
                item["currentState"] = state
            strings.append(item)
        terms = {term: values[language] for term, values in glossary.get("terms", {}).items() if language in values}
        notes = glossary.get("notes", {}).get(language)
        document = {
            "language": language,
            "languageName": LANGUAGES[language],
            "pluralCategories": PLURALS[language],
            "optionalPluralCategories": sorted(OPTIONAL_PLURALS.get(language, set())),
            "numberMayBeLeftOutIn": sorted(EXACT_PLURALS.get(language, set())),
            "glossary": terms,
            "glossaryNotes": notes or "",
            "strings": strings,
        }
        path = folder / f"{language}.json"
        path.write_text(json.dumps(document, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"{path}: {len(strings)} strings")


def import_(arguments):
    catalog = load()
    entries = translatable(catalog)
    trouble = 0
    languages = set()
    for path in arguments.files:
        document = json.loads(Path(path).read_text(encoding="utf-8"))
        language = document.get("language")
        if language not in LANGUAGES:
            sys.exit(f"{path}: unknown language {language!r}")
        languages.add(language)
        imported = 0
        for key, value in document.get("translations", {}).items():
            if key not in entries:
                print(f"{path}: {key!r} isn't a string to translate (sync, or a typo?)")
                trouble += 1
                continue
            # Forms that are all the same, for a string that can't vary by plural, are one translation.
            if isinstance(value, dict) and len(set(value.values())) == 1 and counted_argument(key, entries[key]) is None:
                value = next(iter(value.values()))
            found = problems(key, entries[key], language, value)
            if found:
                print(f"{path}: {key!r}: " + "; ".join(found))
                trouble += 1
                continue
            unit = ({"variations": {"plural": {category: {"stringUnit": {"state": "translated", "value": text}}
                                               for category, text in value.items()}}}
                    if isinstance(value, dict) else {"stringUnit": {"state": "translated", "value": value}})
            entries[key].setdefault("localizations", {})[language] = unit
            imported += 1
        print(f"{path}: {imported} {LANGUAGES[language]} strings " + ("fine" if arguments.dry_run else "imported"))
    if not arguments.dry_run:
        save(catalog)
    for language in sorted(languages):
        keys = missing(entries, language)
        if keys:
            print(f"{LANGUAGES[language]} still misses {len(keys)} strings: " + ", ".join(repr(key) for key in keys[:20])
                  + (" …" if len(keys) > 20 else ""))
    if trouble:
        sys.exit(f"{trouble} strings have problems; fix them and run import again.")


def glossary(arguments):
    """Each language's words for the app's terms, and notes on its style, which export hands the next
    translator. A file adds terms, and languages a term doesn't have yet. The words and notes the
    glossary has stay as they are, since a translator's copy of them tends to lose details (which word
    on a button, which for a Jira status). To revise them on purpose, --replace takes the file's words
    and adds what its notes say that the glossary's don't; rewording the notes is done by hand."""
    shared = json.loads(GLOSSARY.read_text(encoding="utf-8")) if GLOSSARY.exists() else {}
    terms = shared.setdefault("terms", {})
    notes = shared.setdefault("notes", {})
    before = json.dumps(shared, sort_keys=True)
    existing = set(terms)
    documents = []
    for path in arguments.files:
        document = json.loads(Path(path).read_text(encoding="utf-8"))
        if document.get("language") not in LANGUAGES:
            sys.exit(f"{path}: unknown language {document.get('language')!r}")
        if not isinstance(document.get("terms") or {}, dict) or not isinstance(document.get("notes") or "", str):
            sys.exit(f"{path}: terms should be an object of words, and notes a text")
        documents.append((path, document))
    kept = False
    for path, document in documents:
        language = document["language"]
        lines = []
        counts = {"the same": 0, "added": 0, "replaced": 0, "kept": 0}
        text, ours = (document.get("notes") or "").strip(), notes.get(language, "")
        new = unlike(text, ours)
        if new and not ours:
            lines.append(f"  + notes: {preview(text)!r}")
            notes[language] = text
        elif new and arguments.replace:
            lines.append(f"  added to the notes: {preview(new)!r}")
            notes[language] = f"{ours} {new}"
        elif text and normalized(text) != normalized(ours):
            lines.append("  kept the notes; " + (f"only the file's say: {preview(new)!r}" if new
                                                 else "the file's only leave parts of them out"))
            kept = True
        for term, given in (document.get("terms") or {}).items():
            value = given.strip() if isinstance(given, str) else ""
            current = terms.get(term, {}).get(language)
            if not value:
                lines.append(f"  skipped {term!r}: {given!r} isn't a word")
            elif value == current:
                counts["the same"] += 1
            elif current is None:
                lines.append(f"  + {term!r}: {value!r}" + ("" if term in existing else " (new term)"))
                terms.setdefault(term, {})[language] = value
                counts["added"] += 1
            elif arguments.replace:
                lines.append(f"  replaced {term!r}: {current!r} with {value!r}")
                terms[term][language] = value
                counts["replaced"] += 1
            else:
                shorter = len(value) < len(current) and normalized(value) in normalized(current)
                how = "shortens it to" if shorter else "has"
                lines.append(f"  kept {term!r}: {current!r}; the file {how} {value!r}")
                counts["kept"] += 1
                kept = True
        summary = ", ".join(f"{count} {label}" for label, count in counts.items() if count)
        print(f"{path}: {len(document.get('terms') or {})} {LANGUAGES[language]} terms" + (f": {summary}" if summary else ""))
        for line in lines:
            print(line)
    if kept and not arguments.replace:
        print("Where a file differs, the glossary keeps its own words and notes. To revise them on purpose, run "
              "glossary --replace on a file with only the corrections (--dry-run first shows what it changes).")
    if arguments.dry_run:
        print("Dry run: the glossary is unchanged.")
    elif json.dumps(shared, sort_keys=True) != before:
        GLOSSARY.write_text(json.dumps(shared, indent=2, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8")


def normalized(text):
    return " ".join(text.casefold().split()).rstrip(".;!? ")


def sentences(notes):
    """Notes in sentences, and the parts of a sentence between semicolons."""
    return [part for part in re.split(r"(?<=[.;!?])\s+", notes) if part.strip()]


def unlike(notes, other):
    """What notes say that other doesn't, in their own words."""
    known = {normalized(part) for part in sentences(other)}
    return " ".join(part for part in sentences(notes) if normalized(part) not in known)


def preview(text, limit=400):
    return text if len(text) <= limit else text[:limit - 1] + "…"


def check(arguments):
    catalog = load()
    entries = translatable(catalog)
    errors = []
    regions = re.search(r"knownRegions = \((.*?)\);", PROJECT.read_text(encoding="utf-8"), re.S)
    known = {region.strip().strip('"') for region in (regions.group(1).split(",") if regions else [])}
    for language in LANGUAGES:
        if language not in known:
            errors.append(f"{language} isn't in the project's knownRegions")
    stale = [key for key, entry in catalog["strings"].items() if entry.get("extractionState") == "stale"]
    if stale:
        errors.append(f"{len(stale)} strings aren't used anymore; run sync")
    for language in selected(arguments):
        for key, entry in sorted(entries.items()):
            value, state = translation(entry, language)
            if value is None:
                errors.append(f"{language}: {key!r} isn't translated")
            elif state != "translated":
                errors.append(f"{language}: {key!r} needs review ({state})")
            else:
                errors.extend(f"{language}: {key!r}: {problem}" for problem in problems(key, entry, language, value))
    for key, entry in entries.items():
        if isinstance(english(key, entry), dict):
            errors.extend(f"en: {key!r}: {problem}" for problem in problems(key, entry, "en", english(key, entry)))
    for error in errors[:200]:
        print(error)
    if len(errors) > 200:
        print(f"… and {len(errors) - 200} more")
    if errors:
        sys.exit(f"{len(errors)} problems.")
    print(f"All {len(entries)} strings are translated into {len(selected(arguments))} languages.")


def selected(arguments):
    if not getattr(arguments, "lang", None):
        return list(LANGUAGES)
    languages = [language.strip() for language in arguments.lang.split(",") if language.strip()]
    unknown = [language for language in languages if language not in LANGUAGES]
    if unknown:
        sys.exit(f"Unknown languages: {', '.join(unknown)} (known: {', '.join(LANGUAGES)})")
    return languages


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("sync", help="build, then update the catalog from the code")
    command.add_argument("--no-build", action="store_true", help="use the last build's extracted strings")
    command.add_argument("--lang")
    command.set_defaults(run=sync)
    command = commands.add_parser("status", help="what each language still needs")
    command.add_argument("--lang")
    command.set_defaults(run=status)
    command = commands.add_parser("plural", help="the English singular of a string with a count")
    command.add_argument("key")
    command.add_argument("one")
    command.set_defaults(run=plural)
    command = commands.add_parser("dnt", help="mark strings as the same in every language")
    command.add_argument("keys", nargs="+")
    command.set_defaults(run=dnt)
    command = commands.add_parser("review", help="mark a string's translations to redo")
    command.add_argument("key")
    command.add_argument("--lang")
    command.set_defaults(run=review)
    command = commands.add_parser("export", help="a JSON file per language with what it still needs")
    command.add_argument("folder")
    command.add_argument("--lang")
    command.add_argument("--all", action="store_true", help="every string, with its current translation")
    command.set_defaults(run=export)
    command = commands.add_parser("import", help="merge translated JSON files into the catalog")
    command.add_argument("files", nargs="+")
    command.add_argument("--dry-run", action="store_true", help="only check the files")
    command.set_defaults(run=import_)
    command = commands.add_parser("glossary", help="add translators' new terms to the shared glossary")
    command.add_argument("files", nargs="+")
    command.add_argument("--replace", action="store_true",
                         help="take the files' words where they differ from the glossary's, and add what their notes "
                              "say that its don't (a revision on purpose)")
    command.add_argument("--dry-run", action="store_true", help="only show what would change")
    command.set_defaults(run=glossary)
    command = commands.add_parser("check", help="fail when a translation is missing or broken")
    command.add_argument("--lang")
    command.set_defaults(run=check)
    arguments = parser.parse_args()
    arguments.run(arguments)


if __name__ == "__main__":
    main()
