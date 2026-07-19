from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
CSS = (ROOT / "assets/css/style.css").read_text(encoding="utf-8")
POST_LAYOUT = (ROOT / "_layouts/post.html").read_text(encoding="utf-8")


def css_rule(source: str, selector: str) -> str:
    match = re.search(re.escape(selector) + r"\s*\{(?P<body>[^}]*)\}", source)
    if not match:
        raise AssertionError(f"Missing CSS rule for {selector}")
    return match.group("body")


def mobile_css() -> str:
    marker = "@media (max-width: 720px)"
    if marker not in CSS:
        raise AssertionError("Missing 720px mobile breakpoint")
    return CSS.split(marker, 1)[1]


class MobilePostLayoutTests(unittest.TestCase):
    def test_template_order_is_toc_content_support(self):
        toc_match = re.search(r'class="[^"]*\bpost-toc\b[^"]*"', POST_LAYOUT)
        self.assertIsNotNone(toc_match)
        toc = toc_match.start()
        content = POST_LAYOUT.index('class="content post-content"')
        sidebar = POST_LAYOUT.index('class="post-sidebar"')
        self.assertLess(toc, content)
        self.assertLess(content, sidebar)

    def test_mobile_grid_items_use_automatic_rows(self):
        source = mobile_css()
        for selector in (".post-toc", ".post-content", ".post-sidebar"):
            rule = css_rule(source, selector)
            self.assertIn("grid-column: auto", rule)
            self.assertIn("grid-row: auto", rule)


if __name__ == "__main__":
    unittest.main()
