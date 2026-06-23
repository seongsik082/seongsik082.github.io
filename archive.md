---
layout: default
title: Posts
permalink: /posts/
---

<section class="page-title">
  <p class="eyebrow">Posts</p>
  <h1>전체 포스트 목록을 살펴보세요.</h1>
  <p class="page-description">
    백엔드 개발, 프로젝트 회고, 문제 해결 과정을 차곡차곡 정리합니다.
  </p>
</section>

<section class="post-categories">
  <a href="/posts/">전체</a>
  <a href="/posts/">백엔드</a>
  <a href="/posts/">프로젝트</a>
  <a href="/posts/">회고</a>
</section>

<section class="post-count">
  총 {{ site.posts | size }}개의 포스트가 있어요
</section>

<section class="archive-list">
  {% for post in site.posts %}
    <article class="post-row">
      <a href="{{ post.url | relative_url }}">
        <div class="post-row-body">
          <div class="post-tags">
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
