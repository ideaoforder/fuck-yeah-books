require_relative "test_helper"

class AddSearchTest < ShelfTest
  include Rack::Test::Methods
  include Shelf
  def app = Shelf::App

  OL_SEARCH = { "docs" => [
    { "key" => "/works/OL1921185W", "title" => "Underworld", "author_name" => ["Don DeLillo"],
      "first_publish_year" => 1997, "cover_i" => 8231856, "edition_count" => 41 },
    { "key" => "/works/OL99W", "title" => "Underworld USA", "author_name" => ["Someone"], "first_publish_year" => 2003 }
  ] }.freeze
  GB_SEARCH = { "items" => [
    { "volumeInfo" => { "title" => "Underworld", "authors" => ["Don DeLillo"], "publishedDate" => "1998" } }, # dup of OL
    { "volumeInfo" => { "title" => "Underworld: Stories", "authors" => ["Other Person"], "publishedDate" => "2010",
                        "industryIdentifiers" => [{ "type" => "ISBN_13", "identifier" => "9780441013593" }],
                        "imageLinks" => { "thumbnail" => "http://books.google.com/c?zoom=1&edge=curl" } } }
  ] }.freeze

  def setup
    super
    @old_key = ENV["GOOGLE_BOOKS_API_KEY"]
    ENV["GOOGLE_BOOKS_API_KEY"] = "k"
    Lookup.http = lambda do |url|
      case url
      when /openlibrary\.org\/search\.json\?q=/ then OL_SEARCH
      when /googleapis.*volumes\?q=/ then GB_SEARCH
      when %r{works/OL1921185W/ratings} then { "summary" => { "average" => 3.9, "count" => 120 } }
      end
    end
  end

  def teardown
    ENV["GOOGLE_BOOKS_API_KEY"] = @old_key
    Lookup.http = ->(url) { FAKE_OL[url] }
  end

  def test_search_merges_sources_and_drops_cross_source_dupes
    r = Lookup.search_books("delillo underworld")
    assert_equal [["openlibrary", "Underworld"], ["openlibrary", "Underworld USA"], ["google", "Underworld: Stories"]],
                 r.map { [_1[:source], _1[:title]] }
    assert_equal ["OL1921185W", 41, 1997, "https://covers.openlibrary.org/b/id/8231856-M.jpg"],
                 r[0].values_at(:openlibrary_work, :editions, :year, :cover_url)
    assert_equal ["9780441013593", "https://books.google.com/c?zoom=1"], r[2].values_at(:isbn13, :cover_url)
    assert_empty Lookup.search_books("ab")
  end

  def test_api_search_flags_books_already_in_library
    b = Book.create(title: "Underworld", authors: "Don DeLillo")
    get "/api/search", q: "underworld"
    res = JSON.parse(last_response.body)
    assert_equal ["/books/#{b.id}", nil, nil], res.map { _1["in_library"] }
  end

  def test_adding_a_pick_without_isbn
    get "/api/search", q: "underworld"
    pick = JSON.parse(last_response.body).first
    post "/api/books", JSON.generate(pick: pick, status: "read", owned: true), "CONTENT_TYPE" => "application/json"
    data = JSON.parse(last_response.body)
    assert_equal "created", data["status"]
    b = Book.first
    assert_equal "/books/#{b.id}", data["url"]
    assert_equal ["Underworld", "Don DeLillo", nil, "OL1921185W", 1997, "read", true, 3.9],
                 b.values.values_at(:title, :authors, :isbn13, :openlibrary_work, :published_year, :status, :owned, :ol_avg_rating)
    assert b.scanned_at, "picked copy counts as the one you own"
  end

  def test_pick_absorbs_existing_entry
    old = Book.create(title: "Underworld", authors: "Don DeLillo", status: "read", rating: 4.0, goodreads_id: "11755")
    res = Enricher.add_from_search(OL_SEARCH["docs"].first.then {
      { title: _1["title"], authors: "Don DeLillo", openlibrary_work: "OL1921185W", year: 1997 } })
    assert_equal "merged", res[:status]
    assert_equal 1, Book.count
    refute_equal old.id, res[:book].id
    assert_equal [4.0, "11755", "OL1921185W"], res[:book].refresh.values.values_at(:rating, :goodreads_id, :openlibrary_work)
  end

  def test_pick_with_existing_isbn
    b = Book.create(title: "Dune", isbn13: "9780441013593")
    res = Enricher.add_from_search({ "title" => "Dune", "isbn13" => "9780441013593" })
    assert_equal ["exists", b.id], [res[:status], res[:book].id]
  end

  def test_add_page_renders_finder
    get "/books/new"
    assert_includes last_response.body, %(id="finder")
    assert_includes last_response.body, "and Google Books"
  end
end
