# Mobile Post Reading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the mobile post-content/sidebar overlap and deliver a compact, accessible mobile reading experience without changing the desktop visual direction.

**Architecture:** Split the post table of contents from the supporting sidebar so the three grid items have an explicit semantic order: TOC, content, support links. Keep the existing Jekyll/Liquid rendering and vanilla JavaScript, then use a one-column mobile grid with automatic rows and a two-column desktop grid.

**Tech Stack:** GitHub Pages, Jekyll/Liquid, HTML, CSS, vanilla JavaScript, Python standard-library regression tests

## Global Constraints

- Mobile breakpoint: 720px and below; desktop layout starts at 721px.
- Test widths: 375px, 390px, 430px, 720px, 721px, 768px, and 1024px or wider.
- Mobile body text: 16px with 1.75 line height.
- Mobile post title: 30px; `h2`: 24px; `h3`: 20px.
- Mobile content side padding: 20px.
- Interactive target size: at least 44px.
- Keep the existing 1120px desktop post container and two-column reading layout.
- Add no framework or external JavaScript dependency.
- Do not include homepage, projects-page, image-optimization, or SEO redesign work.

---

## File Map

- `tests/test_mobile_post_layout.py`: Static regression tests for template order, mobile grid placement, header behavior, overflow protection, theme semantics, and focus styles.
- `_layouts/post.html`: Separate the table of contents from the supporting sidebar while preserving Liquid topic and troubleshooting logic.
- `_layouts/default.html`: Populate the new TOC element, initialize its mobile state, and keep theme accessibility state synchronized.
- `_includes/header.html`: Mark the GitHub navigation link for mobile-only hiding and provide initial theme-button state.
- `assets/css/style.css`: Define desktop/mobile grid placement, compact mobile header, reading typography, overflow protection, touch targets, focus states, and dark-mode body color.

---

### Task 1: Lock the Mobile Overlap Regression

**Files:**
- Create: `tests/test_mobile_post_layout.py`
- Test: `tests/test_mobile_post_layout.py`

**Interfaces:**
- Consumes: `_layouts/post.html` classes and the final `@media (max-width: 720px)` block in `assets/css/style.css`
- Produces: `MobilePostLayoutTests` assertions that later tasks must satisfy

- [ ] **Step 1: Create the failing source-level regression test**

```python
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
        toc = POST_LAYOUT.index('class="post-toc"')
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
```

- [ ] **Step 2: Run the regression test and confirm the current code fails**

Run:

```powershell
& 'C:\Users\김성식\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' -m unittest tests.test_mobile_post_layout -v
```

Expected: FAIL because `_layouts/post.html` has no `.post-toc` element and the mobile CSS does not reset all three grid rows.

- [ ] **Step 3: Commit the failing regression test**

```powershell
git add tests/test_mobile_post_layout.py
git commit -m "test: reproduce mobile post overlap"
```

---

### Task 2: Separate the TOC and Fix the Grid Flow

**Files:**
- Modify: `_layouts/post.html:51-85`
- Modify: `_layouts/default.html:89-111`
- Modify: `assets/css/style.css:835-875`
- Modify: `assets/css/style.css:1136-1144`
- Test: `tests/test_mobile_post_layout.py`

**Interfaces:**
- Consumes: `css_rule()` and `mobile_css()` from Task 1
- Produces: `.post-toc`, `.post-content`, and `.post-sidebar` as sibling grid items; `[data-post-toc-list]` as the JavaScript population target

- [ ] **Step 1: Refactor the post template into three ordered grid items**

Replace the complete `.post-layout` block with:

```html
<div class="post-layout">
  <details class="post-toc post-side-card" open>
    <summary>이 글에서 다루는 내용</summary>
    <nav data-post-toc-list aria-label="글 목차"></nav>
  </details>

  <div class="content post-content">
    {{ content }}
  </div>

  <aside class="post-sidebar" aria-label="관련 탐색">
    {% if matched_route_count > 0 %}
      <div class="post-side-card">
        <p class="section-label">도움이 되는 상황</p>
        {% for route in troubleshooting_paths %}
          {% if route.slugs contains page.slug %}
            <a class="sidebar-link" href="{{ '/troubleshooting/#' | append: route.key | relative_url }}">{{ route.title }}</a>
          {% endif %}
        {% endfor %}
        <a class="sidebar-link" href="{{ '/troubleshooting/' | relative_url }}">전체 troubleshooting 경로 보기</a>
      </div>
    {% endif %}
    {% if primary_tag != "" %}
      <div class="post-side-card">
        <p class="section-label">같은 주제 더 보기</p>
        <a class="sidebar-link" href="{{ '/posts/' | relative_url }}?tag={{ primary_tag | url_encode }}">#{{ primary_tag }} 글 모아보기</a>
        <a class="sidebar-link" href="{{ '/topics/' | relative_url }}">주제 허브에서 이어서 보기</a>
        <a class="sidebar-link" href="{{ '/start-here/' | relative_url }}">처음 읽기 가이드 보기</a>
      </div>
    {% endif %}
    <div class="post-side-card">
      <p class="section-label">탐색</p>
      <a class="sidebar-link" href="{{ '/posts/' | relative_url }}">전체 글 목록 보기</a>
      <a class="sidebar-link" href="{{ '/about/' | relative_url }}">블로그 소개 보기</a>
    </div>
  </aside>
</div>
```

Delete the old `<div class="post-side-card" data-post-toc>` from inside `.post-sidebar` and delete the old duplicate `.post-content` block at the bottom of `.post-layout`.

- [ ] **Step 2: Update TOC generation for the new target and mobile default**

Replace the existing TOC script block in `_layouts/default.html` with:

```javascript
const toc = document.querySelector(".post-toc");
const tocList = document.querySelector("[data-post-toc-list]");
const articleContent = document.querySelector(".post-content");

if (toc && tocList && articleContent) {
  const headings = [...articleContent.querySelectorAll("h2")];

  if (headings.length === 0) {
    toc.hidden = true;
  } else {
    const list = document.createElement("ul");
    headings.forEach((heading, index) => {
      if (!heading.id) heading.id = `section-${index + 1}`;
      const item = document.createElement("li");
      const link = document.createElement("a");
      link.href = `#${heading.id}`;
      link.textContent = heading.textContent.trim();
      item.appendChild(link);
      list.appendChild(item);
    });
    tocList.appendChild(list);

    if (window.matchMedia("(max-width: 720px)").matches) {
      toc.removeAttribute("open");
    }
  }
}
```

- [ ] **Step 3: Define explicit desktop grid areas**

Replace the current post-layout placement rules with:

```css
.post-layout {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 260px;
  grid-template-areas:
    "content toc"
    "content sidebar";
  gap: 14px 32px;
  align-items: start;
}

.post-toc {
  grid-area: toc;
  position: sticky;
  top: 94px;
}

.post-content {
  grid-area: content;
  min-width: 0;
}

.post-sidebar {
  grid-area: sidebar;
  display: grid;
  gap: 14px;
}
```

Add TOC summary/list rules:

```css
.post-toc summary {
  color: var(--accent);
  cursor: pointer;
  font-size: 13px;
  font-weight: 800;
}

.post-toc nav {
  margin-top: 12px;
}
```

- [ ] **Step 4: Define a one-column mobile flow with automatic placement**

Inside `@media (max-width: 720px)`, replace the existing `.post-layout` and `.post-sidebar` overrides with:

```css
.post-layout {
  grid-template-columns: 1fr;
  grid-template-areas:
    "toc"
    "content"
    "sidebar";
  gap: 24px;
}

.post-toc {
  grid-column: auto;
  grid-row: auto;
  position: static;
}

.post-content {
  grid-column: auto;
  grid-row: auto;
}

.post-sidebar {
  grid-column: auto;
  grid-row: auto;
}
```

- [ ] **Step 5: Run the regression test and confirm it passes**

Run:

```powershell
& 'C:\Users\김성식\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' -m unittest tests.test_mobile_post_layout -v
```

Expected: 2 tests PASS.

- [ ] **Step 6: Commit the layout fix**

```powershell
git add _layouts/post.html _layouts/default.html assets/css/style.css
git commit -m "fix: repair mobile post reading layout"
```

---

### Task 3: Add Mobile Reading and Accessibility Regressions

**Files:**
- Modify: `tests/test_mobile_post_layout.py`
- Test: `tests/test_mobile_post_layout.py`

**Interfaces:**
- Consumes: `CSS`, `POST_LAYOUT`, `css_rule()`, and `mobile_css()` from Task 1
- Produces: source-level acceptance tests for header, typography, overflow, focus, touch size, theme state, and TOC semantics

- [ ] **Step 1: Load the shared layout and header fixtures**

Add:

```python
DEFAULT_LAYOUT = (ROOT / "_layouts/default.html").read_text(encoding="utf-8")
HEADER = (ROOT / "_includes/header.html").read_text(encoding="utf-8")
```

- [ ] **Step 2: Add failing acceptance tests**

Add these methods to `MobilePostLayoutTests`:

```python
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
    self.assertIn("color: var(--muted)", css_rule(CSS, ".content p,\n.content li,\n.project-card p,\n.project-card dd"))

def test_theme_button_exposes_and_updates_state(self):
    self.assertIn('aria-pressed="false"', HEADER)
    self.assertIn('setAttribute("aria-pressed"', DEFAULT_LAYOUT)
    self.assertIn('setAttribute("aria-label"', DEFAULT_LAYOUT)
```

- [ ] **Step 3: Run the test and confirm the new assertions fail**

Run:

```powershell
& 'C:\Users\김성식\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' -m unittest tests.test_mobile_post_layout -v
```

Expected: the 2 layout tests PASS and the new header, typography, focus, dark-mode, and theme-state tests FAIL.

- [ ] **Step 4: Commit the failing acceptance tests**

```powershell
git add tests/test_mobile_post_layout.py
git commit -m "test: define mobile reading acceptance criteria"
```

---

### Task 4: Implement Mobile Reading and Accessibility Polish

**Files:**
- Modify: `_includes/header.html:6-10`
- Modify: `_layouts/default.html:79-88`
- Modify: `assets/css/style.css:31-125`
- Modify: `assets/css/style.css:890-920`
- Modify: `assets/css/style.css:1088-1159`
- Test: `tests/test_mobile_post_layout.py`

**Interfaces:**
- Consumes: acceptance tests from Task 3
- Produces: `.site-nav-github`, `syncThemeButton()`, compact mobile header rules, fixed reading typography, accessible focus/touch states, and semantic dark-mode colors

- [ ] **Step 1: Add header hooks and initial theme state**

Change the GitHub link and theme button in `_includes/header.html` to:

```html
<a class="site-nav-github" href="https://github.com/{{ site.author.github }}">GitHub</a>
<button class="theme-toggle" type="button" aria-label="다크 모드 사용" aria-pressed="false">◐</button>
```

- [ ] **Step 2: Synchronize visual and accessible theme state**

Replace the theme block in `_layouts/default.html` with:

```javascript
const themeToggle = document.querySelector(".theme-toggle");
const savedTheme = localStorage.getItem("theme");
const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
const useDarkTheme = savedTheme ? savedTheme === "dark" : prefersDark;

document.documentElement.classList.toggle("dark", useDarkTheme);

function syncThemeButton() {
  if (!themeToggle) return;
  const isDark = document.documentElement.classList.contains("dark");
  themeToggle.setAttribute("aria-pressed", String(isDark));
  themeToggle.setAttribute("aria-label", isDark ? "라이트 모드 사용" : "다크 모드 사용");
}

syncThemeButton();

themeToggle?.addEventListener("click", () => {
  document.documentElement.classList.toggle("dark");
  const isDark = document.documentElement.classList.contains("dark");
  localStorage.setItem("theme", isDark ? "dark" : "light");
  syncThemeButton();
});
```

- [ ] **Step 3: Add global focus, touch, dark-mode, and overflow rules**

Add the focus and overflow rules below, and replace the existing `.theme-toggle` and fixed content-color declarations with the exact declarations shown:

```css
a:focus-visible,
button:focus-visible,
select:focus-visible,
input:focus-visible,
summary:focus-visible {
  outline: 3px solid var(--accent);
  outline-offset: 3px;
}

.theme-toggle {
  min-width: 44px;
  min-height: 44px;
}

.content p,
.content li,
.project-card p,
.project-card dd {
  color: var(--muted);
}

.content code {
  color: var(--inline-code-text);
}

.post-content,
.post-content p,
.post-content li,
.post-content a,
.post-content code {
  overflow-wrap: anywhere;
}
```

Keep `.content pre { overflow-x: auto; }` so code scrolls internally.

Add `--inline-code-text: #245ba8;` to `:root` and `--inline-code-text: #dbe7ff;` to `:root.dark`.

- [ ] **Step 4: Implement the compact mobile header**

Inside `@media (max-width: 720px)`, update:

```css
.site-header {
  min-height: 56px;
  padding: 6px 20px;
  flex-direction: row;
  gap: 12px;
}

.site-logo small {
  display: none;
}

.site-nav-github {
  display: none;
}

.site-nav {
  margin-left: auto;
  gap: 8px;
}

.site-nav a,
.theme-toggle {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-height: 44px;
}
```

- [ ] **Step 5: Implement mobile reading typography and code sizing**

Inside `@media (max-width: 720px)`, add:

```css
.post-content {
  font-size: 16px;
  line-height: 1.75;
}

.post-header h1 {
  font-size: 30px;
}

.post-content h2 {
  margin-top: 36px;
  font-size: 24px;
}

.post-content h3 {
  margin-top: 28px;
  font-size: 20px;
}

.content pre {
  max-width: 100%;
  overflow-x: auto;
  padding: 16px;
  font-size: 14px;
}

.post-tag-list a,
.post-nav-card,
.related-post-card {
  min-height: 44px;
}
```

- [ ] **Step 6: Run all mobile-post tests**

Run:

```powershell
& 'C:\Users\김성식\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' -m unittest tests.test_mobile_post_layout -v
```

Expected: all tests PASS.

- [ ] **Step 7: Commit the reading polish**

```powershell
git add _includes/header.html _layouts/default.html assets/css/style.css
git commit -m "feat: improve mobile post reading experience"
```

---

### Task 5: Final Verification

**Files:**
- Verify: `tests/test_mobile_post_layout.py`
- Verify: `_layouts/post.html`
- Verify: `_layouts/default.html`
- Verify: `_includes/header.html`
- Verify: `assets/css/style.css`

**Interfaces:**
- Consumes: all implementation from Tasks 1-4
- Produces: a clean worktree and recorded verification evidence

- [ ] **Step 1: Run the complete source-level regression suite**

Run:

```powershell
& 'C:\Users\김성식\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' -m unittest discover -s tests -v
```

Expected: all tests PASS.

- [ ] **Step 2: Check whitespace and accidental edits**

Run:

```powershell
git diff --check
git status --short
git diff --stat HEAD~4
```

Expected: no whitespace errors; only the planned test, template, layout, header, CSS, and design/plan documents appear.

- [ ] **Step 3: Verify the unchanged content system**

Run when Ruby/Bundler is available:

```powershell
ruby scripts/check_posts.rb
bundle exec jekyll build
```

Expected: the post checker reports success and Jekyll finishes without an error. In the current Windows workspace Ruby/Bundler is unavailable, so record that limitation rather than claiming these two commands passed.

- [ ] **Step 4: Review the final diff against the approved scope**

Run:

```powershell
git diff HEAD~4 -- _layouts/post.html _layouts/default.html _includes/header.html assets/css/style.css tests/test_mobile_post_layout.py
```

Expected: no homepage, projects-page, post-content, image, dependency, or SEO changes.

- [ ] **Step 5: Commit any verification-only corrections**

If verification found and corrected a scoped issue:

```powershell
git add tests/test_mobile_post_layout.py _layouts/post.html _layouts/default.html _includes/header.html assets/css/style.css
git commit -m "test: finalize mobile post verification"
```

If no corrections were necessary, do not create an empty commit.
