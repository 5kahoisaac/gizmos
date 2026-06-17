---
name: gizmos-catalog
description: Add or update a script entry in the "gizmos" catalog README. Use whenever the user adds a new shell script (a .sh file) to their gizmos repo and wants it documented, or says things like "add this script to the readme", "catalog this cli", "update the gizmos readme", "add a section for gac.sh", or drops a script alongside the README and asks to document it. Handles reading the script, generating a standardized section, inserting it in alphabetical order, and rebuilding the table of contents to match. Trigger this even if the user only says "add this to my catalog" with a script file and doesn't mention the readme explicitly.
---

# gizmos-catalog

Adds a shell script in the `gizmos` repo to the catalog README as a standardized
section, keeping entries in alphabetical order and the table of contents in
sync.

## What it does

Given the path to a `.sh` script in the repo, the bundled
`scripts/add_script.py`:

1. Reads the script file.
2. Infers a section **name** (filename minus extension) and **shell** label
   (from the shebang: `zsh`, or `bash/zsh` for bash/sh).
3. Inserts or replaces a section in `README.md` using the standard template.
4. Re-sorts all sections alphabetically (case-insensitive).
5. Rebuilds the table of contents so each entry links to its section with a
   short description.

The script preserves the README's custom intro and Setup wording — it only
manages the TOC list and the per-script sections, marked by HTML comment
anchors (`<!-- toc:start/end -->` and `<!-- sections:start/end -->`). On first
run against a README without those anchors, it wraps the existing content in
place.

There is no reliable description inside a script file, so **the user must
supply a one-line description** via `--desc` (or you propose one from the
script's behavior and confirm it). Without it, the section gets a `TODO:`
placeholder.

## How to use it

Run the script from the repo root (or pass `--readme PATH`):

```bash
python scripts/add_script.py path/to/<name>.sh \
  --readme README.md \
  --desc "short one-line description"
```

Overrides:

- `--name`  — section heading / command name (default: filename without `.sh`)
- `--desc`  — the short description used in the TOC and section body
- `--shell` — override the inferred shell label (e.g. `zsh`, `bash/zsh`)
- `--dry-run` — print the resulting README to stdout instead of writing it

## Workflow

1. **Locate the README and the script.** Both live in the gizmos repo. If
   there's no README yet, the tool scaffolds one (with the repo clone +
   loop-source Setup block).
2. **Get a description.** Read the script to understand what it does, propose a
   terse one-line description, and confirm it with the user. Pass it via
   `--desc`.
3. **Dry run** (`--dry-run`) to show the user the section and TOC entry that
   will be added; confirm the inferred name and shell.
4. **Apply** without `--dry-run` to write the file.
5. **Show the result** — the updated TOC and the new section.

## Notes and edge cases

- **Idempotent.** Re-running on the same script updates that section in place
  (no duplicates). If you omit `--desc` on an update, the existing description
  is preserved rather than replaced with a placeholder.
- **Description quality.** The TOC reads best with terse, lowercase, verb-first
  descriptions (e.g. "switch between multiple Claude Code accounts", "update
  all your AI coding CLIs at once").
- **Curated TOC blurbs are kept.** Sections you aren't touching retain their
  existing TOC description; the tool won't overwrite them with longer section
  prose.
- **Usage example.** A freshly generated section defaults to `<name> --help`.
  Offer to replace it with a more representative example from the script's
  actual commands.
- **Fallback.** If Python isn't available, edit the README by hand using the
  same template and ordering rules below.

## Section template

Each section follows this shape (the script generates it):

```markdown
## <name>

`<name>.sh` · <shell>

<short description>

```sh
# usage
<name> --help
```
```
