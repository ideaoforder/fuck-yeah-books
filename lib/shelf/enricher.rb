module Shelf
  # Glue for the "add by ISBN" flow, import detection, and background
  # metadata backfills.
  module Enricher
    @state = { running: false, done: 0, total: 0 }
    @lock = Mutex.new

    class << self
      def status = @lock.synchronize { @state.dup }

      # => { status: "created"|"exists"|"invalid", book:, message: }
      def add_by_isbn(code, status: nil, format: nil, owned: false)
        isbn = ISBN.from_scan(code)
        return { status: "invalid", book: nil, message: "#{code.inspect} isn't a valid ISBN" } unless isbn

        if (book = Book.first(isbn13: isbn))
          return { status: "exists", book: book, message: "Already in your library: #{book.display_title}" }
        end

        book = Book.create(isbn13: isbn, status: Book::STATUSES.key?(status) ? status : "want",
                           format: Book::FORMATS.include?(format) ? format : nil, owned: !!owned)
        found = book.enrich!
        msg = found ? "Added #{book.display_title}" : "Added ISBN #{isbn} — no metadata found yet (try Refresh later)"
        { status: "created", book: book, message: msg, found: found }
      end

      def import(data)
        data = data.dup.force_encoding("UTF-8").delete_prefix("﻿")
        klass =
          if Importers::Booklog.detect?(data) then Importers::Booklog
          else
            headers = CSV.parse_line(data) || []
            [Importers::Goodreads, Importers::Storygraph].find { _1.detect?(headers) } or
              raise ArgumentError, "Unrecognized file. Expected a Goodreads or StoryGraph CSV, or Booklog JSON."
          end
        klass.call(data)
      end

      # Politely walks books that have never been looked up. One at a time,
      # with a pause, so we're a good Open Library citizen.
      # Books added by ISBN whose lookup found nothing (shown as "ISBN 978…").
      def placeholders = Book.exclude(isbn13: nil).where(Sequel.|({ title: nil }, { title: "" }))

      def enrich_all_in_background(scope = Book.where(looked_up_at: nil), pause: 0.5)
        ids = scope.select_map(:id)
        @lock.synchronize do
          return false if @state[:running] || ids.empty?
          @state = { running: true, done: 0, total: ids.size }
        end
        Thread.new do
          ids.each do |id|
            Book[id]&.enrich!
            @lock.synchronize { @state[:done] += 1 }
            sleep pause
          end
        ensure
          @lock.synchronize { @state[:running] = false }
        end
      end
    end
  end
end
