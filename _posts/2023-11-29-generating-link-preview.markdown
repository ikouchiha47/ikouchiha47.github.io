---
active: true
layout: post
title: "Generate Link Preview"
subtitle: "jekyll plugin to generate link preview from open graph"
description: "How to wite a jekyll plugin to create a liquid tag to render link preview with opengraph"
date: 2023-11-29 00:00:00
background_color: '#000'
---

### Epilogue

Initially when I wrote the [article]({% link _posts/2023-11-27-self-hosted-website.markdown %}) on how to host your website. I migrated 
it from [my linkedin page](https://www.linkedin.com/in/{{ site.linkedin_username }}).

The linkedin article supports showing a small section with the external website name and some description. This is called a link preview,
and its done usually using the `meta` tags, and the convention is called [OpenGraph](https://ogp.me).

<p>&nbsp;</p>

### Opengraph protocol

It deals with a bunch of `<meta>` tags as presented on the external website, to get the details.


This is how it looks like:

{% preview "https://www.digitalocean.com/community/tutorials/how-to-secure-nginx-with-let-s-encrypt-on-ubuntu-20-04" %}

And the corresponding html might look like this.

```html

  <!-- HTML Meta Tags -->
  <title>How To Secure Nginx with Let's Encrypt on Ubuntu 20.04  | DigitalOcean</title>
  <meta name="description" content="Let’s Encrypt is a Certificate Authority (CA) that provides an easy way to obtain and install free TLS/SSL certificates, thereby enabling encrypted HTTPS on … ">

  <!-- Facebook Meta Tags -->
  <meta property="og:url" content="https://www.digitalocean.com/community/tutorials/how-to-secure-nginx-with-let-s-encrypt-on-ubuntu-20-04">
  <meta property="og:type" content="website">
  <meta property="og:title" content="How To Secure Nginx with Let's Encrypt on Ubuntu 20.04  | DigitalOcean">
  <meta property="og:description" content="Let’s Encrypt is a Certificate Authority (CA) that provides an easy way to obtain and install free TLS/SSL certificates, thereby enabling encrypted HTTPS on … ">
  <meta property="og:image" content="https://community-cdn-digitalocean-com.global.ssl.fastly.net/vkL74ySp2fFiArxbTvhp4QF2">

  <!-- Twitter Meta Tags -->
  <meta name="twitter:card" content="summary_large_image">
  <meta property="twitter:domain" content="digitalocean.com">
  <meta property="twitter:url" content="https://www.digitalocean.com/community/tutorials/how-to-secure-nginx-with-let-s-encrypt-on-ubuntu-20-04">
  <meta name="twitter:title" content="How To Secure Nginx with Let's Encrypt on Ubuntu 20.04  | DigitalOcean">
  <meta name="twitter:description" content="Let’s Encrypt is a Certificate Authority (CA) that provides an easy way to obtain and install free TLS/SSL certificates, thereby enabling encrypted HTTPS on … ">
  <meta name="twitter:image" content="https://community-cdn-digitalocean-com.global.ssl.fastly.net/vkL74ySp2fFiArxbTvhp4QF2">

  <!-- Meta Tags Generated via https://www.opengraph.xyz -->
```

You can try it on any webpage from here: [https://www.opengraph.xyz](https://www.opengraph.xyz).


Since its html, not everytime the tags will be done right, so we also need to support finding the best possible values.

<p>&nbsp;</p>

### Writing a Liquid Tag

Jekyll uses [Liquid](https://shopify.github.io/liquid/) templating engine. 

The usual way to write a plugin is in the `_plugins/` folder in your root directory.

A basic custom template code generally looks like this:

```ruby
module Jekyll
  class RenderTimeTag < Liquid::Tag

    def initialize(tag_name, text, tokens)
      super
      @text = text
    end

    # THIS IS THE EXPECTED METHOD
    def render(context)
      "#{@text} #{Time.now}"
    end
  end
end

Liquid::Template.register_tag('render_time', Jekyll::RenderTimeTag)
```
_from jekyll [docs](https://jekyllrb.com/docs/plugins/tags/)_


To write this custom link preview tag we need something similar. And these tags will be executed during the loading phase, before jekyll generate the static pages, _obviously_.

<p>&nbsp;</p>

### Implementation details

In order to achieve this, we will:
1. download the webpage
2. parse the meta tags
3. extract the title description and image
4. In case they are not present in meta tags, try to get them from different sources, like get list of all images, read title tag etc.


We could use [faraday](https://lostisland.github.io/faraday/) and [Nokogiri](https://nokogiri.org), but _Show me Speed_.

There is a ruby gem called [metainspector](https://github.com/jaimeiniesta/metainspector) and it does steps `1.`, `2.` and `4.`, and it has a way to get the `best` possible values.

```ruby
page = MetaInspector.new(url, encoding: 'utf-8')
```

We can now create two classes. `OpenGraphFactory` and `NonOpenGraphFactory`.

The base case for selecting one depends on the presence of the required fields
- `og:title`, 
- `og:description` and 
- `og:image`

in `page.meta_tags["property"]`. If it does, its processed by `OpenGraphFactory`. 

```ruby
def create_properties_from_page(page)
  if !%w[og:title og:type og:url og:image].all? { |required_tag|
    page.meta_tags['property'].include?(required_tag)
  }
    factory = NonOpenGraphPropertiesFactory.new
  else
    factory = OpenGraphPropertiesFactory.new
  end
  factory.from_page(page)
end
```

_here `page` refers to `MetaInspector.new` object._

<p>&nbsp;</p>
The two __classes__ would look like this:

```ruby
class OpenGraphFactory
  def from_page(page)
    {
      title: get_property_value(page.meta_tags, "og:title")
      description: get_property_value(page.meta_tags, "og:description")
      image: convert_to_absolute_url(get_property_value(page.meta_tags, "og:image")),
      domain: page.host,
    }
  end

  private
  def get_property_value(meta_tags, meta_key)
    # Sometime the `og:*` values are also present inside `page.meta_tags["name"]` 
    # instead of `page.meta_tags["property"].
    page.meta_tags["property"][meta_key] || page.meta_tags["name"][meta_key]
  end

  def convert_to_aboslute_url(url)
    # if 
  end
end
```
<p>&nbsp;</p>

```ruby
class NonOpenGraphFactory
  def from_page(page)
    {
      title: page.best_tile,
      description: page.best_description,
      image: page.images.best,
      domain: page.host,
    }
  end
end
```

And then you need to have a template to `render` into. And you can use string substitution, or rendering engine.

<p>&nbsp;</p>

```html
<section class="flex flex-row align-center gap-2">
  <section class="flex-1 image-preview>
    <img src=#{image} />
  </section>
  <section> class="flex-2 content-wrapper">
    <a class="content-title" href=#{domain}>#{title}</em>
    <p class="description">#{description}</p>
  </section>
</section>
```

__Register__ your `Liquid` template 

`Liquid::Template.register_tag('preview', Jekyll::Preview::PreviewTag)`

<p>&nbsp;</p>

### Optimization

We didn't handle what happens when network goes off. The `factory` classes return `title: Not Found` right now.

Now, the problem is we don't want to visit the website everytime we jekyll serve. What we do is cache the metaproperty values
against the `md5(website_url)`. 

So the next time, it searches in cache first and then goes to make external requests.

```ruby
def get_properties(url)
  cache_filepath = "#{@@cache_dir}/%s.json" % Digest::MD5.hexdigest(url)

  if File.exist?(cache_filepath) then
    hash = load_cache_file(cache_filepath)
    return create_properties_from_hash(hash)
  end

  page = fetch(url)
  properties = create_properties_from_page(page)
  save_cache_file(cache_filepath, properties)

  properties
end
```

There can be another optimization that can be made, which is to queue these urls and generate in batches. But we will see that later


And that's it.

<p>&nbsp;</p>

### Usage

```ruby
{% raw %}
{% preview "https://ikouchiha47.github.io/2023/11/27/self-hosted-website.html" %}
{% endraw %}
```

And it looks like:

{% preview "https://ikouchiha47.github.io/2023/11/27/self-hosted-website.html" %}

