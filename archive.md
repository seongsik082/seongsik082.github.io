---
layout: default
title: Posts
permalink: /posts/
---

<section class="posts-hero">
  <div class="posts-hero-inner">
    <p class="eyebrow">Archive</p>
    <h1>백엔드 개발 주제별로 글을 탐색해보세요.</h1>
    <p>Java, Spring, Database, REST API, 운영 이슈를 태그와 검색으로 빠르게 찾을 수 있습니다.</p>
  </div>
</section>

<section class="post-controls" aria-label="Post filters">
  <select id="categoryFilter" aria-label="카테고리">
    <option value="all">전체 태그</option>
    <option value="Backend">Backend</option>
    <option value="Java">Java</option>
    <option value="Spring">Spring</option>
    <option value="JPA">JPA</option>
    <option value="Database">Database</option>
    <option value="REST API">REST API</option>
    <option value="API">API</option>
    <option value="HTTP">HTTP</option>
    <option value="Distributed Systems">Distributed Systems</option>
    <option value="Observability">Observability</option>
    <option value="Performance">Performance</option>
    <option value="Kubernetes">Kubernetes</option>
    <option value="AWS">AWS</option>
    <option value="Docker">Docker</option>
    <option value="Redis">Redis</option>
    <option value="Testing">Testing</option>
  </select>
  <label class="search-box" for="postSearch">
    <span aria-hidden="true">⌕</span>
    <input id="postSearch" type="search" placeholder="제목 또는 요약 검색">
  </label>
</section>

<section class="post-categories" aria-label="Post tags">
  {% assign sorted_tags = site.tags | sort %}
  {% for tag in sorted_tags %}
    <button type="button" data-tag="{{ tag[0] }}">#{{ tag[0] }}</button>
  {% endfor %}
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

<p class="empty-state" id="emptyState" hidden>조건에 맞는 글이 없습니다. 다른 태그나 검색어로 다시 찾아보세요.</p>

<script>
  const searchInput = document.querySelector("#postSearch");
  const categoryFilter = document.querySelector("#categoryFilter");
  const tagButtons = [...document.querySelectorAll("[data-tag]")];
  const posts = [...document.querySelectorAll(".post-row")];
  const count = document.querySelector("#visiblePostCount");
  const emptyState = document.querySelector("#emptyState");
  const params = new URLSearchParams(window.location.search);
  let activeTag = "";

  function normalize(value) {
    return (value || "").toLowerCase();
  }

  function parseTags(raw) {
    return (raw || "")
      .split(",")
      .map((tag) => tag.trim())
      .filter(Boolean);
  }

  function syncQuery() {
    const next = new URLSearchParams();
    if (searchInput.value.trim()) next.set("q", searchInput.value.trim());
    if (categoryFilter.value !== "all") next.set("category", categoryFilter.value);
    if (activeTag) next.set("tag", activeTag);
    const query = next.toString();
    const url = query ? `${window.location.pathname}?${query}` : window.location.pathname;
    window.history.replaceState({}, "", url);
  }

  function applyFilters() {
    const keyword = normalize(searchInput.value);
    const category = categoryFilter.value;
    let visible = 0;

    posts.forEach((post) => {
      const text = normalize(`${post.dataset.title} ${post.dataset.excerpt}`);
      const tags = parseTags(post.dataset.tags);
      const matchesKeyword = !keyword || text.includes(keyword);
      const matchesCategory = category === "all" || tags.includes(category);
      const matchesTag = !activeTag || tags.includes(activeTag);
      const show = matchesKeyword && matchesCategory && matchesTag;

      post.hidden = !show;
      if (show) visible += 1;
    });

    count.textContent = visible;
    emptyState.hidden = visible !== 0;
    syncQuery();
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

  if (params.get("q")) searchInput.value = params.get("q");
  if (params.get("category")) categoryFilter.value = params.get("category");
  if (params.get("tag")) {
    activeTag = params.get("tag");
    tagButtons.forEach((item) => item.classList.toggle("is-active", item.dataset.tag === activeTag));
  }

  applyFilters();
</script>
