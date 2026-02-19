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
        </div>
      </div>
    </div>
  </div>
</header>

<div class="container space-grotesk">
  <div class="row">
    <div class="col-lg-8 col-md-10 mx-auto">

      <!-- Breadcrumb -->
      <nav aria-label="breadcrumb" style="margin-bottom: 1.5rem;">
        <ol class="breadcrumb" style="background: transparent; padding: 0;">
          {% if page.group_url %}
            <li class="breadcrumb-item"><a href="{{ page.group_url | relative_url }}">{{ page.group_title }}</a></li>
          {% endif %}
          {% if page.chapter_title and page.is_chapter_index != true %}
            {% if page.chapter_url %}
              <li class="breadcrumb-item"><a href="{{ page.chapter_url | relative_url }}">{{ page.chapter_title }}</a></li>
            {% else %}
              <li class="breadcrumb-item">{{ page.chapter_title }}</li>
            {% endif %}
          {% endif %}
          <li class="breadcrumb-item active" aria-current="page">{{ page.title }}</li>
        </ol>
      </nav>

      {{ content }}

      <hr>

      <!-- Prev / Next / Up navigation -->
      {% assign group_pages = site.pages | where: "group", page.group | sort: "url" %}
      {% assign current_index = nil %}
      {% for gp in group_pages %}
        {% if gp.url == page.url %}
          {% assign current_index = forloop.index0 %}
        {% endif %}
      {% endfor %}

      <div class="clearfix" style="margin-top: 2rem;">
        {% if current_index != nil %}
          {% assign prev_index = current_index | minus: 1 %}
          {% assign next_index = current_index | plus: 1 %}

          {% if prev_index >= 0 %}
            {% assign prev_page = group_pages[prev_index] %}
            <a class="btn btn-primary float-left" href="{{ prev_page.url | relative_url }}" title="{{ prev_page.title }}">&larr; Previous</a>
          {% endif %}

          {% if next_index < group_pages.size %}
            {% assign next_page = group_pages[next_index] %}
            <a class="btn btn-primary float-right" href="{{ next_page.url | relative_url }}" title="{{ next_page.title }}">Next &rarr;</a>
          {% endif %}
        {% endif %}
      </div>

      {% if page.group_url %}
      <div style="text-align: center; margin-top: 1rem;">
        <a href="{{ page.group_url | relative_url }}">&uarr; Back to Table of Contents</a>
      </div>
      {% endif %}

    </div>
  </div>
</div>
