#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check relative links and #anchors in the repository's Markdown files.

Dependency-free (Python 3.8+ standard library only). See README.md next to this
file for what is checked and what is deliberately ignored.

Exit status: 0 = no problems, 1 = problems found, 2 = usage error.
"""

import argparse
import bisect
import fnmatch
import html
import os
import re
import subprocess
import sys
from urllib.parse import unquote

MARKDOWN_EXTENSIONS = (".md", ".markdown")

# A URI scheme ("https:", "mailto:", "tel:", ...). Anything with a scheme, and
# protocol-relative "//host/..." URLs, is external and not checked.
SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.\-]*:")

FENCE_OPEN_RE = re.compile(r"^(?P<prefix>[ \t>]*)(?P<fence>`{3,}|~{3,})(?P<info>.*)$")
ATX_HEADING_RE = re.compile(r"^ {0,3}(#{1,6})(?=[ \t]|$)(.*)$")
SETEXT_UNDERLINE_RE = re.compile(r"^ {0,3}(=+|-+)[ \t]*$")
BLOCKQUOTE_PREFIX_RE = re.compile(r"^(?: {0,3}>[ \t]?)+")
NOT_PARAGRAPH_RE = re.compile(r"^ {0,3}(?:[-+*][ \t]|\d{1,9}[.)][ \t]|>|\||#|<)")
REFERENCE_DEF_RE = re.compile(
    r"^ {0,3}\[(?P<label>[^\]]+)\]:[ \t]*(?:<(?P<angle>[^>\n]*)>|(?P<bare>\S+))",
    re.MULTILINE,
)
FULL_REFERENCE_RE = re.compile(r"(?<![\]\\])\[(?P<text>[^\[\]\n]*)\]\[(?P<label>[^\[\]\n]*)\]")
HTML_ATTR_RE = re.compile(r"""(?i)<[a-z][^<>]*?\b(?P<attr>href|src)\s*=\s*(?:"(?P<dq>[^"]*)"|'(?P<sq>[^']*)')""")
HTML_ID_RE = re.compile(r"""(?i)<[a-z][^<>]*?\b(?:id|name)\s*=\s*(?:"([^"]*)"|'([^']*)')""")
HTML_COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)
HTML_TAG_RE = re.compile(r"<[^<>]+>")
BACKSLASH_ESCAPE_RE = re.compile(r"\\([!-/:-@\[-`{-~])")

DEFAULT_EXCLUDED_DIRS = {".git", "node_modules", ".build", "build", "target", ".gradle", "DerivedData"}


# --------------------------------------------------------------------------
# Masking: blank out text that GitHub does not render as links (fenced code,
# inline code spans, HTML comments) while keeping every newline, so offsets in
# the masked text still map to the original line numbers.
# --------------------------------------------------------------------------

def _blank(text):
    return re.sub(r"[^\n]", " ", text)


def fenced_line_flags(lines):
    """Return a list of booleans: True where a line is part of a fenced code block
    (including the opening and closing fence lines). An unclosed fence runs to the
    end of the document, as in CommonMark."""
    flags = [False] * len(lines)
    fence_char = None
    fence_len = 0
    for i, line in enumerate(lines):
        if fence_char is None:
            m = FENCE_OPEN_RE.match(line)
            if m and not (m.group("fence")[0] == "`" and "`" in m.group("info")):
                fence_char = m.group("fence")[0]
                fence_len = len(m.group("fence"))
                flags[i] = True
        else:
            flags[i] = True
            stripped = line.lstrip(" \t>")
            run = len(stripped) - len(stripped.lstrip(fence_char))
            if run >= fence_len and stripped[run:].strip() == "":
                fence_char = None
    return flags


def mask_code_spans(chunk):
    """Blank inline code spans in one paragraph-sized chunk of text (CommonMark:
    a run of N backticks opens a span closed by the next run of exactly N)."""
    out = []
    i = 0
    n = len(chunk)
    while i < n:
        if chunk[i] == "\\" and i + 1 < n and chunk[i + 1] == "`":
            out.append(chunk[i:i + 2])
            i += 2
            continue
        if chunk[i] != "`":
            out.append(chunk[i])
            i += 1
            continue
        j = i
        while j < n and chunk[j] == "`":
            j += 1
        run = j - i
        k = j
        close = -1
        while k < n:
            if chunk[k] == "`":
                m = k
                while m < n and chunk[m] == "`":
                    m += 1
                if m - k == run:
                    close = k
                    break
                k = m
            else:
                k += 1
        if close == -1:
            out.append(chunk[i:j])  # unmatched backticks are literal text
            i = j
        else:
            out.append(_blank(chunk[i:close + run]))
            i = close + run
    return "".join(out)


def mask_markdown(text):
    """Return text with fenced code, inline code spans and HTML comments blanked."""
    lines = text.split("\n")
    fenced = fenced_line_flags(lines)
    lines = [_blank(line) if fenced[i] else line for i, line in enumerate(lines)]
    text = "\n".join(lines)
    text = HTML_COMMENT_RE.sub(lambda m: _blank(m.group(0)), text)
    # Code spans cannot cross a blank line, so mask paragraph by paragraph.
    parts = re.split(r"(\n[ \t]*\n)", text)
    return "".join(p if idx % 2 else mask_code_spans(p) for idx, p in enumerate(parts))


# --------------------------------------------------------------------------
# Headings and GitHub-style anchors
# --------------------------------------------------------------------------

def heading_plain_text(raw):
    """Approximate the rendered text of a heading's inline Markdown."""
    text = raw
    text = re.sub(r"(`+)(.+?)\1", lambda m: m.group(2), text)          # code spans keep their content
    text = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", text)              # images -> alt text
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)               # inline links -> text
    text = re.sub(r"\[([^\]]*)\]\[[^\]]*\]", r"\1", text)              # reference links -> text
    text = HTML_TAG_RE.sub("", text)                                   # inline HTML tags
    text = re.sub(r"(?<!\w)_+(?=\S)|(?<=\S)_+(?!\w)", "", text)        # _emphasis_ delimiters
    text = BACKSLASH_ESCAPE_RE.sub(r"\1", text)
    return html.unescape(text)


def base_slug(text):
    """GitHub-style slug: lowercase, drop everything except word characters,
    hyphens and spaces, then turn each space into a hyphen."""
    slug = text.strip().lower()
    slug = re.sub(r"[^\w\- ]", "", slug)
    return slug.replace(" ", "-")


class Slugger:
    """Assign unique slugs the way GitHub does for repeated headings:
    'foo', 'foo-1', 'foo-2', ... (mirrors github-slugger)."""

    def __init__(self):
        self.occurrences = {}

    def slug(self, text):
        original = base_slug(text)
        slug = original
        while slug in self.occurrences:
            self.occurrences[original] += 1
            slug = "%s-%d" % (original, self.occurrences[original])
        self.occurrences[slug] = 0
        return slug


def extract_headings(text):
    """Return the raw text of every ATX and setext heading outside fenced code."""
    lines = text.split("\n")
    fenced = fenced_line_flags(lines)
    headings = []
    prev_paragraph_line = None
    for i, line in enumerate(lines):
        if fenced[i]:
            prev_paragraph_line = None
            continue
        content = BLOCKQUOTE_PREFIX_RE.sub("", line)
        m = ATX_HEADING_RE.match(content)
        if m:
            body = re.sub(r"(?:^|[ \t]+)#+[ \t]*$", "", m.group(2)).strip()
            headings.append(body)
            prev_paragraph_line = None
            continue
        if SETEXT_UNDERLINE_RE.match(content) and prev_paragraph_line is not None:
            headings.append(prev_paragraph_line.strip())
            prev_paragraph_line = None
            continue
        if content.strip() and not NOT_PARAGRAPH_RE.match(content) and not content.startswith(("    ", "\t")):
            prev_paragraph_line = content
        else:
            prev_paragraph_line = None
    return headings


def anchors_for(text):
    """All fragment targets a Markdown document defines: heading slugs plus
    explicit HTML id/name attributes."""
    slugger = Slugger()
    anchors = {slugger.slug(heading_plain_text(h)) for h in extract_headings(text)}
    for m in HTML_ID_RE.finditer(mask_markdown(text)):
        anchors.add(m.group(1) if m.group(1) is not None else m.group(2))
    return anchors


# --------------------------------------------------------------------------
# Link extraction
# --------------------------------------------------------------------------

def parse_destination(text, start):
    """Parse an inline link destination beginning at text[start] (just after the
    opening parenthesis). Returns the destination string, or None."""
    n = len(text)
    i = start
    while i < n and text[i] in " \t":
        i += 1
    if i < n and text[i] == "\n":
        i += 1
        while i < n and text[i] in " \t":
            i += 1
    if i < n and text[i] == "<":
        end = text.find(">", i + 1)
        if end == -1 or "\n" in text[i + 1:end]:
            return None
        return text[i + 1:end]
    depth = 0
    j = i
    while j < n:
        c = text[j]
        if c == "\\" and j + 1 < n:
            j += 2
            continue
        if c in " \t\n":
            break
        if c == "(":
            depth += 1
        elif c == ")":
            if depth == 0:
                break
            depth -= 1
        j += 1
    if j >= n:
        return None
    return text[i:j]


def normalize_label(label):
    return re.sub(r"\s+", " ", label.strip()).casefold()


def extract_links(text):
    """Yield (offset, destination, kind) for every link-like target in a document.
    kind is 'inline', 'reference-definition', 'html' or 'undefined-reference'."""
    masked = mask_markdown(text)

    definitions = set()
    for m in REFERENCE_DEF_RE.finditer(masked):
        definitions.add(normalize_label(m.group("label")))
        dest = m.group("angle") if m.group("angle") is not None else m.group("bare")
        yield m.start("label") - 1, dest, "reference-definition"

    pos = masked.find("](")
    while pos != -1:
        dest = parse_destination(masked, pos + 2)
        if dest is not None:
            yield pos + 2, dest, "inline"
        pos = masked.find("](", pos + 2)

    for m in FULL_REFERENCE_RE.finditer(masked):
        label = m.group("label") or m.group("text")
        if not label.strip() or label.startswith("^"):
            continue
        if masked[m.end():m.end() + 1] == "(":
            continue
        if normalize_label(label) not in definitions:
            yield m.start(), label, "undefined-reference"

    for m in HTML_ATTR_RE.finditer(masked):
        dest = m.group("dq") if m.group("dq") is not None else m.group("sq")
        yield m.start("attr"), dest, "html"


# --------------------------------------------------------------------------
# Repository model
# --------------------------------------------------------------------------

class Repo:
    def __init__(self, root, excludes):
        self.root = os.path.realpath(root)
        self.excludes = excludes
        self.files, self.source = self._list_files()
        self.dirs = {""}
        for f in self.files:
            parts = f.split("/")
            for k in range(1, len(parts)):
                self.dirs.add("/".join(parts[:k]))
        self._anchor_cache = {}

    def _excluded(self, rel):
        return any(fnmatch.fnmatch(rel, pat) or fnmatch.fnmatch(rel, pat.rstrip("/") + "/*")
                   for pat in self.excludes)

    def _list_files(self):
        """Files tracked by Git plus untracked, non-ignored files, so the result
        matches what CI sees after a checkout. Falls back to walking the tree when
        Git is unavailable."""
        try:
            out = subprocess.run(
                ["git", "-C", self.root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            ).stdout.decode("utf-8", "surrogateescape")
            files = {f for f in out.split("\0") if f and os.path.lexists(os.path.join(self.root, f))}
            source = "git"
        except (OSError, subprocess.CalledProcessError):
            files = set()
            for dirpath, dirnames, filenames in os.walk(self.root):
                dirnames[:] = [d for d in dirnames if d not in DEFAULT_EXCLUDED_DIRS]
                for name in filenames:
                    files.add(os.path.relpath(os.path.join(dirpath, name), self.root).replace(os.sep, "/"))
            source = "filesystem"
        return {f for f in files if not self._excluded(f)}, source

    def markdown_files(self):
        return sorted(f for f in self.files if f.lower().endswith(MARKDOWN_EXTENSIONS))

    def read(self, rel):
        with open(os.path.join(self.root, rel), encoding="utf-8") as fh:
            return fh.read()

    def anchors(self, rel):
        if rel not in self._anchor_cache:
            self._anchor_cache[rel] = anchors_for(self.read(rel))
        return self._anchor_cache[rel]


def resolve(source_rel, path):
    """Resolve a link path against the linking file. Returns a repo-relative
    POSIX path, or None if it escapes the repository root."""
    if path.startswith("/"):
        joined = path.lstrip("/")
    else:
        joined = "/".join(filter(None, [os.path.dirname(source_rel).replace(os.sep, "/"), path]))
    parts = []
    for part in joined.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                return None
            parts.pop()
        else:
            parts.append(part)
    return "/".join(parts)


def check_target(repo, source_rel, dest):
    """Return a problem message for one link destination, or None if it is fine
    (or external and therefore not checked)."""
    dest = BACKSLASH_ESCAPE_RE.sub(r"\1", html.unescape(dest.strip()))
    if not dest or dest.startswith("//") or SCHEME_RE.match(dest):
        return None
    path, _, fragment = dest.partition("#")
    path = unquote(path.split("?", 1)[0])
    fragment = unquote(fragment)

    if path:
        target = resolve(source_rel, path)
        if target is None:
            return "link points outside the repository: %s" % dest
        if target not in repo.files and target not in repo.dirs:
            return "broken link: %s (no such file or directory: %s)" % (dest, target or ".")
    else:
        target = source_rel

    if not fragment:
        return None
    if target in repo.dirs:
        readme = next((target + "/" + name if target else name
                       for name in ("README.md", "readme.md", "README.markdown")
                       if (target + "/" + name if target else name) in repo.files), None)
        if readme is None:
            return None
        target = readme
    if not target.lower().endswith(MARKDOWN_EXTENSIONS):
        return None  # anchors into non-Markdown files (code line links, HTML) are not checked
    anchors = repo.anchors(target)
    if fragment in anchors:
        return None
    hint = ""
    lowered = {a.lower(): a for a in anchors}
    if fragment.lower() in lowered:
        hint = " (did you mean #%s? anchors are case-sensitive)" % lowered[fragment.lower()]
    where = "" if target == source_rel else " in %s" % target
    return "broken anchor: %s (no heading or id '#%s'%s)%s" % (dest, fragment, where, hint)


def check_file(repo, rel):
    """Return (problems, checked, external) for one Markdown file, where problems
    is a list of (line, column, message)."""
    text = repo.read(rel)
    line_starts = [0] + [m.end() for m in re.finditer(r"\n", text)]
    problems, checked, external = [], 0, 0
    for offset, dest, kind in extract_links(text):
        line = bisect.bisect_right(line_starts, offset)
        col = offset - line_starts[line - 1] + 1
        if kind == "undefined-reference":
            problems.append((line, col, "undefined link reference: [%s]" % dest))
            continue
        stripped = dest.strip()
        if stripped.startswith("//") or SCHEME_RE.match(stripped):
            external += 1
            continue
        if not stripped:
            continue
        checked += 1
        message = check_target(repo, rel, dest)
        if message:
            problems.append((line, col, message))
    return problems, checked, external


def default_root():
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Check relative links and #anchors in Markdown files.")
    parser.add_argument("files", nargs="*",
                        help="Markdown files to check, relative to the root (default: every Markdown file)")
    parser.add_argument("--root", default=default_root(),
                        help="repository root (default: two levels above this script)")
    parser.add_argument("--exclude", action="append", default=[], metavar="GLOB",
                        help="skip files matching this repo-relative glob (repeatable), e.g. 'spikes/s07-*/vendor/*'")
    args = parser.parse_args(argv)

    if not os.path.isdir(args.root):
        parser.error("root is not a directory: %s" % args.root)
    repo = Repo(args.root, args.exclude)

    if args.files:
        selected = []
        for f in args.files:
            rel = os.path.relpath(os.path.abspath(f), repo.root).replace(os.sep, "/") \
                if os.path.isabs(f) or os.path.exists(f) else f.replace(os.sep, "/")
            if rel not in repo.files:
                parser.error("not a file in the repository: %s" % f)
            selected.append(rel)
    else:
        selected = repo.markdown_files()

    in_actions = os.environ.get("GITHUB_ACTIONS") == "true"
    total_problems = total_checked = total_external = 0
    for rel in selected:
        problems, checked, external = check_file(repo, rel)
        total_checked += checked
        total_external += external
        for line, col, message in sorted(problems):
            total_problems += 1
            print("%s:%d:%d: %s" % (rel, line, col, message))
            if in_actions:
                print("::error file=%s,line=%d,col=%d::%s" % (rel, line, col, message))

    summary = "check-links: %d Markdown file(s), %d relative link(s) checked, %d external link(s) skipped (files from %s)" % (
        len(selected), total_checked, total_external, repo.source)
    if total_problems:
        print("%s: %d problem(s)" % (summary, total_problems))
        return 1
    print("%s: no problems" % summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
