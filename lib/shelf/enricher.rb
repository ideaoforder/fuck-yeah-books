module Shelf
  # Glue for the "add by ISBN" flow, import detection, and background
  # metadata backfills.
  module Enricher
    @state = { running: false, done: 0, total: 0 }
    @lock = Mutex.new

    class << self
      def status = @lock.synchronize { @state.dup }

      # => { status: "created"|"exists"|"invalid", book:, message: }
      def add_by_isbn(code, status: nil, format: nil)
        isbn = ISBN.from_scan(code)
        unless isbn
          return { status: "invalid", book: nil, sticker: store_sticker?(code),
                   message: store_sticker?(code) ? "Store sticker, not an ISBN" : "#{code.inspect} isn't a valid ISBN" }
        end

        if (book = Book.first(isbn13: isbn))
          book.update(scanned_at: Time.now, owned: true)
          return { status: "exists", book: book, message: "Already in your library: #{book.display_title}" }
        end

        # Scanned means it's in your hands, so it's owned.
        book = Book.create(isbn13: isbn, status: Book::STATUSES.key?(status) ? status : "want",
                           format: Book::FORMATS.include?(format) ? format : nil, owned: true,
                           scanned_at: Time.now)
        found = book.enrich!

        if found && (merged = absorb_duplicates(book))
          return { status: "merged", book: book, found: true, message: "Merged with your existing entry for #{merged}" }
        end

        msg = found ? "Added #{book.display_title}" : "Added ISBN #{isbn}. No metadata found yet (try Refresh later)"
        { status: "created", book: book, message: msg, found: found }
      end

      # Retailer price stickers (Borders' 24-digit BINC labels, etc.) encode
      # an internal SKU, not the ISBN, so there's nothing to look up.
      def store_sticker?(code)
        d = code.to_s.gsub(/\D/, "")
        d.length == 24 || (d.length > 13 && ![15, 18].include?(d.length))
      end

      # Add a pick from the typeahead (often an older book with no barcode).
      # Like a scan, it's the copy you own, so it's canonical.
      SEARCH_ATTRS = %i[title subtitle authors openlibrary_work isbn13 cover_url publisher pages].freeze

      def add_from_search(pick, status: nil)
        pick = pick.transform_keys(&:to_sym)
        attrs = pick.slice(*SEARCH_ATTRS).reject { |_, v| v.nil? || v.to_s.empty? }
        attrs[:published_year] = pick[:year].to_i if pick[:year].to_s.match?(/\A\d{3,4}\z/)
        attrs[:isbn13] = ISBN.normalize(attrs[:isbn13]) if attrs[:isbn13]

        if attrs[:isbn13] && (book = Book.first(isbn13: attrs[:isbn13]))
          book.update(scanned_at: Time.now, owned: true)
          return { status: "exists", book: book, message: "Already in your library: #{book.display_title}" }
        end

        book = Book.create(**attrs, status: Book::STATUSES.key?(status) ? status : "want",
                                    owned: true, scanned_at: Time.now)
        book.enrich!
        if (merged = absorb_duplicates(book))
          return { status: "merged", book: book, message: "Merged with your existing entry for #{merged}" }
        end
        { status: "created", book: book, message: "Added #{book.display_title}" }
      end

      # Another edition of something already on the shelf. The new (scanned
      # or picked) copy is canonical: it keeps its edition details and absorbs
      # your rating, review, reads, loans and tags from the old entry.
      # => title of the first entry merged in, or nil.
      def absorb_duplicates(book)
        merged = nil
        while (existing = Duplicates.match_for(book))
          merged ||= existing.display_title
          Duplicates.merge!(book, [existing])
        end
        merged
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
