---
layout: default
---

<!-- Page Header -->
{% if page.background %}
<header class="masthead" style="background-image: url('{{ page.background | prepend: site.baseurl | replace: '//', '/' }}')">
{% elsif page.background_color %}
<header class="masthead" style="background: {{page.background_color }}">
{% else %}
<header class="masthead">
{% endif %}
  <div class="overlay"></div>
  <div class="container">
    <div class="row">
      <div class="col-lg-8 col-md-10 mx-auto">
        <div class="post-heading">
          <h1>{{ page.title }}</h1>
          {% if page.subtitle %}
          <h2 class="subheading">{{ page.subtitle }}</h2>
          {% endif %}
          <span class="meta">Posted by
            <a href="#">{% if page.author %}{{ page.author }}{% else %}{{ site.author }}{% endif %}</a>
            on {{ page.date | date: '%B %d, %Y' }}
          </span>
        </div>
      </div>
    </div>
  </div>
</header>

<div class="container space-grotesk">
  <div class="row">
    <div class="col-lg-8 col-md-10 mx-auto">

      {{ content }}

      {% unless page.hide_toc %}
      <hr>

      {% assign group_pages = site.pages | where: "group", page.group | sort: "url" %}

      {% comment %} Detect chapters: pages whose URL ends with /index.html (subdirectory indices) {% endcomment %}
      {% assign chapters = "" | split: "" %}
      {% for gp in group_pages %}
        {% if gp.is_chapter_index %}
          {% assign chapters = chapters | push: gp %}
        {% endif %}
      {% endfor %}

      {% if chapters.size > 0 %}
        {% comment %} Chaptered group: show TOC grouped by chapter {% endcomment %}
        <h2>Table of Contents</h2>
        {% for chapter in chapters %}
          <h3>{{ chapter.chapter_title | default: chapter.title }}</h3>
          <ol>
          {% for gp in group_pages %}
            {% if gp.chapter == chapter.chapter and gp.is_chapter_index != true %}
              <li><a href="{{ gp.url | relative_url }}">{{ gp.title }}</a></li>
            {% endif %}
          {% endfor %}
          </ol>
        {% endfor %}
      {% else %}
        {% comment %} Flat group: simple ordered list {% endcomment %}
        <h2>Table of Contents</h2>
        <ol>
        {% for gp in group_pages %}
          <li><a href="{{ gp.url | relative_url }}">{{ gp.title }}</a></li>
        {% endfor %}
        </ol>
      {% endif %}
      {% endunless %}

    </div>
  </div>
</div>
