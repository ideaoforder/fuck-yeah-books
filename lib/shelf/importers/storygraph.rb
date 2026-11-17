module Shelf
  module Importers
    # StoryGraph: Manage Account → Export StoryGraph Library.
    # Header names are matched loosely since SG has tweaked them over time.
    class Storygraph < Base
      STATUSES = { "read" => "read", "currently-reading" => "reading", "to-read" => "want",
                   "did-not-finish" => "dnf", "paused" => "reading" }.freeze
      DATE = %r{\d{4}/\d{1,2}/\d{1,2}}

      def self.detect?(headers) = headers.include?("ISBN/UID") || headers.include?("Star Rating")

      def each_record
        csv_rows.each do |row, line|
          uid = col(row, "ISBN/UID", "ISBN")
          isbn = ISBN.normalize(uid)
          status = STATUSES.fetch(col(row, "Read Status").to_s.downcase, "want")
          reads = parse_reads(col(row, "Dates Read"), col(row, "Last Date Read"))
          reads << [nil, nil] if reads.empty? && status == "read"

          yield({
            book: {
              title: col(row, "Title"),
              authors: col(row, "Authors", "Author").to_s.split(/,\s*/).join("; "),
              isbn13: isbn,
              storygraph_id: isbn ? nil : uid,
              format: format_from(col(row, "Format")),
              status: status,
              owned: col(row, "Owned?", "Owned").to_s.match?(/\Ay/i),
              rating: rating(col(row, "Star Rating")),
              review: clean_review(col(row, "Review")),
              reviewed_on: reads.map(&:last).compact.max || date(col(row, "Date Added")),
              tags: col(row, "Tags"),
              added_on: date(col(row, "Date Added"))
            },
            reads: reads
          }, line)
        end
      end

      private

      # "2023/01/05-2023/01/10, 2024/02/01" → [[start, end], [nil, end]]
      def parse_reads(dates_read, last_read)
        reads = dates_read.to_s.split(/,\s*/).filter_map do |chunk|
          ds = chunk.scan(DATE).map { date(_1) }
          next if ds.empty?
          ds.size >= 2 ? [ds[0], ds[1]] : [nil, ds[0]]
        end
        reads << [nil, date(last_read)] if reads.empty? && date(last_read)
        reads
      end
    end
  end
end
