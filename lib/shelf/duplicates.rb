require "set"

module Shelf
  # Finds and merges duplicate books. Assumes one copy per book: two
  # editions of the same work count as duplicates.
  module Duplicates
    Group = Struct.new(:books, :reasons) do
      # The copy with the most of *your* data is the default keeper.
      def suggested_keeper
        books.max_by do |b|
          [b.reads.size + (b.rating ? 2 : 0) + (b.review.to_s.strip.empty? ? 0 : 2) +
             (b.isbn13 ? 1 : 0) + (b.cover_url ? 1 : 0), -b.id]
        end
      end
    end

    MATCH_ATTRS = %i[isbn13 title authors openlibrary_work goodreads_id].freeze

    REASONS = { "isbn" => "Same ISBN", "work" => "Same Open Library work",
                "gr" => "Same Goodreads book", "title" => "Same title & author" }.freeze

    MERGE_FILL = %i[isbn13 isbn10 title subtitle authors publisher published_year pages format cover_url
                    rating reviewed_on openlibrary_id openlibrary_work goodreads_id storygraph_id
                    gr_avg_rating ol_avg_rating ol_rating_count looked_up_at].freeze

    module_function

    def keys_for(b)
      keys = []
      keys << "isbn:#{b.isbn13}" if b.isbn13
      keys << "work:#{b.openlibrary_work}" unless b.openlibrary_work.to_s.empty?
      keys << "gr:#{b.goodreads_id}" unless b.goodreads_id.to_s.empty?
      t, a = b.match_key.split("|", 2)
      keys << "title:#{t}|#{a}" unless t.to_s.empty? || a.to_s.empty?
      keys
    end

    def dismissed_pairs
      DB[:not_duplicates].select_map(%i[book_a_id book_b_id]).to_set
    end

    def pair(a, b) = [a, b].minmax

    def groups
      books = Book.eager(:reads).all
      by_id = books.to_h { [_1.id, _1] }
      dismissed = dismissed_pairs
      parent = {} # union-find over book ids
      find = lambda do |x|
        parent[x] = x unless parent.key?(x)
        parent[x] == x ? x : (parent[x] = find.(parent[x]))
      end
      reasons = Hash.new { |h, k| h[k] = Set.new }

      buckets = Hash.new { |h, k| h[k] = [] }
      books.each { |b| keys_for(b).each { buckets[_1] << b.id } }
      buckets.each do |key, ids|
        ids.combination(2).each do |a, b|
          next if dismissed.include?(pair(a, b))
          parent[find.(a)] = find.(b)
          reasons[[a, b]] << REASONS[key.split(":").first]
        end
      end

      parent.keys.group_by { find.(_1) }.values.select { _1.size > 1 }.map do |ids|
        rs = reasons.select { |(a, b), _| ids.include?(a) && ids.include?(b) }.values.reduce(Set.new, :|)
        Group.new(ids.sort.map { by_id[_1] }, rs.to_a.sort)
      end.sort_by { _1.books.first.display_title.downcase }
    end

    def count = groups.size

    # An existing book that `book` duplicates, if any.
    def match_for(book)
      keys = keys_for(book)
      return nil if keys.empty?
      dismissed = dismissed_pairs
      Book.exclude(id: book.id).all.find do |other|
        !dismissed.include?(pair(book.id, other.id)) && (keys_for(other) & keys).any?
      end
    end

    def dismiss!(ids)
      ids = ids.map(&:to_i).uniq
      ids.combination(2).each do |a, b|
        DB[:not_duplicates].insert_conflict.insert(book_a_id: pair(a, b)[0], book_b_id: pair(a, b)[1])
      end
    end

    # Fold `others` into `keeper`. Nothing you entered is lost: blanks are
    # filled, reviews/notes are concatenated, tags unioned, reads and loans
    # moved over, and the most-advanced status wins.
    def merge!(keeper, others)
      others = Array(others).reject { _1.id == keeper.id }
      DB.transaction do
        others.each do |o|
          MERGE_FILL.each { |c| keeper[c] = o[c] if blank?(keeper[c]) && !blank?(o[c]) }
          %i[review notes].each do |c|
            parts = [keeper[c], o[c]].map { _1.to_s.strip }.reject(&:empty?).uniq
            keeper[c] = parts.empty? ? nil : parts.join("\n\n---\n\n")
          end
          keeper.tags = (keeper.tag_list | o.tag_list).join(", ").then { _1.empty? ? nil : _1 }
          keeper.owned ||= o.owned
          keeper.added_on = [keeper.added_on, o.added_on].compact.min
          if Book::STATUS_RANK.fetch(o.status, 0) > Book::STATUS_RANK.fetch(keeper.status, 0)
            keeper.status = o.status
          end

          have = keeper.reads.map(&:finished_on)
          o.reads.each do |r|
            if r.finished_on ? have.include?(r.finished_on) : have.any?
              r.destroy
            else
              r.update(book_id: keeper.id)
              have << r.finished_on
            end
          end
          DB[:borrows].where(book_id: o.id).update(book_id: keeper.id)

          o.destroy
          keeper.save_changes
          keeper.refresh
        end
      end
      keeper
    end

    def blank?(v) = v.nil? || v == ""
  end
end
