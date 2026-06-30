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
    <h1>Posts</h1>
    <p>백엔드 학습 노트와 문제 해결 기록을 모아둔 공간입니다.</p>
  </div>
</section>

<section class="post-controls" aria-label="Post filters">
  <select id="topicFilter" aria-label="주제">
    <option value="all">전체 주제</option>
    <optgroup label="추천 주제">
      {% for topic in topic_paths %}
        <option value="topic:{{ topic.key }}">{{ topic.label }}</option>
      {% endfor %}
    </optgroup>
    <optgroup label="전체 태그">
      {% for tag in sorted_tags %}
        <option value="tag:{{ tag[0] }}">{{ tag[0] }} ({{ tag[1] | size }})</option>
      {% endfor %}
    </optgroup>
  </select>
  <label class="search-box" for="postSearch">
    <span aria-hidden="true">⌕</span>
    <input id="postSearch" type="search" placeholder="제목 또는 요약 검색">
  </label>
  <button class="filter-reset" id="resetFilters" type="button">초기화</button>
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
  const topicFilter = document.querySelector("#topicFilter");
  const resetFiltersButton = document.querySelector("#resetFilters");
  const posts = [...document.querySelectorAll(".post-row")];
  const count = document.querySelector("#visiblePostCount");
  const emptyState = document.querySelector("#emptyState");
  const filterStatus = document.querySelector("#filterStatus");
  const params = new URLSearchParams(window.location.search);
  let activeTag = "";
  let activeRoute = "";

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

  function selectedFilter() {
    const value = topicFilter.value;
    if (value === "all") return { type: "all", key: "", label: "전체 주제" };
    const separator = value.indexOf(":");
    return {
      type: value.slice(0, separator),
      key: value.slice(separator + 1),
      label: topicFilter.selectedOptions[0]?.textContent || value
    };
  }

  function syncQuery() {
    const next = new URLSearchParams();
    const selected = selectedFilter();
    if (searchInput.value.trim()) next.set("q", searchInput.value.trim());
    if (selected.type === "topic") next.set("topic", selected.key);
    if (selected.type === "tag") next.set("tag", selected.key);
    if (activeTag && selected.type !== "tag") next.set("tag", activeTag);
    if (activeRoute) next.set("route", activeRoute);
    const query = next.toString();
    const url = query ? `${window.location.pathname}?${query}` : window.location.pathname;
    window.history.replaceState({}, "", url);
  }

  function applyFilters() {
    const keyword = normalize(searchInput.value);
    const selected = selectedFilter();
    let visible = 0;
    const summary = [];

    posts.forEach((post) => {
      const text = normalize(`${post.dataset.title} ${post.dataset.excerpt}`);
      const tags = parseTags(post.dataset.tags);
      const topics = parseTags(post.dataset.topics);
      const routes = parseTags(post.dataset.routes);
      const matchesKeyword = !keyword || text.includes(keyword);
      const matchesSelected =
        selected.type === "all" ||
        (selected.type === "topic" && topics.includes(selected.key)) ||
        (selected.type === "tag" && tags.includes(selected.key));
      const matchesTag = !activeTag || tags.includes(activeTag);
      const matchesRoute = !activeRoute || routes.includes(activeRoute);
      const show = matchesKeyword && matchesSelected && matchesTag && matchesRoute;

      post.hidden = !show;
      if (show) visible += 1;
    });

    count.textContent = visible;
    emptyState.hidden = visible !== 0;

    if (selected.type !== "all") summary.push(`${selected.type === "tag" ? "태그" : "주제"}: ${selected.label}`);
    if (activeTag && selected.type !== "tag") summary.push(`태그: #${activeTag}`);
    if (activeRoute) summary.push(`경로: ${activeRoute}`);
    if (searchInput.value.trim()) summary.push(`검색: "${searchInput.value.trim()}"`);
    filterStatus.textContent = summary.length ? `현재 필터: ${summary.join(" · ")}` : "전체 글을 보고 있습니다.";

    syncQuery();
  }

  searchInput.addEventListener("input", applyFilters);
  topicFilter.addEventListener("change", applyFilters);
  resetFiltersButton.addEventListener("click", () => {
    searchInput.value = "";
    topicFilter.value = "all";
    activeTag = "";
    activeRoute = "";
    applyFilters();
  });

  if (params.get("q")) searchInput.value = params.get("q");
  if (params.get("topic")) {
    const requestedTopic = params.get("topic");
    if (hasOption(topicFilter, `topic:${requestedTopic}`)) {
      topicFilter.value = `topic:${requestedTopic}`;
    }
  }
  const requestedTag = params.get("tag") || params.get("category") || "";
  if (requestedTag && hasOption(topicFilter, `tag:${requestedTag}`)) {
    topicFilter.value = `tag:${requestedTag}`;
  } else {
    activeTag = requestedTag;
  }
  activeRoute = params.get("route") || "";

  applyFilters();
</script>
