require_relative "test_helper"

class DuplicatesTest < ShelfTest
  include Rack::Test::Methods
  include Shelf
  def app = Shelf::App

  def group_titles = Duplicates.groups.map { |g| g.books.map(&:id) }

  def test_match_key_normalization
    assert_equal Book.match_key("The Hobbit: or There and Back Again", "J. R. R. Tolkien"),
                 Book.match_key("Hobbit", "J.R.R. Tolkien")
    assert_equal Book.match_key("Cien años de soledad", "Gabriel García Márquez"),
                 Book.match_key("Cien Anos de Soledad", "Gabriel Garcia Marquez")
    assert_equal Book.match_key("Pride & Prejudice", "Jane Austen"), Book.match_key("Pride and Prejudice", "Jane Austen")
  end

  def test_finds_groups_by_isbn_work_and_title
    a = Book.create(title: "Underworld", authors: "Don DeLillo", isbn13: "9780330369954", openlibrary_work: "OL1W")
    b = Book.create(title: "Underworld: A Novel", authors: "Don DeLillo", isbn13: "9780684848150") # title match
    c = Book.create(title: "Underworld (Picador)", authors: "Someone Else", openlibrary_work: "OL1W") # work match
    Book.create(title: "Underworld", authors: "Different Author") # same title, other author: not a dup
    d = Book.create(title: "Piranesi", authors: "Susanna Clarke", goodreads_id: "50202953")
    e = Book.create(title: "Piranesi (Hardcover)", authors: "S. Clarke", goodreads_id: "50202953")

    groups = Duplicates.groups
    assert_equal [[d.id, e.id], [a.id, b.id, c.id]], groups.map { |g| g.books.map(&:id) } # sorted by title
    assert_equal ["Same Goodreads book", "Same title & author"], groups.first.reasons
    assert_equal ["Same Open Library work", "Same title & author"], groups.last.reasons
  end

  def test_dismiss_hides_pair
    a = Book.create(title: "Dune", authors: "Frank Herbert")
    b = Book.create(title: "Dune", authors: "Frank Herbert")
    Duplicates.dismiss!([a.id, b.id])
    assert_empty Duplicates.groups
    assert_nil Duplicates.match_for(a)
  end

  def test_merge_keeps_everything
    keep = Book.create(title: "Dune", authors: "Frank Herbert", status: "read", rating: 5.0,
                       review: "Spice.", tags: "sci-fi", added_on: Date.new(2021, 1, 1))
    keep.add_read(finished_on: Date.new(2021, 3, 14))
    other = Book.create(title: "Dune", authors: "Frank Herbert", isbn13: "9780441013593", status: "read",
                        rating: 4.0, review: "Worms.", tags: "sci-fi, favorites", owned: true,
                        cover_url: "https://x/c.jpg", added_on: Date.new(2019, 5, 1), notes: "lend to Sam")
    other.add_read(finished_on: Date.new(2021, 3, 14)) # same read, from the other import
    other.add_read(started_on: Date.new(2024, 5, 20), finished_on: Date.new(2024, 6, 2))
    other.add_borrow(borrowed_by: "Sam", borrowed_on: Date.new(2025, 1, 1))

    Duplicates.merge!(keep, [other])
    keep.refresh
    assert_nil Book[other.id]
    assert_equal [5.0, "9780441013593", "https://x/c.jpg", true, Date.new(2019, 5, 1), "lend to Sam"],
                 [keep.rating, keep.isbn13, keep.cover_url, keep.owned, keep.added_on, keep.notes]
    assert_equal "Spice.\n\n---\n\nWorms.", keep.review
    assert_equal "sci-fi, favorites", keep.tags
    assert_equal [Date.new(2021, 3, 14), Date.new(2024, 6, 2)], keep.reads.map(&:finished_on)
    assert_equal ["Sam"], keep.borrows.map(&:borrowed_by)
  end

  def test_merge_takes_most_finished_status
    keep = Book.create(title: "X", authors: "A B", status: "want")
    other = Book.create(title: "X", authors: "A B", status: "read", rating: 3.5)
    Duplicates.merge!(keep, [other])
    assert_equal ["read", 3.5], [keep.status, keep.rating]
  end

  def test_scanning_another_edition_merges_into_existing
    hobbit = Book.create(title: "The Hobbit", authors: "J.R.R. Tolkien", status: "read", rating: 4.5,
                         openlibrary_work: "OL262758W")
    res = Enricher.add_by_isbn("9780547928227") # FAKE_OL: same work
    assert_equal "exists", res[:status]
    assert_equal hobbit.id, res[:book].id
    assert_equal 1, Book.count
    assert_equal ["9780547928227", 4.5, "paperback"], hobbit.refresh.values.values_at(:isbn13, :rating, :format)
  end

  def test_import_matches_on_goodreads_id
    Book.create(title: "Dune: Deluxe Edition", authors: "F. Herbert", goodreads_id: "234225")
    r = Enricher.import(fixture("goodreads_library_export.csv"))
    assert_equal [2, 1], [r.created, r.updated]
  end

  def test_pages_and_actions
    a = Book.create(title: "Dune", authors: "Frank Herbert", status: "read", rating: 4.0)
    b = Book.create(title: "Dune", authors: "Frank Herbert", isbn13: "9780441013593")
    get "/duplicates"
    assert last_response.ok?
    assert_includes last_response.body, %(name="keep" value="#{a.id}" checked)
    get "/books/#{b.id}"
    assert_includes last_response.body, "Looks like a duplicate"
    get "/import"
    assert_includes last_response.body, "1 possible duplicate group"

    post "/duplicates/merge", keep: a.id, ids: [a.id, b.id]
    assert last_response.redirect?
    assert_equal [a.id], Book.select_map(:id)
    assert_equal "9780441013593", a.refresh.isbn13

    c = Book.create(title: "Dune", authors: "Frank Herbert")
    post "/duplicates/dismiss", ids: [a.id.to_s, c.id.to_s]
    assert_empty Duplicates.groups
  end
end
