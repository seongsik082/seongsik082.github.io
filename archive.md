---
layout: default
title: Posts
permalink: /posts/
---

{% assign sorted_tags = site.tags | sort %}
{% assign topic_paths = site.data.topic_paths %}
{% assign troubleshooting_paths = site.data.troubleshooting_paths %}

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

<section class="archive-guides" aria-label="Troubleshooting routes">
  {% for route in troubleshooting_paths %}
    <a class="archive-guide-card" href="{{ '/posts/' | relative_url }}?route={{ route.key }}">
      <strong>{{ route.label }}</strong>
      <span>{{ route.title }}</span>
    </a>
  {% endfor %}
</section>

<section class="topic-shortcuts" aria-label="Main topics">
  {% for topic in topic_paths %}
    <button type="button" data-topic-filter="{{ topic.key }}" data-topic-label="{{ topic.label }}">{{ topic.label }}</button>
  {% endfor %}
</section>

<section class="topic-shortcuts route-shortcuts" aria-label="Troubleshooting filters">
  {% for route in troubleshooting_paths %}
    <button type="button" data-route-filter="{{ route.key }}" data-route-label="{{ route.label }}">{{ route.label }}</button>
  {% endfor %}
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

<p class="filter-note">주제 버튼은 여러 태그를 묶은 읽기 경로이고, 카테고리와 태그는 더 세부적으로 좁힐 때 유용합니다.</p>

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
    {% capture topic_keys %}{% for topic in topic_paths %}{% assign matches_topic = false %}{% for tag in topic.tags %}{% if post.tags contains tag %}{% assign matches_topic = true %}{% break %}{% endif %}{% endfor %}{% if matches_topic %}{{ topic.key }}|{% endif %}{% endfor %}{% endcapture %}
    {% capture route_keys %}{% for route in troubleshooting_paths %}{% if route.slugs contains post.slug %}{{ route.key }}|{% endif %}{% endfor %}{% endcapture %}
    <article class="post-row" data-title="{{ post.title | escape }}" data-excerpt="{{ post.excerpt | strip_html | escape }}" data-tags="{{ post.tags | join: ',' }}" data-topics="{{ topic_keys | strip }}" data-routes="{{ route_keys | strip }}">
      <a href="{{ post.url | relative_url }}">
        <div class="post-row-body">
          <div class="post-category">
            {% for tag in post.tags limit: 2 %}
              <span>{{ tag }}</span>
            {% endfor %}
          </div>
          {% if route_keys != blank %}
            <div class="route-chip-list in-row">
              {% for route in troubleshooting_paths %}
                {% if route.slugs contains post.slug %}
                  <span>{{ route.label }}</span>
                {% endif %}
              {% endfor %}
            </div>
          {% endif %}
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
  const topicButtons = [...document.querySelectorAll("[data-topic-filter]")];
  const routeButtons = [...document.querySelectorAll("[data-route-filter]")];
  const tagButtons = [...document.querySelectorAll("[data-tag]")];
  const posts = [...document.querySelectorAll(".post-row")];
  const count = document.querySelector("#visiblePostCount");
  const emptyState = document.querySelector("#emptyState");
  const filterStatus = document.querySelector("#filterStatus");
  const params = new URLSearchParams(window.location.search);
  let activeTopic = "";
  let activeRoute = "";
  let activeTag = "";

  function normalize(value) {
    return (value || "").toLowerCase();
  }

  function parseTags(raw) {
    return (raw || "")
      .split(/[,|]/)
      .map((tag) => tag.trim())
      .filter(Boolean);
  }

  function hasOption(select, value) {
    return [...select.options].some((option) => option.value === value);
  }

  function syncQuery() {
    const next = new URLSearchParams();
    if (searchInput.value.trim()) next.set("q", searchInput.value.trim());
    if (activeTopic) next.set("topic", activeTopic);
    if (activeRoute) next.set("route", activeRoute);
    if (categoryFilter.value !== "all") next.set("category", categoryFilter.value);
    if (activeTag) next.set("tag", activeTag);
    const query = next.toString();
    const url = query ? `${window.location.pathname}?${query}` : window.location.pathname;
    window.history.replaceState({}, "", url);
  }

  function applyFilters() {
    const keyword = normalize(searchInput.value);
    const category = categoryFilter.value;
    const activeTopicButton = topicButtons.find((item) => item.dataset.topicFilter === activeTopic);
    const activeRouteButton = routeButtons.find((item) => item.dataset.routeFilter === activeRoute);
    let visible = 0;
    const summary = [];

    posts.forEach((post) => {
      const text = normalize(`${post.dataset.title} ${post.dataset.excerpt}`);
      const tags = parseTags(post.dataset.tags);
      const topics = parseTags(post.dataset.topics);
      const routes = parseTags(post.dataset.routes);
      const matchesKeyword = !keyword || text.includes(keyword);
      const matchesTopic = !activeTopic || topics.includes(activeTopic);
      const matchesRoute = !activeRoute || routes.includes(activeRoute);
      const matchesCategory = category === "all" || tags.includes(category);
      const matchesTag = !activeTag || tags.includes(activeTag);
      const show = matchesKeyword && matchesTopic && matchesRoute && matchesCategory && matchesTag;

      post.hidden = !show;
      if (show) visible += 1;
    });

    count.textContent = visible;
    emptyState.hidden = visible !== 0;

    if (activeTopic) summary.push(`주제: ${activeTopicButton?.dataset.topicLabel || activeTopic}`);
    if (activeRoute) summary.push(`증상: ${activeRouteButton?.dataset.routeLabel || activeRoute}`);
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
    activeTopic = "";
    activeRoute = "";
    activeTag = "";
    topicButtons.forEach((item) => item.classList.remove("is-active"));
    routeButtons.forEach((item) => item.classList.remove("is-active"));
    tagButtons.forEach((item) => item.classList.remove("is-active"));
    applyFilters();
  });
  topicButtons.forEach((button) => {
    button.addEventListener("click", () => {
      activeTopic = activeTopic === button.dataset.topicFilter ? "" : button.dataset.topicFilter;
      topicButtons.forEach((item) => item.classList.toggle("is-active", item.dataset.topicFilter === activeTopic));
      applyFilters();
    });
  });
  routeButtons.forEach((button) => {
    button.addEventListener("click", () => {
      activeRoute = activeRoute === button.dataset.routeFilter ? "" : button.dataset.routeFilter;
      routeButtons.forEach((item) => item.classList.toggle("is-active", item.dataset.routeFilter === activeRoute));
      applyFilters();
    });
  });
  tagButtons.forEach((button) => {
    button.addEventListener("click", () => {
      activeTag = activeTag === button.dataset.tag ? "" : button.dataset.tag;
      tagButtons.forEach((item) => item.classList.toggle("is-active", item.dataset.tag === activeTag));
      applyFilters();
    });
  });

  if (params.get("q")) searchInput.value = params.get("q");
  if (params.get("topic")) {
    const requestedTopic = params.get("topic");
    if (topicButtons.some((item) => item.dataset.topicFilter === requestedTopic)) {
      activeTopic = requestedTopic;
      topicButtons.forEach((item) => item.classList.toggle("is-active", item.dataset.topicFilter === activeTopic));
    }
  }
  if (params.get("route")) {
    const requestedRoute = params.get("route");
    if (routeButtons.some((item) => item.dataset.routeFilter === requestedRoute)) {
      activeRoute = requestedRoute;
      routeButtons.forEach((item) => item.classList.toggle("is-active", item.dataset.routeFilter === activeRoute));
    }
  }
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
