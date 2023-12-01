# 2. Use the following link syntax: 
#
#  {% preview http://example.com/some-article.html %}
#
# 3. In case we can't fetch the Title from a linksource, you can set it manually:
#
#  {% preview "Some Article" http://example.com/some-article.html %}

require 'pry'
require "digest"
require "json"
require 'uri'

require 'faraday'
require 'faraday/follow_redirects'
require 'faraday-cookie_jar'

require "metainspector"

IMAGE_OVERRIDES = {
  "AWS": "https://upload.wikimedia.org/wikipedia/commons/5/5c/AWS_Simple_Icons_AWS_Cloud.svg",
  "TERRAFORM": "https://raw.githubusercontent.com/github/explore/80688e429a7d4ef2fca1e82350fe8e3517d3494d/topics/terraform/terraform.png"
}

module Jekyll
  module Preview
    class OverrideImage
      def self.overrides(url, image_src)
        if url.include?("://docs.aws.amazon.") && image_src.include?("warning")
          return IMAGE_OVERRIDES[:AWS]
        elsif url.include?("://www.terraform.io")
          return IMAGE_OVERRIDES[:TERRAFORM]
        end

        return image_src
      end
    end

    class Properties
      def initialize(properties, template_file)
        @properties = properties
        @template_file = template_file
      end

      def to_hash
        @properties
      end

      def to_hash_for_custom_template
        hash_for_custom_template = {}
        @properties.each{ |key, value|
          hash_for_custom_template[key] = value
          # NOTE: 'link_*' variables will be deleted in v1.0.0.
          hash_for_custom_template['link_' + key] = value
        }
        hash_for_custom_template
      end

      def template_file
        @template_file
      end
    end

    class OpenGraphPropertiesFactory
      @@template_file = 'linkpreview.html'

      def self.template_file
        @@template_file
      end

      def from_page(page)
        properties = page.meta_tags['property']
        image = convert_to_absolute_url(get_property(properties, 'og:image'), page.root_url)
        image = OverrideImage.overrides(page.url, image)

        og_properties = {
          # basic metadata (https://ogp.me/#metadata)
          'title' => get_property(properties, 'og:title'),
          'type' => get_property(properties, 'og:type'),
          'url' => get_property(properties, 'og:url'),
          'image' => image,
          'description' => get_property(properties, 'og:description'),
          'determiner' => get_property(properties, 'og:determiner'),
          'locale' => get_property(properties, 'og:locale'),
          'locale_alternate' => get_property(properties, 'og:locale:alternate'),
          'site_name' => get_property(properties, 'og:site_name'),

          'domain' => page.host,

          # optional metadata (https://ogp.me/#optional)
          ## image
          # 'image_secure_url' => convert_to_absolute_url(get_property(properties, 'og:image:secure_url'), page.root_url),
          # 'image_type' => get_property(properties, 'og:image:type'),
          # 'image_width' => get_property(properties, 'og:image:width'),
          # 'image_height' => get_property(properties, 'og:image:height'),
          # 'image_alt' => get_property(properties, 'og:image:alt'),
          ## video
          # 'video' => convert_to_absolute_url(get_property(properties, 'og:video'), page.root_url),
          # 'video_secure_url' => convert_to_absolute_url(get_property(properties, 'og:video:secure_url'), page.root_url),
          # 'video_type' => get_property(properties, 'og:video:type'),
          # 'video_width' => get_property(properties, 'og:video:width'),
          # 'video_height' => get_property(properties, 'og:video:height'),
          ## audio
          # 'audio' => convert_to_absolute_url(get_property(properties, 'og:audio'), page.root_url),
          # 'audio_secure_url' => convert_to_absolute_url(get_property(properties, 'og:audio:secure_url'), page.root_url),
          # 'audio_type' => get_property(properties, 'og:audio:type'),
          ## other optional metadata
          
        }

        Properties.new(og_properties, @@template_file)
      end

      def from_hash(hash)
        Properties.new(hash, @@template_file)
      end

      private
      def get_property(properties, key)
        if !properties.key? key then
          return nil
        end
        properties[key].first
      end

      private
      def convert_to_absolute_url(url, domain)
        if url.nil? then
          return nil
        end
        # root relative url
        if url[0] == '/' then
          return URI.join(domain, url).to_s
        end
        url
      end
    end

    class NonOpenGraphPropertiesFactory
      @@template_file = 'linkpreview_nog.html'

      def self.template_file
        @@template_file
      end

      def from_page(page)
        Properties.new({
          'title' => page.best_title,
          'url' => page.url,
          'description' => page.best_description,
          'domain' => page.host,
          'image' => OverrideImage.overrides(page.url, best_image(page)),
        }, @@template_file)
      end

      def best_image(page)
        img = page.images.best
        return img unless img&.empty?

        h = Nokogiri::HTML(page.to_s)
        logos = h.css('img').select {|img| img['src']&.include?('logo') }.map { |img| img['src'] }.uniq
        return "" if logos&.empty?

        return logos.first
      end

      def from_hash(hash)
        Properties.new(hash, @@template_file)
      end

    end 

    class PreviewTag < Liquid::Tag
      @@cache_dir = '_cache'
      @@template_dir = '_includes'

      def initialize(tag_name, markup, parse_context)
        super
        @markup = markup.strip()
      end

      def render(context)
        url = get_url_from(context)
        
        properties = get_properties(url)
        render_linkpreview context, properties
      end

      def get_properties(url)
        cache_filepath = "#{@@cache_dir}/%s.json" % Digest::MD5.hexdigest(url)

        p "url ==> #{url}, filepath ==> #{cache_filepath}"

        if File.exist?(cache_filepath) then
          hash = load_cache_file(cache_filepath)
          return create_properties_from_hash(hash)
        end

        page = fetch(url)
        properties = create_properties_from_page(page)

        if Dir.exist?(@@cache_dir) then
          save_cache_file(cache_filepath, properties)
        else
          # TODO: This message will be shown at all linkprevew tag
          warn "'#{@@cache_dir}' directory does not exist. Create it for caching."
        end
        properties
      end

      private
      def get_url_from(context)
        context[@markup]
      end

      private
      def fetch(url)
        MetaInspector.new(url, encoding: 'utf-8', faraday_options: { redirect: { limit: 2 } })
      end
 
      private
      def load_cache_file(filepath)
        JSON.parse(File.open(filepath).read)
      end

      protected
      def save_cache_file(filepath, properties)
        File.open(filepath, 'w') { |f| f.write JSON.generate(properties.to_hash) }
      end

      private
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

      private
      def create_properties_from_hash(hash)
        if hash['image'] then
          factory = OpenGraphPropertiesFactory.new
        else
          factory = NonOpenGraphPropertiesFactory.new
        end

        factory.from_hash(hash)
      end

      private
      def render_linkpreview(context, properties)
        template_path = get_custom_template_path context, properties
        if File.exist?(template_path)
          hash = properties.to_hash_for_custom_template
          gen_custom_template template_path, hash
        else
          gen_default_template properties.to_hash
        end
      end

      private
      def get_custom_template_path(context, properties)
        source_dir = get_source_dir_from context
        File.join source_dir, @@template_dir, properties.template_file
      end

      private
      def get_source_dir_from(context)
        File.absolute_path context.registers[:site].config['source'], Dir.pwd
      end

      private
      def gen_default_template(hash)
        title = hash['title']
        url = hash['url']
        description = hash['description']
        domain = hash['domain']
        image = hash['image']
        image_html = ""
        if image then
          image_html = <<-EOS
      <div class="preview-image">
        <a href="#{url}" target="_blank" class="preview-img-wrapper">
          <img src="#{image}" />
        </a>
      </div>
          EOS
        end
        html = <<-EOS
<div class="preview-wrapper">
  <div class="preview-wrapper-inner">
    <div class="preview-content">
#{image_html}
      <div class="preview-body">
        <h2 class="preview-title">
          <a href="#{url}" target="_blank">#{title}</a>
        </h2>
        <div class="preview-description">#{description}</div>
        <div class="preview-footer">
          <a href="//#{domain}" target="_blank">#{domain}</a>
        </div>
      </div>
    </div>
  </div>
</div>
        EOS
        html
      end

      private
      def gen_custom_template(template_path, hash)
        template = File.read template_path
        Liquid::Template.parse(template).render!(hash)
      end
    end
  end
end

Liquid::Template.register_tag('preview', Jekyll::Preview::PreviewTag)
