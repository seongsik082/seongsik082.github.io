---
layout: default
title: Archive
permalink: /archive/
---

<section class="page-title">
  <p class="eyebrow">Archive</p>
  <h1>기록한 글</h1>
</section>

<section class="archive-list">
  {% for post in site.posts %}
    <article>
      <time datetime="{{ post.date | date_to_xmlschema }}">{{ post.date | date: "%Y.%m.%d" }}</time>
      <h2><a href="{{ post.url | relative_url }}">{{ post.title }}</a></h2>
      <p>{{ post.excerpt | strip_html | truncate: 140 }}</p>
    </article>
  {% endfor %}
</section>
