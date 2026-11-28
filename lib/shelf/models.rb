require "date"

module Shelf
  class Book < Sequel::Model(DB[:books])
    plugin :timestamps, update_on_create: true
    plugin :validation_helpers

    one_to_many :reads,   class: "Shelf::Read",   order: [Sequel.asc(:finished_on, nulls: :first), :id]
    one_to_many :borrows, class: "Shelf::Borrow", order: Sequel.desc(:borrowed_on)

    FORMATS  = %w[hardcover paperback ebook audiobook other].freeze
    STATUSES = { "want" => "Want to read", "reading" => "Reading", "read" => "Read", "dnf" => "Did not finish",
                 "not_interested" => "Not interested" }.freeze
    EDITABLE = %i[isbn13 title subtitle authors publisher published_year pages format cover_url
                  status owned rating review reviewed_on tags notes].freeze

    # Used when merging/importing: higher wins. "Not interested" ties with "want",
    # so re-importing an old to-read shelf never overrides your choice.
    STATUS_RANK = { "not_interested" => 0, "want" => 0, "reading" => 1, "dnf" => 2, "read" => 3 }.freeze

    # "The Hobbit: or There and Back Again" + "J. R. R. Tolkien" → "hobbit|tolkien"
    def self.match_key(title, authors)
      fold = ->(s) { s.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub("&", " and ") }
      t = fold.(title).sub(/\s*[:(\[].*/, "").sub(/\A\s*(the|a|an)\s+/, "").gsub(/[^a-z0-9]/, "")
      a = fold.(authors.to_s.split(/[;,]/).first).split.last.to_s.gsub(/[^a-z0-9]/, "")
      "#{t}|#{a}"
    end

    def match_key = self.class.match_key(title, authors)

    def before_validation
      self.isbn13 = ISBN.normalize(isbn13) if isbn13
      self.isbn10 ||= ISBN.to10(isbn13)
      self.format = nil if format.to_s.empty?
      self.status = "want" if status.to_s.empty?
      super
    end

    def before_save
      changed = changed_columns
      if (changed.include?(:review) || changed.include?(:rating)) && !changed.include?(:reviewed_on) &&
         (review.to_s.strip != "" || rating)
        self.reviewed_on = Date.today
      end
      self.added_on ||= Date.today
      super
    end

    def validate
      super
      errors.add(:title, "or a valid ISBN is required") if title.to_s.strip.empty? && isbn13.nil?
      validates_includes STATUSES.keys, :status
      validates_includes FORMATS, :format, allow_nil: true
      if rating && !(rating > 0 && rating <= 5 && (rating * 4 % 1).zero?)
        errors.add(:rating, "must be between 0.25 and 5, in quarter steps")
      end
      if rating && !rateable?
        errors.add(:rating, "can only be set on books you've read (or DNF'd)")
      end
    end

    def display_title = title.to_s.strip.empty? ? "ISBN #{isbn13}" : title
    def author_list   = authors.to_s.split(";").map(&:strip).reject(&:empty?)
    def tag_list      = tags.to_s.split(",").map(&:strip).reject(&:empty?)
    def last_read_on  = reads.map(&:finished_on).compact.max
    def current_borrow = borrows.find { _1.returned_on.nil? }
    def community_rating = gr_avg_rating || ol_avg_rating

    # size: "M" (~180px wide) or "L" (~500px). Open Library covers are stored
    # at M and resized on request; other sources are used as stored.
    def cover_src(size = "M")
      if cover_url.to_s.match?(%r{covers\.openlibrary\.org/.*-[SML]\.jpg})
        cover_url.sub(/-[SML]\.jpg/, "-#{size}.jpg")
      else
        cover_url || (isbn13 && "https://covers.openlibrary.org/b/isbn/#{isbn13}-#{size}.jpg?default=false")
      end
    end

    # Fill in blanks from Open Library / Google Books, and refresh community
    # ratings. Never overwrites something you've already set.
    def enrich!
      meta = (isbn13 && Lookup.by_isbn(isbn13)) || {}
      if meta.empty? && !title.to_s.empty?
        meta = Lookup.search(title, author_list.first) || {}
      end
      meta.each { |k, v| self[k] = v if self[k].nil? || self[k] == "" }
      self.cover_url = meta[:cover_url] if meta[:cover_url] && Lookup.low_res_cover?(cover_url)
      if cover_url.to_s.empty?
        self.cover_url = Lookup.fallback_cover(isbn: isbn13, work: openlibrary_work || meta[:openlibrary_work])
      end

      work = openlibrary_work || meta[:openlibrary_work]
      if work && (r = Lookup.ratings(work))
        set(r)
      elsif meta[:ol_avg_rating]
        set(meta.slice(:ol_avg_rating, :ol_rating_count))
      end

      self.looked_up_at = Time.now
      save_changes(validate: false)
      !meta.empty?
    end

    RATEABLE = %w[read dnf].freeze

    def rateable? = RATEABLE.include?(status)

    # Inline rating. nil clears it.
    def rate!(value)
      self.rating = value
      save_changes
    end

    # Undo "read": back to want (or reading), drop the rating (ratings are for
    # read books), and remove a read finished today (an accidental ✓ Read).
    # Older reads and the review text are kept.
    def unread!(new_status = "want")
      raise ArgumentError, "#{new_status} isn't an unread status" if RATEABLE.include?(new_status)
      DB.transaction do
        reads_dataset.where(finished_on: Date.today).delete
        self.rating = nil
        self.status = new_status
        save_changes
      end
      refresh
    end

    # Record a finished read (or start one) and bump status accordingly.
    def log_read!(started_on: nil, finished_on: nil)
      add_read(started_on: started_on, finished_on: finished_on)
      update(status: finished_on ? "read" : "reading")
    end
  end

  class Read < Sequel::Model(DB[:reads])
    many_to_one :book, class: "Shelf::Book"
  end

  class Borrow < Sequel::Model(DB[:borrows])
    plugin :validation_helpers
    many_to_one :book, class: "Shelf::Book"

    def validate
      super
      validates_presence %i[borrowed_by borrowed_on]
    end

    def days_out = ((returned_on || Date.today) - borrowed_on).to_i
  end
end
