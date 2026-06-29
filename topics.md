---
layout: default
title: Topics
permalink: /topics/
---

{% assign topic_paths = site.data.topic_paths %}

<section class="page-title">
  <p class="eyebrow">Topics</p>
  <h1>백엔드 개발 주제를 영역별로 모아봅니다.</h1>
  <p class="page-description">
    시간순으로 글을 읽기보다, Java, Spring, API, Database, 운영 주제처럼 문제 영역별로 탐색하고 싶다면 이 페이지에서 시작하면 됩니다.
  </p>
</section>

<section class="guide-grid">
  {% for topic in topic_paths %}
    {% assign topic_count = 0 %}
    {% for post in site.posts %}
      {% assign matches_topic = false %}
      {% for tag in topic.tags %}
        {% if post.tags contains tag %}
          {% assign matches_topic = true %}
          {% break %}
        {% endif %}
      {% endfor %}
      {% if matches_topic %}
        {% assign topic_count = topic_count | plus: 1 %}
      {% endif %}
    {% endfor %}

    <article class="guide-card">
      <p class="section-label">{{ topic.label }}</p>
      <h2>{{ topic.title }}</h2>
      <p>{{ topic.topics_description }}</p>
      <div class="topic-meta">
        <strong>{{ topic_count }} {{ topic.count_label }}</strong>
        <a href="{{ '/posts/' | relative_url }}?topic={{ topic.key }}">{{ topic.view_label }}</a>
      </div>
    </article>
  {% endfor %}
</section>

<section class="home-section">
  <div class="section-kicker">전체 태그</div>
  <div class="section-head compact">
    <h2>세부 주제를 태그로 탐색해보세요</h2>
    <a class="text-link" href="{{ '/posts/' | relative_url }}">전체 목록 보기</a>
  </div>

  <div class="topic-cloud">
    {% assign sorted_tags = site.tags | sort %}
    {% for tag in sorted_tags %}
      {% assign encoded_tag = tag[0] | url_encode %}
      <a href="{{ '/posts/' | relative_url }}?tag={{ encoded_tag }}">
        #{{ tag[0] }}
        <span>{{ tag[1] | size }}</span>
      </a>
    {% endfor %}
  </div>
</section>
