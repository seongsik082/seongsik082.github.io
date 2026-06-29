---
layout: default
title: Posts
permalink: /posts/
---

{% assign sorted_tags = site.tags | sort %}

<section class="posts-hero">
  <div class="posts-hero-inner">
    <p class="eyebrow">Archive</p>
    <h1>백엔드 개발 주제별로 글을 탐색해보세요.</h1>
    <p>Java, Spring, Database, REST API, 운영 이슈를 태그와 검색으로 빠르게 찾을 수 있습니다.</p>
  </div>
</section>

<section class="archive-guides" aria-label="Quick routes">
  <a class="archive-guide-card" href="{{ '/start-here/' | relative_url }}">
    <strong>처음 읽기</strong>
    <span>읽는 순서를 먼저 보고 싶다면 여기서 시작합니다.</span>
  </a>
  <a class="archive-guide-card" href="{{ '/topics/' | relative_url }}">
    <strong>주제 허브</strong>
    <span>Java, Spring, API, Database, 운영 주제를 영역별로 훑어볼 수 있습니다.</span>
  </a>
  <a class="archive-guide-card" href="{{ '/posts/?tag=Backend' | relative_url }}">
    <strong>전체 백엔드 글</strong>
    <span>필터 없이 최신 글부터 빠르게 훑고 싶을 때 사용하면 됩니다.</span>
  </a>
</section>

<section class="post-controls" aria-label="Post filters">
  <select id="categoryFilter" aria-label="카테고리">
    <option value="all">전체 태그</option>
    {% for tag in sorted_tags %}
      <option value="{{ tag[0] }}">{{ tag[0] }} ({{ tag[1] | size }})</option>
    {% endfor %}
  </select>
  <label class="search-box" for="postSearch">
    <span aria-hidden="true">⌕</span>
    <input id="postSearch" type="search" placeholder="제목 또는 요약 검색">
  </label>
  <button class="filter-reset" id="resetFilters" type="button">초기화</button>
</section>

<p class="filter-note">카테고리는 전체 글을 빠르게 좁히는 용도이고, 아래 태그 버튼은 세부 주제를 바로 고를 때 유용합니다.</p>

<section class="post-categories" aria-label="Post tags">
  {% for tag in sorted_tags %}
    <button type="button" data-tag="{{ tag[0] }}">#{{ tag[0] }}</button>
  {% endfor %}
</section>

<section class="post-count">
  총 <span id="visiblePostCount">{{ site.posts | size }}</span>개의 포스트가 있어요
</section>

<p class="filter-status" id="filterStatus" aria-live="polite">전체 글을 보고 있습니다.</p>

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
  const resetFiltersButton = document.querySelector("#resetFilters");
  const tagButtons = [...document.querySelectorAll("[data-tag]")];
  const posts = [...document.querySelectorAll(".post-row")];
  const count = document.querySelector("#visiblePostCount");
  const emptyState = document.querySelector("#emptyState");
  const filterStatus = document.querySelector("#filterStatus");
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

  function hasOption(select, value) {
    return [...select.options].some((option) => option.value === value);
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
    const summary = [];

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

    if (category !== "all") summary.push(`카테고리: ${category}`);
    if (activeTag) summary.push(`태그: #${activeTag}`);
    if (searchInput.value.trim()) summary.push(`검색: "${searchInput.value.trim()}"`);
    filterStatus.textContent = summary.length ? `현재 필터: ${summary.join(" · ")}` : "전체 글을 보고 있습니다.";

    syncQuery();
  }

  searchInput.addEventListener("input", applyFilters);
  categoryFilter.addEventListener("change", applyFilters);
  resetFiltersButton.addEventListener("click", () => {
    searchInput.value = "";
    categoryFilter.value = "all";
    activeTag = "";
    tagButtons.forEach((item) => item.classList.remove("is-active"));
    applyFilters();
  });
  tagButtons.forEach((button) => {
    button.addEventListener("click", () => {
      activeTag = activeTag === button.dataset.tag ? "" : button.dataset.tag;
      tagButtons.forEach((item) => item.classList.toggle("is-active", item.dataset.tag === activeTag));
      applyFilters();
    });
  });

  if (params.get("q")) searchInput.value = params.get("q");
  if (params.get("category") && hasOption(categoryFilter, params.get("category"))) {
    categoryFilter.value = params.get("category");
  }
  if (params.get("tag")) {
    const requestedTag = params.get("tag");
    if (tagButtons.some((item) => item.dataset.tag === requestedTag)) {
      activeTag = requestedTag;
      tagButtons.forEach((item) => item.classList.toggle("is-active", item.dataset.tag === activeTag));
    }
  }

  applyFilters();
</script>
