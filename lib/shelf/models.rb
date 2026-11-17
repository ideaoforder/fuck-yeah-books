require "date"

module Shelf
  class Book < Sequel::Model(DB[:books])
    plugin :timestamps, update_on_create: true
    plugin :validation_helpers

    one_to_many :reads,   class: "Shelf::Read",   order: [Sequel.asc(:finished_on, nulls: :first), :id]
    one_to_many :borrows, class: "Shelf::Borrow", order: Sequel.desc(:borrowed_on)

    FORMATS  = %w[hardcover paperback ebook audiobook other].freeze
    STATUSES = { "want" => "Want to read", "reading" => "Reading", "read" => "Read", "dnf" => "Did not finish" }.freeze
    EDITABLE = %i[isbn13 title subtitle authors publisher published_year pages format cover_url
                  status owned rating review reviewed_on tags notes].freeze

    def self.match_key(title, authors)
      t = title.to_s.downcase.sub(/\s*[:(].*/, "").gsub(/[^a-z0-9]/, "")
      a = authors.to_s.split(/[;,]/).first.to_s.downcase.split.last.to_s.gsub(/[^a-z0-9]/, "")
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
    end

    def display_title = title.to_s.strip.empty? ? "ISBN #{isbn13}" : title
    def author_list   = authors.to_s.split(";").map(&:strip).reject(&:empty?)
    def tag_list      = tags.to_s.split(",").map(&:strip).reject(&:empty?)
    def last_read_on  = reads.map(&:finished_on).compact.max
    def current_borrow = borrows.find { _1.returned_on.nil? }
    def community_rating = gr_avg_rating || ol_avg_rating

    def cover_src(size = "M")
      cover_url || (isbn13 && "https://covers.openlibrary.org/b/isbn/#{isbn13}-#{size}.jpg?default=false")
    end

    # Fill in blanks from Open Library / Google Books, and refresh community
    # ratings. Never overwrites something you've already set.
    def enrich!
      meta = (isbn13 && Lookup.by_isbn(isbn13)) || {}
      if meta.empty? && !title.to_s.empty?
        meta = Lookup.search(title, author_list.first) || {}
      end
      meta.each { |k, v| self[k] = v if self[k].nil? || self[k] == "" }

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
