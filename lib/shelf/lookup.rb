require "net/http"
require "json"
require "uri"

module Shelf
  # Metadata lookups. Open Library first (open data, has community ratings),
  # Google Books as a fallback. No API keys needed for either.
  module Lookup
    USER_AGENT = "Shelf/1.0 (personal book tracker)".freeze

    FORMAT_MAP = {
      /hard/i => "hardcover", /paper|mass market/i => "paperback",
      /e-?book|kindle|digital|epub/i => "ebook", /audio|cd/i => "audiobook"
    }.freeze

    class << self
      # Swappable for tests: ->(url) { parsed_json_or_nil }
      attr_writer :http

      def http
        @http ||= method(:get_json)
      end

      # => Hash of Book column values, or nil.
      # Open Library's books API, then its search index (which sometimes knows
      # an ISBN the books API doesn't), then Google Books.
      def by_isbn(isbn13)
        open_library(isbn13) || open_library_search(isbn13) || google_books(isbn13)
      end

      def open_library_search(isbn)
        fields = "key,title,subtitle,author_name,publisher,first_publish_year,number_of_pages_median," \
                 "cover_i,ratings_average,ratings_count"
        doc = http.call("https://openlibrary.org/search.json?isbn=#{isbn}&limit=1&fields=#{fields}")&.dig("docs", 0)
        return nil unless doc && doc["title"]
        {
          title: doc["title"],
          subtitle: doc["subtitle"],
          authors: Array(doc["author_name"]).join("; ").then { _1.empty? ? nil : _1 },
          publisher: Array(doc["publisher"]).first,
          published_year: doc["first_publish_year"],
          pages: doc["number_of_pages_median"],
          cover_url: doc["cover_i"] && "https://covers.openlibrary.org/b/id/#{doc['cover_i']}-M.jpg",
          openlibrary_work: doc["key"].to_s.split("/").last,
          ol_avg_rating: doc["ratings_average"]&.round(2),
          ol_rating_count: doc["ratings_count"]
        }.reject { |_, v| v.nil? || v == "" }
      end

      def open_library(isbn)
        data = http.call("https://openlibrary.org/api/books?bibkeys=ISBN:#{isbn}&format=json&jscmd=data")
        rec = data && data["ISBN:#{isbn}"] or return nil
        edition = http.call("https://openlibrary.org/isbn/#{isbn}.json") || {}
        ids = rec["identifiers"] || {}
        {
          title: rec["title"],
          subtitle: rec["subtitle"],
          authors: Array(rec["authors"]).map { _1["name"] }.join("; ").then { _1.empty? ? nil : _1 },
          publisher: Array(rec["publishers"]).first&.dig("name"),
          published_year: rec["publish_date"].to_s[/\d{4}/]&.to_i,
          pages: rec["number_of_pages"],
          cover_url: rec.dig("cover", "medium"),
          openlibrary_id: rec["key"].to_s.split("/").last,
          openlibrary_work: Array(edition["works"]).first&.dig("key").to_s.split("/").last,
          goodreads_id: Array(ids["goodreads"]).first,
          isbn10: Array(ids["isbn_10"]).first,
          format: map_format(edition["physical_format"])
        }.reject { |_, v| v.nil? || v == "" }
      end

      def google_books(isbn)
        # Keyless requests get a quota of zero, so a key is effectively required.
        # Free: console.cloud.google.com → enable "Books API" → Credentials → API key.
        key = ENV["GOOGLE_BOOKS_API_KEY"].to_s
        return nil if key.empty?
        data = http.call("https://www.googleapis.com/books/v1/volumes?q=isbn:#{isbn}&key=#{key}")
        item = data && Array(data["items"]).first or return nil
        info = item["volumeInfo"] || {}
        # Search results only carry ~128px thumbnails; the volume endpoint
        # has the bigger sizes.
        detail = item["id"] && http.call("https://www.googleapis.com/books/v1/volumes/#{item['id']}?key=#{key}")
        links = detail&.dig("volumeInfo", "imageLinks") || info["imageLinks"] || {}
        cover = links.values_at("large", "medium", "extraLarge", "small", "thumbnail").compact.first
        {
          title: info["title"],
          subtitle: info["subtitle"],
          authors: Array(info["authors"]).join("; ").then { _1.empty? ? nil : _1 },
          publisher: info["publisher"],
          published_year: info["publishedDate"].to_s[/\d{4}/]&.to_i,
          pages: info["pageCount"],
          cover_url: cover && clean_google_cover(cover)
        }.reject { |_, v| v.nil? || v == "" }
      end

      # https, and drop the fake page-curl Google paints on thumbnails.
      def clean_google_cover(url) = url.sub("http://", "https://").sub("&edge=curl", "")

      # Low-res covers we'll replace on refresh: Google search thumbnails.
      def low_res_cover?(url) = url.to_s.match?(/books\.google.*[?&]zoom=1(&|\z)/)

      # Free-text search for the Add page's typeahead. Open Library results
      # are works (any edition); Google results are specific editions.
      # => [{ title:, authors:, year:, cover_url:, openlibrary_work:, isbn13:, editions:, source: }]
      def search_books(query, limit: 8)
        q = query.to_s.strip
        return [] if q.length < 3
        ol = search_open_library(q, limit)
        gb = search_google(q, limit)
        seen = ol.map { Book.match_key(_1[:title], _1[:authors]) }
        ol + gb.reject { seen.include?(Book.match_key(_1[:title], _1[:authors])) }
      end

      def search_open_library(q, limit)
        params = URI.encode_www_form(q: q, limit: limit,
                                     fields: "key,title,subtitle,author_name,first_publish_year,cover_i,edition_count")
        Array(http.call("https://openlibrary.org/search.json?#{params}")&.dig("docs")).filter_map do |d|
          next unless d["title"]
          {
            source: "openlibrary", title: d["title"], subtitle: d["subtitle"],
            authors: Array(d["author_name"]).first(3).join("; "),
            year: d["first_publish_year"], editions: d["edition_count"],
            openlibrary_work: d["key"].to_s.split("/").last,
            cover_url: d["cover_i"] && "https://covers.openlibrary.org/b/id/#{d['cover_i']}-M.jpg"
          }
        end
      end

      def search_google(q, limit)
        key = ENV["GOOGLE_BOOKS_API_KEY"].to_s
        return [] if key.empty?
        params = URI.encode_www_form(q: q, maxResults: limit, printType: "books", key: key)
        Array(http.call("https://www.googleapis.com/books/v1/volumes?#{params}")&.dig("items")).filter_map do |item|
          v = item["volumeInfo"] || {}
          next unless v["title"]
          ids = Array(v["industryIdentifiers"]).to_h { [_1["type"], _1["identifier"]] }
          thumb = v.dig("imageLinks", "thumbnail")
          {
            source: "google", title: v["title"], subtitle: v["subtitle"],
            authors: Array(v["authors"]).first(3).join("; "),
            year: v["publishedDate"].to_s[/\d{4}/]&.to_i, publisher: v["publisher"], pages: v["pageCount"],
            isbn13: ISBN.normalize(ids["ISBN_13"] || ids["ISBN_10"]),
            cover_url: thumb && clean_google_cover(thumb)
          }
        end
      end

      # For books without an ISBN (Kindle editions from Goodreads, etc.):
      # finds the Open Library work, which carries community ratings.
      def search(title, author)
        q = URI.encode_www_form(title: title, author: author.to_s, limit: 1,
                                fields: "key,ratings_average,ratings_count,cover_i")
        doc = http.call("https://openlibrary.org/search.json?#{q}")&.dig("docs", 0) or return nil
        {
          openlibrary_work: doc["key"].to_s.split("/").last,
          ol_avg_rating: doc["ratings_average"]&.round(2),
          ol_rating_count: doc["ratings_count"],
          cover_url: doc["cover_i"] && "https://covers.openlibrary.org/b/id/#{doc['cover_i']}-M.jpg"
        }.compact
      end

      # When the edition has no cover: the work's cover (any edition of the
      # same book, sharp), then Google's cover for this exact ISBN.
      def fallback_cover(isbn: nil, work: nil)
        work_cover(work) || (isbn && google_books(isbn)&.dig(:cover_url))
      end

      def work_cover(work_id)
        return nil unless work_id
        id = Array(http.call("https://openlibrary.org/works/#{work_id}.json")&.dig("covers")).find { _1.to_i.positive? }
        id && "https://covers.openlibrary.org/b/id/#{id}-M.jpg"
      end

      def ratings(work_id)
        s = http.call("https://openlibrary.org/works/#{work_id}/ratings.json")&.dig("summary") or return nil
        return nil unless s["average"]
        { ol_avg_rating: s["average"].round(2), ol_rating_count: s["count"] }
      end

      def map_format(str)
        return nil if str.to_s.empty?
        FORMAT_MAP.find { |re, _| str.match?(re) }&.last || "other"
      end

      private

      def get_json(url, redirects = 3)
        uri = URI(url)
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                              open_timeout: 4, read_timeout: 6) do |h|
          h.get(uri.request_uri, "User-Agent" => USER_AGENT, "Accept" => "application/json")
        end
        case res
        when Net::HTTPSuccess then JSON.parse(res.body)
        when Net::HTTPRedirection
          redirects.positive? ? get_json(URI.join(url, res["location"]).to_s, redirects - 1) : nil
        when Net::HTTPNotFound then nil # normal "we don't have it"
        else
          warn "[lookup] #{redact(url)}: HTTP #{res.code} #{res.body.to_s[0, 200].gsub(/\s+/, ' ')}"
          nil
        end
      rescue StandardError => e
        warn "[lookup] #{redact(url)}: #{e.class}: #{e.message}"
        nil
      end

      def redact(url) = url.sub(/key=[^&]+/, "key=…")
    end
  end
end
