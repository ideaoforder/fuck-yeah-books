module Shelf
  module Importers
    # Goodreads: My Books → Import and export → Export Library.
    class Goodreads < Base
      SHELVES = { "read" => "read", "currently-reading" => "reading", "to-read" => "want" }.freeze

      def self.detect?(headers) = headers.include?("Book Id") && headers.include?("Exclusive Shelf")

      def each_record
        csv_rows.each do |row, line|
          shelf = col(row, "Exclusive Shelf").to_s
          read_on = date(col(row, "Date Read"))
          status = SHELVES[shelf] ||
                   if shelf.match?(/not.?interested|won.?t.?read|skip/i) then "not_interested"
                   elsif shelf.match?(/dnf|did.?not|abandon/i) then "dnf"
                   else read_on ? "read" : "want"
                   end
          authors = [col(row, "Author"), *col(row, "Additional Authors").to_s.split(",")].compact.map(&:strip)

          reads = []
          if read_on then reads << [nil, read_on]
          elsif status == "read" then reads << [nil, nil]
          end

          yield({
            book: {
              title: col(row, "Title").to_s.sub(/\s*\([^()]*#\d+(\.\d+)?\)\z/, ""), # drop "(Series, #1)"
              authors: authors.uniq.join("; "),
              isbn13: ISBN.normalize(col(row, "ISBN13")) || ISBN.normalize(col(row, "ISBN")),
              publisher: col(row, "Publisher"),
              published_year: col(row, "Year Published")&.to_i,
              pages: col(row, "Number of Pages")&.to_i,
              format: format_from(col(row, "Binding")),
              status: status,
              owned: col(row, "Owned Copies").to_i.positive?,
              rating: rating(col(row, "My Rating")),
              review: clean_review(col(row, "My Review")),
              reviewed_on: read_on || date(col(row, "Date Added")),
              notes: col(row, "Private Notes"),
              tags: col(row, "Bookshelves").to_s.split(",").map(&:strip).reject { SHELVES.key?(_1) || _1 == shelf }.join(", "),
              added_on: date(col(row, "Date Added")),
              goodreads_id: col(row, "Book Id"),
              gr_avg_rating: col(row, "Average Rating")&.to_f&.then { _1.positive? ? _1 : nil }
            },
            reads: reads
          }, line)
        end
      end
    end
  end
end
