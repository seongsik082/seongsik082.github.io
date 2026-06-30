---
layout: default
title: Posts
permalink: /posts/
---

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
    {% for topic in topic_paths %}
      <option value="{{ topic.key }}">{{ topic.label }}</option>
    {% endfor %}
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

  function syncQuery() {
    const next = new URLSearchParams();
    if (searchInput.value.trim()) next.set("q", searchInput.value.trim());
    if (topicFilter.value !== "all") next.set("topic", topicFilter.value);
    if (activeTag) next.set("tag", activeTag);
    if (activeRoute) next.set("route", activeRoute);
    const query = next.toString();
    const url = query ? `${window.location.pathname}?${query}` : window.location.pathname;
    window.history.replaceState({}, "", url);
  }

  function applyFilters() {
    const keyword = normalize(searchInput.value);
    const topic = topicFilter.value;
    const activeTopicLabel = topicFilter.selectedOptions[0]?.textContent || topic;
    let visible = 0;
    const summary = [];

    posts.forEach((post) => {
      const text = normalize(`${post.dataset.title} ${post.dataset.excerpt}`);
      const tags = parseTags(post.dataset.tags);
      const topics = parseTags(post.dataset.topics);
      const routes = parseTags(post.dataset.routes);
      const matchesKeyword = !keyword || text.includes(keyword);
      const matchesTopic = topic === "all" || topics.includes(topic);
      const matchesTag = !activeTag || tags.includes(activeTag);
      const matchesRoute = !activeRoute || routes.includes(activeRoute);
      const show = matchesKeyword && matchesTopic && matchesTag && matchesRoute;

      post.hidden = !show;
      if (show) visible += 1;
    });

    count.textContent = visible;
    emptyState.hidden = visible !== 0;

    if (topic !== "all") summary.push(`주제: ${activeTopicLabel}`);
    if (activeTag) summary.push(`태그: #${activeTag}`);
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
    if (hasOption(topicFilter, requestedTopic)) {
      topicFilter.value = requestedTopic;
    }
  }
  activeTag = params.get("tag") || params.get("category") || "";
  activeRoute = params.get("route") || "";

  applyFilters();
</script>
