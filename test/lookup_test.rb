require_relative "test_helper"

class LookupTest < ShelfTest
  ISBN = "9781250448194"

  def with_http(responses)
    calls = []
    Shelf::Lookup.http = ->(url) { calls << url; responses.find { |pat, _| url.include?(pat) }&.last }
    yield calls
  ensure
    Shelf::Lookup.http = ->(url) { FAKE_OL[url] }
  end

  def with_env(key, value)
    old = ENV[key]
    ENV[key] = value
    yield
  ensure
    ENV[key] = old
  end

  def test_falls_back_to_open_library_search
    search = { "docs" => [{ "key" => "/works/OL1W", "title" => "Found Via Search", "author_name" => ["A. Writer"],
                            "cover_i" => 42, "ratings_average" => 3.912, "ratings_count" => 7 }] }
    with_http("search.json?isbn=#{ISBN}" => search) do
      meta = Shelf::Lookup.by_isbn(ISBN)
      assert_equal ["Found Via Search", "A. Writer", "OL1W", 3.91, "https://covers.openlibrary.org/b/id/42-M.jpg"],
                   meta.values_at(:title, :authors, :openlibrary_work, :ol_avg_rating, :cover_url)
    end
  end

  def test_google_books_is_skipped_without_a_key
    with_env("GOOGLE_BOOKS_API_KEY", nil) do
      with_http({}) do |calls|
        assert_nil Shelf::Lookup.by_isbn(ISBN)
        refute calls.any? { _1.include?("googleapis") }
      end
    end
  end

  def test_google_books_uses_key
    gb = { "items" => [{ "volumeInfo" => { "title" => "From Google", "authors" => ["G. Author"], "pageCount" => 300 } }] }
    with_env("GOOGLE_BOOKS_API_KEY", "abc123") do
      with_http("googleapis.com" => gb) do |calls|
        assert_equal "From Google", Shelf::Lookup.by_isbn(ISBN)[:title]
        assert calls.any? { _1.include?("&key=abc123") }
      end
    end
  end

  def test_placeholders_can_be_retried
    stub = Shelf::Book.create(isbn13: ISBN, looked_up_at: Time.now)
    Shelf::Book.create(title: "Has a title", isbn13: "9780441013593")
    assert_equal [stub.id], Shelf::Enricher.placeholders.select_map(:id)

    search = { "docs" => [{ "key" => "/works/OL1W", "title" => "Now Found" }] }
    with_http("search.json?isbn=" => search) do
      Shelf::Enricher.enrich_all_in_background(Shelf::Enricher.placeholders, pause: 0)
      sleep 0.05 while Shelf::Enricher.status[:running]
    end
    assert_equal "Now Found", stub.refresh.title
    assert_equal 0, Shelf::Enricher.placeholders.count
  end
end
