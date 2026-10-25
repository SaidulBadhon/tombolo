# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for check_links.py. Run: python3 -m unittest discover -s tools/check-links"""

import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_links  # noqa: E402


class RepoTestCase(unittest.TestCase):
    def make_repo(self, files):
        root = tempfile.mkdtemp(prefix="check-links-test-")
        self.addCleanup(shutil.rmtree, root)
        for rel, content in files.items():
            path = os.path.join(root, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(textwrap.dedent(content))
        return root

    def problems(self, files, rel="README.md"):
        root = self.make_repo(files)
        repo = check_links.Repo(root, [])
        return [msg for _, _, msg in check_links.check_file(repo, rel)[0]]


class SlugTests(unittest.TestCase):
    def slug(self, raw):
        return check_links.base_slug(check_links.heading_plain_text(raw))

    def test_punctuation_and_dashes(self):
        self.assertEqual(self.slug("Phase 0 — Foundations, spikes & security design (12–17 ew)"),
                         "phase-0--foundations-spikes--security-design-1217-ew")

    def test_inline_code_and_links_keep_their_text(self):
        self.assertEqual(self.slug("0.C Spikes (each produces a short write-up in `docs/spikes/`)"),
                         "0c-spikes-each-produces-a-short-write-up-in-docsspikes")
        self.assertEqual(self.slug("See [the plan](plan.md) **now**"), "see-the-plan-now")

    def test_underscores_inside_words_are_kept(self):
        self.assertEqual(self.slug("ACCESS_LOCAL_NETWORK and _emphasis_"), "access_local_network-and-emphasis")

    def test_duplicates_get_numeric_suffixes(self):
        s = check_links.Slugger()
        self.assertEqual([s.slug(t) for t in ["Setup", "Setup", "Setup-1", "Setup"]],
                         ["setup", "setup-1", "setup-1-1", "setup-2"])


class HeadingTests(unittest.TestCase):
    def test_atx_setext_and_fenced(self):
        text = textwrap.dedent("""\
            # Title #
            Setext heading
            --------------
            ```
            # not a heading
            ```
            > ## Quoted heading
            - list item
            ---
            """)
        self.assertEqual(check_links.extract_headings(text), ["Title", "Setext heading", "Quoted heading"])

    def test_html_ids_are_anchors(self):
        anchors = check_links.anchors_for('<a id="custom"></a>\n<a name="other"></a>\n# Heading\n')
        self.assertEqual(anchors, {"custom", "other", "heading"})


class LinkTests(RepoTestCase):
    def test_valid_links_pass(self):
        self.assertEqual(self.problems({
            "README.md": """\
                # Top
                [self](#top) [doc](docs/a.md) [anchor](docs/a.md#second-part) [dir](docs/)
                [dir readme anchor](docs#docs-home) ![img](img/x.png) [root](/docs/a.md)
                [spaces](<docs/b c.md>) [encoded](docs/b%20c.md) [query](docs/a.md?plain=1)
                [empty fragment](#) [parens](docs/f(1).md)
                """,
            "docs/README.md": "# Docs home\n",
            "docs/a.md": "# A\n## Second part\n",
            "docs/b c.md": "x\n",
            "docs/f(1).md": "x\n",
            "img/x.png": "",
        }), [])

    def test_broken_file_and_anchor(self):
        problems = self.problems({
            "README.md": "# Top\n[a](missing.md) [b](#nope) [c](docs/a.md#nope) [d](docs/a.md#A)\n",
            "docs/a.md": "# A\n",
        })
        self.assertEqual(len(problems), 4, problems)
        self.assertIn("broken link: missing.md", problems[0])
        self.assertIn("broken anchor: #nope", problems[1])
        self.assertIn("in docs/a.md", problems[2])
        self.assertIn("did you mean #a?", problems[3])

    def test_file_names_are_case_sensitive(self):
        self.assertEqual(len(self.problems({"README.md": "[x](docs/readme.md)\n", "docs/README.md": ""})), 1)

    def test_escaping_the_repository_is_reported(self):
        problems = self.problems({"docs/x.md": "[up](../../outside.md)\n"}, rel="docs/x.md")
        self.assertEqual(len(problems), 1)
        self.assertIn("outside the repository", problems[0])

    def test_external_links_and_code_are_ignored(self):
        self.assertEqual(self.problems({
            "README.md": """\
                [web](https://example.com/missing.md) [mail](mailto:a@example.com) [proto](//example.com/x)
                `[code](missing.md)` and ``[double `tick`](missing.md)``

                ```markdown
                [fenced](missing.md)
                ```

                ~~~~
                [tilde](missing.md)
                ~~~~
                <!-- [comment](missing.md) -->
                """,
        }), [])

    def test_reference_links(self):
        problems = self.problems({
            "README.md": """\
                [good][ok] [Collapsed][] [bad][undefined] [missing target][gone]

                [ok]: docs/a.md
                [collapsed]: <docs/a.md#a>
                [gone]: docs/gone.md
                [web]: https://example.com
                """,
            "docs/a.md": "# A\n",
        })
        self.assertEqual(len(problems), 2, problems)
        self.assertTrue(any("undefined link reference: [undefined]" in p for p in problems))
        self.assertTrue(any("broken link: docs/gone.md" in p for p in problems))

    def test_html_attributes(self):
        problems = self.problems({
            "README.md": '<img src="docs/img.png"> <a href="docs/nope.md">x</a> <a href="https://x.org">y</a>\n',
            "docs/img.png": "",
        })
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("docs/nope.md", problems[0])

    def test_line_numbers_survive_masking(self):
        root = self.make_repo({"README.md": "```\ncode line\n```\n`span`\ntext [x](missing.md)\n"})
        problems, _, _ = check_links.check_file(check_links.Repo(root, []), "README.md")
        self.assertEqual([(line, col) for line, col, _ in problems], [(5, 10)])

    def test_anchor_into_non_markdown_is_not_checked(self):
        self.assertEqual(self.problems({"README.md": "[x](a.py#L10)\n", "a.py": ""}), [])


class MainTests(RepoTestCase):
    def run_main(self, root, *extra):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = check_links.main(["--root", root, *extra])
        return code, out.getvalue()

    def test_exit_codes(self):
        ok = self.make_repo({"README.md": "[a](b.md)\n", "b.md": "# B\n"})
        self.assertEqual(self.run_main(ok)[0], 0)
        bad = self.make_repo({"README.md": "[a](c.md)\n"})
        code, output = self.run_main(bad)
        self.assertEqual(code, 1)
        self.assertIn("README.md:1:5: broken link: c.md", output)

    def test_exclude(self):
        root = self.make_repo({"README.md": "ok\n", "vendor/x/README.md": "[a](nope.md)\n"})
        self.assertEqual(self.run_main(root)[0], 1)
        self.assertEqual(self.run_main(root, "--exclude", "vendor")[0], 0)

    @unittest.skipUnless(shutil.which("git"), "git not installed")
    def test_git_ignored_files_are_not_link_targets(self):
        root = self.make_repo({
            ".gitignore": "ignored.md\n",
            "README.md": "[a](ignored.md)\n",
            "ignored.md": "# I\n",
        })
        subprocess.run(["git", "init", "-q", root], check=True)
        code, output = self.run_main(root)
        self.assertEqual(code, 1)
        self.assertIn("(files from git)", output)


if __name__ == "__main__":
    unittest.main()
