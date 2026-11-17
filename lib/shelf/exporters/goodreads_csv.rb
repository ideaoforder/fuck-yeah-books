require "csv"

module Shelf
  module Exporters
    # Writes the exact column layout of a Goodreads library export. That CSV is
    # the de facto interchange format: StoryGraph, BookWyrm, Goodreads itself
    # and most other trackers can import it.
    #
    # Lossy bits (the format's limits, not ours): ratings are whole stars,
    # only the most recent read date survives, loans aren't included.
    module GoodreadsCsv
      HEADERS = ["Book Id", "Title", "Author", "Author l-f", "Additional Authors", "ISBN", "ISBN13",
                 "My Rating", "Average Rating", "Publisher", "Binding", "Number of Pages", "Year Published",
                 "Original Publication Year", "Date Read", "Date Added", "Bookshelves",
                 "Bookshelves with positions", "Exclusive Shelf", "My Review", "Spoiler", "Private Notes",
                 "Read Count", "Owned Copies"].freeze

      SHELF = { "want" => "to-read", "reading" => "currently-reading", "read" => "read", "dnf" => "did-not-finish" }.freeze
      BINDING = { "hardcover" => "Hardcover", "paperback" => "Paperback", "ebook" => "ebook", "audiobook" => "Audiobook" }.freeze

      module_function

      def call(books)
        CSV.generate do |csv|
          csv << HEADERS
          books.each { |b| csv << row(b) }
        end
      end

      def row(b)
        first, *rest = b.author_list
        shelf = SHELF.fetch(b.status)
        shelves = [*b.tag_list, shelf].uniq
        [
          b.goodreads_id, b.title, first, last_first(first), rest.join(", "),
          %(="#{b.isbn10}"), %(="#{b.isbn13}"),
          b.rating ? b.rating.round(half: :up) : 0,
          b.gr_avg_rating, b.publisher, BINDING[b.format], b.pages, b.published_year, nil,
          b.last_read_on&.strftime("%Y/%m/%d"), b.added_on&.strftime("%Y/%m/%d"),
          shelves.join(", "), shelves.map { "#{_1} (#)" }.join(", "), shelf,
          b.review.to_s.gsub("\n", "<br/>"), nil, b.notes,
          b.reads.size, b.owned ? 1 : 0
        ]
      end

      def last_first(name)
        parts = name.to_s.split
        parts.size > 1 ? "#{parts.last}, #{parts[0..-2].join(' ')}" : name
      end
    end
  end
end
