#!/usr/bin/env python3
"""
add_script.py — add (or update) a script entry in the gizmos catalog README.

Reads a local shell script in the gizmos repo, then inserts a standardized
section into README.md, keeping the catalog in alphabetical order and
rebuilding the table of contents to match.

Usage:
    python add_script.py <path/to/script.sh> [--readme README.md] \
        [--name NAME] [--desc "short description"] [--shell zsh] \
        [--dry-run]

If --name / --desc / --shell are omitted the script infers them:
    name  -> the script's filename without extension
    shell -> from the file's shebang (zsh / bash / bash/zsh fallback)
    desc  -> a TODO placeholder to fill in (no reliable source in the file)

The README is expected to contain these anchor markers (added automatically
on first run if missing):
    <!-- toc:start --> ... <!-- toc:end -->            (table of contents block)
    <!-- sections:start --> ... <!-- sections:end -->  (the per-script sections)
"""

import argparse
import os
import re
import sys

TOC_START = "<!-- toc:start -->"
TOC_END = "<!-- toc:end -->"
SEC_START = "<!-- sections:start -->"
SEC_END = "<!-- sections:end -->"


# --------------------------------------------------------------------------
# script inspection
# --------------------------------------------------------------------------
def read_script(path: str) -> str:
    if not os.path.isfile(path):
        raise SystemExit(f"error: no such file: {path}")
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def infer_shell(content: str) -> str:
    first = content.splitlines()[0] if content else ""
    if "zsh" in first:
        return "zsh"
    if "bash" in first or "/sh" in first:
        return "bash/zsh"
    return "zsh"


def infer_meta(path: str, content: str, args) -> dict:
    filename = os.path.basename(path)
    base = filename.rsplit(".", 1)[0]

    name = args.name or base
    shell = args.shell or infer_shell(content)
    desc = args.desc or "TODO: short one-line description"

    return {
        "name": name,
        "file": filename,
        "shell": shell,
        "desc": desc,
    }


# --------------------------------------------------------------------------
# README parsing / rebuilding
# --------------------------------------------------------------------------
def slugify(name: str) -> str:
    s = name.strip().lower()
    s = re.sub(r"[^\w\- ]", "", s)
    s = s.replace(" ", "-")
    return s


SECTION_TEMPLATE = """## {name}

`{file}` · {shell}

{desc}

```sh
# usage
{name} --help
```
"""


def build_section(meta: dict) -> str:
    return SECTION_TEMPLATE.format(
        name=meta["name"],
        file=meta["file"],
        shell=meta["shell"],
        desc=meta["desc"],
    ).strip()


def parse_sections(body: str) -> dict:
    """Return {name: full_section_text} from inside the sections block."""
    sections = {}
    parts = re.split(r"(?m)^## ", body.strip())
    for p in parts:
        p = p.strip()
        if not p:
            continue
        # drop a trailing horizontal rule so joins control separators
        p = re.sub(r"\n+-{3,}\s*$", "", p).rstrip()
        name = p.splitlines()[0].strip()
        # ignore stray rule fragments that aren't real sections
        if not name or re.fullmatch(r"-{3,}", name):
            continue
        sections[name] = "## " + p
    return sections


def build_toc(names_descs: list) -> str:
    lines = ["- [Setup](#setup)"]
    for name, desc in names_descs:
        lines.append(f"- [{name}](#{slugify(name)}) — {desc}")
    return "\n".join(lines)


def first_line_desc(section_text: str) -> str:
    """Pull a short description from a section: the first prose paragraph."""
    lines = section_text.splitlines()
    for ln in lines[1:]:
        s = ln.strip()
        if not s:
            continue
        # skip the `file` · shell metadata line, code fences, headers
        if s.startswith("`") or s.startswith("```") \
                or s.startswith("#") or s.startswith(">"):
            continue
        return s.rstrip(".")
    return ""


def ensure_markers(text: str) -> str:
    """Make sure both marker blocks exist.

    If markers are already present, return as-is. If the file has existing
    content (a TOC list and/or '## ' sections) but no markers, wrap them in
    place so the custom intro/setup wording is preserved. Only when the file
    is effectively empty do we lay down a fresh scaffold.
    """
    has_sec = SEC_START in text and SEC_END in text
    has_toc = TOC_START in text and TOC_END in text
    if has_sec and has_toc:
        return text

    stripped = text.strip()
    if stripped and ("## " in stripped):
        if not has_toc:
            toc_hdr = re.search(r"(?m)^##\s+Table of contents\s*$", text)
            if toc_hdr:
                after = text[toc_hdr.end():]
                lm = re.search(r"((?:\s*\n)*(?:^- .*\n?)+)", after, re.M)
                if lm:
                    block = lm.group(1)
                    wrapped = "\n\n" + TOC_START + "\n" + block.strip() + "\n" + TOC_END + "\n"
                    text = text[:toc_hdr.end()] + wrapped + after[lm.end():]
        if SEC_START not in text:
            for mm in re.finditer(r"(?m)^## (.+)$", text):
                title = mm.group(1).strip().lower()
                if title in ("table of contents", "setup"):
                    continue
                start = mm.start()
                pre = text[:start]
                rule = re.search(r"\n---\s*\n\s*$", pre)
                insert_at = rule.start() + 1 if rule else start
                text = (text[:insert_at] + SEC_START + "\n\n"
                        + text[insert_at:].rstrip() + "\n\n" + SEC_END + "\n")
                break
        return text

    title = "# gizmos\n"
    m = re.match(r"(# .*\n)", text)
    if m:
        title = m.group(1)
    scaffold = (
        title + "\n"
        "A catalog of small, single-file shell utilities.\n\n"
        "## Table of contents\n\n"
        + TOC_START + "\n- [Setup](#setup)\n" + TOC_END + "\n\n"
        "---\n\n"
        "## Setup\n\n"
        "Clone the repo, then add this loop to your shell config to source "
        "every script.\n\n"
        "```sh\n"
        "git clone <repo-url> ~/.gizmos\n"
        "for f in ~/.gizmos/*.sh; do\n"
        '  [ -r "$f" ] && source "$f"\n'
        "done\n"
        "source ~/.zshrc\n"
        "```\n\n"
        "---\n\n"
        + SEC_START + "\n" + SEC_END + "\n"
    )
    return scaffold


def splice(text: str, meta: dict, desc_explicit: bool = True) -> str:
    text = ensure_markers(text)

    # Capture existing TOC descriptions so curated blurbs aren't clobbered.
    existing_toc = {}
    if TOC_START in text and TOC_END in text:
        toc_body = text[text.index(TOC_START) + len(TOC_START):text.index(TOC_END)]
        for ln in toc_body.splitlines():
            mm = re.match(r"\s*-\s*\[([^\]]+)\]\([^)]*\)\s*—\s*(.+?)\s*$", ln)
            if mm:
                existing_toc[mm.group(1).strip()] = mm.group(2).strip()

    # --- sections block ---
    sec_block = text[text.index(SEC_START) + len(SEC_START):text.index(SEC_END)]
    sections = parse_sections(sec_block)

    # If updating an existing section and no description was explicitly given,
    # keep the description already on file (prefer the section body, then TOC)
    # instead of writing a TODO placeholder.
    if not desc_explicit and meta["name"] in sections:
        prior = first_line_desc(sections[meta["name"]])
        if not prior and meta["name"] in existing_toc:
            prior = existing_toc[meta["name"]]
        if prior:
            meta = {**meta, "desc": prior}

    # add/replace this script's section
    sections[meta["name"]] = build_section(meta)

    # rebuild in alphabetical order, separated by --- rules
    ordered = sorted(sections.keys(), key=str.lower)
    rebuilt = "\n\n---\n\n".join(sections[n] for n in ordered)
    new_sec_block = f"{SEC_START}\n\n{rebuilt}\n\n{SEC_END}"
    text = (
        text[:text.index(SEC_START)]
        + new_sec_block
        + text[text.index(SEC_END) + len(SEC_END):]
    )

    # --- toc block ---
    names_descs = []
    for n in ordered:
        if n == meta["name"]:
            d = meta["desc"]
        elif n in existing_toc:
            d = existing_toc[n]
        else:
            d = first_line_desc(sections[n])
        names_descs.append((n, d))
    toc = build_toc(names_descs)
    new_toc_block = f"{TOC_START}\n{toc}\n{TOC_END}"
    text = (
        text[:text.index(TOC_START)]
        + new_toc_block
        + text[text.index(TOC_END) + len(TOC_END):]
    )

    return text


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(
        description="Add a local shell script to the gizmos catalog README.")
    ap.add_argument("script", help="path to the .sh script in the repo")
    ap.add_argument("--readme", default="README.md")
    ap.add_argument("--name", help="override the section name")
    ap.add_argument("--desc", help="override the short description")
    ap.add_argument("--shell", help="override the shell label (e.g. zsh, bash/zsh)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the result instead of writing")
    args = ap.parse_args()

    content = read_script(args.script)
    meta = infer_meta(args.script, content, args)
    desc_explicit = args.desc is not None

    try:
        with open(args.readme, "r", encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        text = ""

    # detect add vs update before splicing
    was_present = False
    if SEC_START in text and SEC_END in text:
        existing = parse_sections(
            text[text.index(SEC_START) + len(SEC_START):text.index(SEC_END)])
        was_present = meta["name"] in existing

    updated = splice(text, meta, desc_explicit=desc_explicit)

    if args.dry_run:
        sys.stdout.write(updated)
        return

    with open(args.readme, "w", encoding="utf-8") as f:
        f.write(updated)

    action = "Updated" if was_present else "Added"
    # report the description that actually landed in the file
    final_sections = parse_sections(
        updated[updated.index(SEC_START) + len(SEC_START):updated.index(SEC_END)])
    final_desc = first_line_desc(final_sections.get(meta["name"], "")) or meta["desc"]
    print(f"{action} section: {meta['name']}  (`{meta['file']}` · {meta['shell']})")
    print(f"  desc: {final_desc}")
    print(f"  README: {args.readme}")
    if final_desc.startswith("TODO"):
        print("  note: no description given — edit the placeholder, "
              "or re-run with --desc \"...\".")


if __name__ == "__main__":
    main()
