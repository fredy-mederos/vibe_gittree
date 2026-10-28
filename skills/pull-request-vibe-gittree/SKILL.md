---
name: pull-request-vibe-gittree
description: "Get a change to Vibe GitTree ready for a pull request and open it the way CONTRIBUTING.md asks: check it against CLAUDE.md, check its translations, build it without warnings, collect the prompts that made it word for word, take before-and-after screenshots with a public or throwaway repository, write the description from the pull request template, open it as a draft once the user has seen everything and mark it ready when the screenshots are in. Use when asked to open, create, send or submit a pull request to Vibe GitTree (fredy-mederos/vibe_gittree), to contribute a change upstream, or to get a branch ready for review."
---

# Open a Vibe GitTree Pull Request

## Overview

Pull requests to Vibe GitTree (`fredy-mederos/vibe_gittree`) are welcome when their description
shows what was done (`CONTRIBUTING.md`): the prompts that made the change, word for word, and
screenshots of it in the app. One without both isn't reviewed. `.github/pull_request_template.md`
is the description's outline, with a checklist of the project's rules.

Everything in a pull request is public, so the user sees the prompts, the screenshots and the
description before anything goes out. Screenshots need a Mac that builds and runs the app (macOS 15
or later, Xcode); in a session that can't (Linux, a cloud container), do the rest, tell the user
which screenshots to take and how (step 3), and leave the pull request a draft until they're in.

## Workflow

1. Check the change.
- It's on a branch of its own, not `main`, that the user can push: in their fork
  (`gh repo fork --remote` in a clone of Vibe GitTree makes one and adds it as a remote), unless
  they can push to the repository itself.
- `upstream` below is the remote for `fredy-mederos/vibe_gittree` (`git remote -v`; add it if it's
  missing). After `git fetch upstream main`, `git log --oneline upstream/main..HEAD` and
  `git diff upstream/main...HEAD` show what the pull request brings: this change and nothing else
  (no unrelated commits, build products, `dist/`, screenshots or local settings).
- It follows `CLAUDE.md`; read it first if your agent doesn't load it on its own. Among its rules:
  the app stays read-only unless the user allows changes, native components and system colors, big
  lists in AppKit, heavy work off the main thread, gentle network use, and neutral samples (Acme,
  `PROJ-123`), never names from anyone's work.
- When it adds or changes text the app shows: `scripts/localization.py sync`, then
  `scripts/localization.py check` passes. If a language misses strings, translate them with the
  `localize-vibe-gittree` skill, and commit them with the change.
- The build succeeds with no `warning:` lines:
  `xcodebuild -project GitTree.xcodeproj -scheme GitTree -configuration Debug -derivedDataPath build/DerivedData build`.
- Commits are under the user's own name (the identity in `CLAUDE.md` is the owner's), with
  messages like the repository's (`git log`): what changed, in plain words.

2. Collect the prompts.
- Every message the user sent you for this change, word for word and in order: the first request,
  follow-ups, corrections and answers to your questions. Not your replies, not tool output.
- Any you no longer have word for word (from an earlier session, or a conversation that was
  summarized): ask the user for them; don't rewrite them from memory.
- One that isn't in English stays as written, with an English translation after it.
- Show them to the user. Take out something private (a name, a path, a company, a ticket, a token)
  only with their OK, and mark the cut: `[removed]`.

3. Take the screenshots.
- Use a public or throwaway repository, never the user's private work. Vibe GitTree's own history
  works well: `git clone --mirror https://github.com/fredy-mederos/vibe_gittree.git <temp>/sample.git`
  (a plain `git clone` for anything about uncommitted changes or stashes), in a temp folder, not
  in Documents, Desktop or Downloads, so macOS doesn't ask for folder access. For Jira, run
  `python3 scripts/mock-jira.py 8899` and pass `-GTJiraSite http://127.0.0.1:8899`.
- `scripts/snapshot.sh` launches the Debug build with a throwaway library and captures only its
  window. It quits every running Vibe GitTree first, the user's installed copy too: ask before
  running it while that one is open. The window has to be in front while it's captured.
- After: `scripts/snapshot.sh <temp>/after.png 8 -GTOpenRepository <temp>/sample.git [arguments]`.
  The README's "Checking the UI from the command line" lists the arguments that bring the change on
  screen (`-GTSelect`, `-GTSearch`, `-GTCompare`, `-GTAppearance dark`…); `scripts/snapshot-rows.sh`
  captures sidebar rows as they're selected.
- Before, when the change alters something that was already there: the same capture from the
  commit the branch starts from, in a worktree of its own:
  `git worktree add <temp>/before $(git merge-base HEAD upstream/main)`, the same build command
  in `<temp>/before`, then `<temp>/before/scripts/snapshot.sh <temp>/before.png 8` with the same
  arguments, and `git worktree remove <temp>/before`.
- Colors or selected rows: light and dark (`-GTAppearance light`, `-GTAppearance dark`).
- A change with nothing to see in the app (a script, the build): show it working, in a screenshot
  or its output.
- When `screencapture` can't capture (no screen recording permission), launch the Debug build
  yourself (a throwaway library, and no windows restored from the user's own sessions) and it
  captures its own windows into `<temp>/shots`:
```bash
open -n "build/DerivedData/Build/Products/Debug/Vibe GitTree.app" --args -GTDataDirectory <temp>/library \
  -ApplePersistenceIgnoreState YES -GTSnapshot <temp>/shots -GTOpenRepository <temp>/sample.git [arguments]
```
- Keep the images outside the repository, so they aren't committed, and look at every one: it shows
  the change, and nothing private.

4. Write the description from `.github/pull_request_template.md`, keeping its headings, in a file
   outside the repository.
- What it changes: what the change does and why, in a few sentences.
- Prompt: the prompts from step 2, in order, each in a quote block.
- Screenshots: a line per image saying what it shows (before or after, which window, light or
  dark), with a placeholder under it for the image: `gh` can't upload images, so the user drags
  them in on GitHub.
- Checklist: check what's true. Anything left unchecked gets a line saying why.
- The title says what the change does, in a short, plain sentence like the repository's commit
  messages.

5. Open the pull request, once the user has read the description and said yes.
- Push the branch to the fork (`git push -u origin <branch>`, when `origin` is the fork), then:
```bash
gh pr create --repo fredy-mederos/vibe_gittree --base main --head <fork owner>:<branch> --draft \
  --title "<title>" --body-file <description file>
```
- Give the user its URL and the images' paths: on GitHub they edit the description (… › Edit) and
  drag each image onto its placeholder.

6. Mark it ready once the images are in.
- `gh pr view <number> --repo fredy-mederos/vibe_gittree --json body` shows the prompts and an
  image where each placeholder was.
- Then `gh pr ready <number> --repo fredy-mederos/vibe_gittree` (or the user clicks Ready for
  review), and share the URL.

## Guardrails

- Nothing goes out without the user's OK: a pushed branch, the prompts, the screenshots and the
  description are public.
- A pull request stays a draft until it has the prompts and the screenshots.
- Commit under the user's own name, never the owner's identity from `CLAUDE.md`.
- Screenshots go in the description, not the repository (unless the change is to the README's own
  picture, `screenshots/gittree.png`).
- Push only the pull request's own branch: never `main`, never someone else's branch.
