# Paginates the `shorts` collection into /wall/, /wall/page/2/, ...
#
# Deliberately not jekyll-paginate-v2: that plugin's docs warn it can
# conflict with the classic jekyll-paginate already driving /posts/.
# This generator only ever touches the `shorts` collection, so /posts/
# and home stay exactly as they are.
module Wall
  class PaginationGenerator < Jekyll::Generator
    safe true
    priority :low

    def generate(site)
      shorts = site.collections["shorts"]
      return unless shorts

      docs = shorts.docs
                   .reject { |d| d.data["active"] == false }
                   .sort_by { |d| d.date }
                   .reverse

      per_page = site.config.dig("wall", "paginate") || 15
      pages = docs.each_slice(per_page).to_a
      pages = [[]] if pages.empty?
      total_pages = pages.length

      pages.each_with_index do |page_docs, index|
        page_num = index + 1
        dir = page_num == 1 ? "wall" : "wall/page/#{page_num}"

        wall_page = Jekyll::PageWithoutAFile.new(site, site.source, dir, "index.html")
        wall_page.content = ""
        wall_page.data["layout"] = "wall_index"
        wall_page.data["title"] = "the wall"

        wall_page.data["paginator"] = {
          "docs" => page_docs,
          "page" => page_num,
          "total_pages" => total_pages,
          "previous_page_path" => page_num > 1 ? (page_num == 2 ? "/wall/" : "/wall/page/#{page_num - 1}/") : nil,
          "next_page_path" => page_num < total_pages ? "/wall/page/#{page_num + 1}/" : nil,
        }

        site.pages << wall_page
      end
    end
  end
end
