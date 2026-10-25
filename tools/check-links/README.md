# check-links

A dependency-free Python 3 (3.8+) checker for **relative links and `#anchors`** in the repository's Markdown
files. CI runs it on every push and pull request ([`.github/workflows/docs.yml`](../../.github/workflows/docs.yml)).

## Usage

From the repository root:

```sh
python3 tools/check-links/check_links.py                 # check every Markdown file
python3 tools/check-links/check_links.py docs/protocol.md README.md   # check only these files
python3 tools/check-links/check_links.py --exclude 'spikes/s07-*/vendor/*'   # skip matching files
python3 -m unittest discover -s tools/check-links        # run the checker's own tests
```

Each problem is printed as `path:line:column: message`, followed by a one-line summary. Exit status: `0` no
problems, `1` problems found, `2` usage error. Inside GitHub Actions it also emits `::error` annotations, so
problems show up on the pull request diff.

## What it checks

- **Which files:** every `*.md` / `*.markdown` file Git knows about — tracked files plus untracked files that
  are not ignored — so a local run sees what CI sees. Without Git it walks the tree, skipping `.git`, `build`,
  `.build`, `target`, `.gradle`, `node_modules` and `DerivedData`.
- **Which links:** inline links and images (`[text](target)`, `![alt](target)`, including `<angle brackets>`,
  titles and balanced parentheses), reference definitions (`[label]: target`), full and collapsed reference
  links whose label is never defined (`[text][label]`, `[label][]`), and `href` / `src` attributes in raw HTML.
- **Targets:** resolved relative to the linking file (a leading `/` means the repository root). The target
  must be a file or directory in the repository, matched **case-sensitively** (GitHub is case-sensitive even
  where macOS is not). Links that leave the repository are errors.
- **Anchors:** `#fragment` must match a heading in the target Markdown file (or the same file), or an explicit
  HTML `id` / `name` attribute. Headings get GitHub-style slugs: the rendered heading text is lower-cased,
  every character other than word characters, hyphens and spaces is dropped, and each space becomes a hyphen;
  repeated headings get `-1`, `-2`, … suffixes. Matching is exact (case-sensitive); a case-only mismatch is
  reported with a hint. A fragment on a directory link is checked against that directory's `README.md`.

## What it deliberately ignores

- Anything with a URI scheme (`https:`, `http:`, `mailto:`, …) and protocol-relative `//host` URLs —
  external links are not fetched.
- Fenced code blocks (```` ``` ```` and `~~~`), inline code spans and HTML comments.
- Anchors into non-Markdown files (for example `file.py#L10` line links or `page.html#id`).

## Known limitations

- Indented (four-space) code blocks are **not** treated as code; use fenced blocks for example links.
- The slug rules approximate GitHub's renderer; unusual inline Markdown in headings (nested emphasis with
  underscores, raw HTML entities, emoji shortcodes) may slug differently. If the checker disagrees with
  GitHub, add an explicit `<a id="…"></a>` or fix the checker and its tests.
