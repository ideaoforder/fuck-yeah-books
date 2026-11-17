require "json"
require "date"

module Shelf
  # The Booklog format: plain JSON that is also valid schema.org JSON-LD.
  #
  # Books, reviews and ratings use schema.org's own Book / Review / Rating /
  # AggregateRating vocabulary, so any schema.org-aware tool understands them.
  # Things schema.org has no slot for (your reads, loans, reading status) are
  # extension keys, which JSON-LD processors simply ignore.
  #
  # See public/schema/booklog.schema.json and README.md.
  module Booklog
    VERSION = "1.0"
    SCHEMA_ID = "https://shelf.local/schema/booklog-1.0.schema.json"

    FORMATS = { "hardcover" => "Hardcover", "paperback" => "Paperback",
                "ebook" => "EBook", "audiobook" => "AudiobookFormat" }.freeze

    module_function

    def export(books, name: "My books")
      {
        "$schema" => SCHEMA_ID,
        "@context" => "https://schema.org",
        "@type" => "ItemList",
        "name" => name,
        "booklogVersion" => VERSION,
        "dateCreated" => Time.now.utc.iso8601,
        "numberOfItems" => books.size,
        "itemListElement" => books.map { book(_1) }
      }
    end

    # A single review in canonical schema.org shape: Review → itemReviewed → Book.
    def review(b, reader: ENV["SHELF_READER"])
      {
        "@context" => "https://schema.org",
        "@type" => "Review",
        "itemReviewed" => book(b, personal: false),
        "author" => reader && { "@type" => "Person", "name" => reader },
        **review_fields(b)
      }.compact
    end

    def book(b, personal: true)
      h = {
        "@type" => "Book",
        "name" => b.title,
        "alternativeHeadline" => b.subtitle,
        "author" => b.author_list.map { { "@type" => "Person", "name" => _1 } },
        "isbn" => b.isbn13,
        "bookFormat" => FORMATS[b.format]&.then { "https://schema.org/#{_1}" },
        "numberOfPages" => b.pages,
        "publisher" => b.publisher,
        "datePublished" => b.published_year&.to_s,
        "image" => b.cover_url,
        "sameAs" => same_as(b),
        "identifier" => b.storygraph_id && [{ "@type" => "PropertyValue", "propertyID" => "storygraph", "value" => b.storygraph_id }],
        "aggregateRating" => aggregate_ratings(b)
      }
      if personal
        h.merge!(
          "review" => (b.rating || b.review.to_s != "") ? { "@type" => "Review", **review_fields(b) } : nil,
          "keywords" => b.tags,
          # --- extensions (not schema.org) ---
          "readingStatus" => b.status,
          "owned" => b.owned,
          "dateAdded" => b.added_on&.iso8601,
          "privateNotes" => b.notes,
          "reads" => b.reads.map { { "startTime" => _1.started_on&.iso8601, "endTime" => _1.finished_on&.iso8601 }.compact },
          "borrows" => b.borrows.map do |l|
            { "borrower" => l.borrowed_by, "startTime" => l.borrowed_on.iso8601,
              "endTime" => l.returned_on&.iso8601, "notes" => l.notes }.compact
          end
        )
      end
      h.reject { |_, v| v.nil? || v == "" || v == [] }
    end

    def review_fields(b)
      {
        "reviewRating" => b.rating && { "@type" => "Rating", "ratingValue" => b.rating, "bestRating" => 5, "worstRating" => 0 },
        "reviewBody" => b.review.to_s.empty? ? nil : b.review,
        "dateCreated" => b.reviewed_on&.iso8601
      }.compact
    end

    def same_as(b)
      [
        b.openlibrary_id && "https://openlibrary.org/books/#{b.openlibrary_id}",
        b.openlibrary_work && "https://openlibrary.org/works/#{b.openlibrary_work}",
        b.goodreads_id && "https://www.goodreads.com/book/show/#{b.goodreads_id}"
      ].compact
    end

    def aggregate_ratings(b)
      [
        b.gr_avg_rating && { "@type" => "AggregateRating", "ratingValue" => b.gr_avg_rating, "bestRating" => 5,
                             "author" => { "@type" => "Organization", "name" => "Goodreads" } },
        b.ol_avg_rating && { "@type" => "AggregateRating", "ratingValue" => b.ol_avg_rating, "bestRating" => 5,
                             "ratingCount" => b.ol_rating_count, "author" => { "@type" => "Organization", "name" => "Open Library" } }.compact
      ].compact
    end
  end

  module Importers
    # Reads Booklog JSON — a full ItemList export, a single Book, a single
    # schema.org Review (with itemReviewed), or an array of either.
    class Booklog < Base
      def self.detect?(data) = data.lstrip.start_with?("{", "[")

      def each_record
        items(JSON.parse(@data)).each.with_index(1) { |(book, review), i| yield(record(book, review), "item #{i}") }
      end

      private

      def items(json)
        list = json.is_a?(Array) ? json : (json["itemListElement"] || [json])
        list.filter_map do |node|
          node = node["item"] if node["@type"] == "ListItem"
          case node["@type"]
          when "Review" then [node["itemReviewed"] || {}, node]
          when "Book", nil then [node, node["review"]]
          end
        end
      end

      def record(b, review)
        same = Array(b["sameAs"])
        ids = Array(b["identifier"]).to_h { [_1["propertyID"], _1["value"]] } rescue {}
        rating = review && review["reviewRating"]
        agg = Array(b["aggregateRating"])
        {
          book: {
            title: b["name"],
            subtitle: b["alternativeHeadline"],
            authors: Array(b["author"]).map { _1.is_a?(Hash) ? _1["name"] : _1 }.join("; "),
            isbn13: ISBN.normalize(b["isbn"]),
            format: ::Shelf::Booklog::FORMATS.key(b["bookFormat"].to_s.split("/").last),
            pages: b["numberOfPages"],
            publisher: b["publisher"].is_a?(Hash) ? b["publisher"]["name"] : b["publisher"],
            published_year: b["datePublished"].to_s[/\d{4}/]&.to_i,
            cover_url: b["image"].is_a?(Hash) ? b["image"]["url"] : b["image"],
            openlibrary_id: same.join(" ")[%r{openlibrary\.org/books/(\w+)}, 1],
            openlibrary_work: same.join(" ")[%r{openlibrary\.org/works/(\w+)}, 1],
            goodreads_id: same.join(" ")[%r{goodreads\.com/book/show/(\d+)}, 1],
            storygraph_id: ids["storygraph"],
            gr_avg_rating: agg.find { _1.dig("author", "name") == "Goodreads" }&.dig("ratingValue"),
            ol_avg_rating: agg.find { _1.dig("author", "name") == "Open Library" }&.dig("ratingValue"),
            ol_rating_count: agg.find { _1.dig("author", "name") == "Open Library" }&.dig("ratingCount"),
            rating: rating && normalize_rating(rating),
            review: review && review["reviewBody"],
            reviewed_on: review && date(review["dateCreated"] || review["datePublished"]),
            tags: Array(b["keywords"]).join(", "),
            status: b["readingStatus"] || (review ? "read" : nil),
            owned: b["owned"],
            added_on: date(b["dateAdded"]),
            notes: b["privateNotes"]
          },
          reads: Array(b["reads"]).map { [date(_1["startTime"]), date(_1["endTime"])] },
          borrows: Array(b["borrows"]).map do |l|
            { borrowed_by: l["borrower"], borrowed_on: date(l["startTime"]),
              returned_on: date(l["endTime"]), notes: l["notes"] }
          end
        }
      end

      # Rescale any rating to 0–5 and snap to quarter stars.
      def normalize_rating(r)
        value = r["ratingValue"].to_f
        best = (r["bestRating"] || 5).to_f
        worst = (r["worstRating"] || 0).to_f
        return nil if value <= 0
        scaled = worst.zero? ? value / best * 5 : (value - worst) / (best - worst) * 4.75 + 0.25
        ((scaled * 4).round / 4.0).clamp(0.25, 5.0)
      end

      def date(v)
        v.to_s.empty? ? nil : Date.parse(v.to_s)
      rescue Date::Error
        nil
      end
    end
  end
end
