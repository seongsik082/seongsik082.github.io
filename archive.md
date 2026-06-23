---
layout: default
title: Posts
permalink: /posts/
---

<section class="posts-hero">
  <div class="posts-hero-inner">
    <h1>Posts</h1>
    <p>전체 포스트 목록을 살펴보세요.</p>
  </div>
</section>

<section class="post-controls" aria-label="Post filters">
  <select id="categoryFilter" aria-label="카테고리">
    <option value="all">카테고리</option>
    <option value="Backend">Backend</option>
    <option value="Writing">Writing</option>
    <option value="Project">Project</option>
    <option value="Retrospect">Retrospect</option>
  </select>
  <label class="search-box" for="postSearch">
    <span aria-hidden="true">⌕</span>
    <input id="postSearch" type="search" placeholder="검색어">
  </label>
</section>

<section class="post-categories" aria-label="Post tags">
  <button type="button" data-tag="Backend">#Backend</button>
  <button type="button" data-tag="Spring">#Spring</button>
  <button type="button" data-tag="Java">#Java</button>
  <button type="button" data-tag="Database">#Database</button>
  <button type="button" data-tag="API">#API</button>
  <button type="button" data-tag="JPA">#JPA</button>
  <button type="button" data-tag="Redis">#Redis</button>
  <button type="button" data-tag="Docker">#Docker</button>
  <button type="button" data-tag="AWS">#AWS</button>
  <button type="button" data-tag="CI/CD">#CI/CD</button>
  <button type="button" data-tag="Testing">#Testing</button>
  <button type="button" data-tag="Writing">#Writing</button>
  <button type="button" data-tag="Retrospect">#Retrospect</button>
</section>

<section class="post-count">
  총 <span id="visiblePostCount">{{ site.posts | size }}</span>개의 포스트가 있어요
</section>

<section class="archive-list">
  {% for post in site.posts %}
    <article class="post-row" data-title="{{ post.title | escape }}" data-excerpt="{{ post.excerpt | strip_html | escape }}" data-tags="{{ post.tags | join: ',' }}">
      <a href="{{ post.url | relative_url }}">
        <div class="post-row-body">
          <div class="post-category">
            {% for tag in post.tags limit: 2 %}
              <span>{{ tag }}</span>
            {% endfor %}
          </div>
          <h2>{{ post.title }}</h2>
          <p>{{ post.excerpt | strip_html | truncate: 145 }}</p>
        </div>
        <time datetime="{{ post.date | date_to_xmlschema }}">{{ post.date | date: "%Y.%m.%d" }}</time>
      </a>
    </article>
  {% endfor %}
</section>

<script>
  const searchInput = document.querySelector("#postSearch");
  const categoryFilter = document.querySelector("#categoryFilter");
  const tagButtons = [...document.querySelectorAll("[data-tag]")];
  const posts = [...document.querySelectorAll(".post-row")];
  const count = document.querySelector("#visiblePostCount");
  let activeTag = "";

  function normalize(value) {
    return (value || "").toLowerCase();
  }

  function applyFilters() {
    const keyword = normalize(searchInput.value);
    const category = categoryFilter.value;
    let visible = 0;

    posts.forEach((post) => {
      const text = normalize(`${post.dataset.title} ${post.dataset.excerpt}`);
      const tags = post.dataset.tags || "";
      const matchesKeyword = !keyword || text.includes(keyword);
      const matchesCategory = category === "all" || tags.includes(category);
      const matchesTag = !activeTag || tags.includes(activeTag);
      const show = matchesKeyword && matchesCategory && matchesTag;

      post.hidden = !show;
      if (show) visible += 1;
    });

    count.textContent = visible;
  }

  searchInput.addEventListener("input", applyFilters);
  categoryFilter.addEventListener("change", applyFilters);
  tagButtons.forEach((button) => {
    button.addEventListener("click", () => {
      activeTag = activeTag === button.dataset.tag ? "" : button.dataset.tag;
      tagButtons.forEach((item) => item.classList.toggle("is-active", item.dataset.tag === activeTag));
      applyFilters();
    });
  });
</script>
