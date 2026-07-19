from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
CSS = (ROOT / "assets/css/style.css").read_text(encoding="utf-8")
POST_LAYOUT = (ROOT / "_layouts/post.html").read_text(encoding="utf-8")
DEFAULT_LAYOUT = (ROOT / "_layouts/default.html").read_text(encoding="utf-8")
HEADER = (ROOT / "_includes/header.html").read_text(encoding="utf-8")


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

    def test_toc_uses_native_disclosure_semantics(self):
        self.assertIn('<details class="post-toc post-side-card" open>', POST_LAYOUT)
        self.assertIn("<summary>이 글에서 다루는 내용</summary>", POST_LAYOUT)
        self.assertIn('aria-label="글 목차"', POST_LAYOUT)

    def test_mobile_reading_type_and_overflow_are_explicit(self):
        source = mobile_css()
        post_content = css_rule(source, ".post-content")
        post_title = css_rule(source, ".post-header h1")
        code = css_rule(source, ".content pre")
        self.assertIn("font-size: 16px", post_content)
        self.assertIn("line-height: 1.75", post_content)
        self.assertIn("font-size: 30px", post_title)
        self.assertIn("overflow-x: auto", code)
        self.assertIn("overflow-wrap: anywhere", CSS)

    def test_code_blocks_keep_preformatted_scrolling_style(self):
        code = css_rule(CSS, ".content pre code")
        self.assertIn("background: transparent", code)
        self.assertIn("color: inherit", code)
        self.assertIn("overflow-wrap: normal", code)
        self.assertIn("padding: 0", code)

    def test_mobile_toc_controls_have_touch_targets(self):
        source = mobile_css()
        for selector in (".post-toc summary", ".post-toc a"):
            rule = css_rule(source, selector)
            self.assertIn("min-height: 44px", rule)
            self.assertIn("display: flex", rule)

    def test_mobile_header_is_single_row_and_keeps_core_links(self):
        source = mobile_css()
        header_rule = css_rule(source, ".site-header")
        self.assertIn("min-height: 56px", header_rule)
        self.assertIn("flex-direction: row", header_rule)
        self.assertIn('class="site-nav-github"', HEADER)
        self.assertIn(".site-nav-github", source)
        self.assertIn("display: none", css_rule(source, ".site-nav-github"))

    def test_focus_touch_and_dark_mode_rules_are_present(self):
        self.assertIn(":focus-visible", CSS)
        self.assertIn("min-width: 44px", css_rule(CSS, ".theme-toggle"))
        self.assertIn("min-height: 44px", css_rule(CSS, ".theme-toggle"))
        content_selector = (
            ".content p,\n"
            ".content li,\n"
            ".project-card p,\n"
            ".project-card dd"
        )
        self.assertIn("color: var(--muted)", css_rule(CSS, content_selector))

    def test_theme_button_exposes_and_updates_state(self):
        self.assertIn('aria-pressed="false"', HEADER)
        self.assertIn('setAttribute("aria-pressed"', DEFAULT_LAYOUT)
        self.assertIn('setAttribute("aria-label"', DEFAULT_LAYOUT)


if __name__ == "__main__":
    unittest.main()
