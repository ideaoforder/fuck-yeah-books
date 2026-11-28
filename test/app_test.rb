require_relative "test_helper"

class AppTest < ShelfTest
  include Rack::Test::Methods
  def app = Shelf::App

  def scan(code, **opts)
    post "/api/scan", JSON.generate({ code: code, **opts }), "CONTENT_TYPE" => "application/json"
    JSON.parse(last_response.body)
  end

  def test_scan_creates_and_enriches_from_open_library
    res = scan("9780547928227", status: "read")
    assert_equal "created", res["status"]
    b = Shelf::Book.first
    assert_equal ["The Hobbit", "J.R.R. Tolkien", "paperback", 300, "OL262758W", 4.26, 812, "read", true],
                 [b.title, b.authors, b.format, b.pages, b.openlibrary_work, b.ol_avg_rating, b.ol_rating_count, b.status, b.owned]
  end

  def test_scan_duplicate_and_invalid
    scan("9780547928227")
    assert_equal "exists", scan("054792822X")["status"] # ISBN-10 of the same book
    assert_equal "invalid", scan("12345")["status"]
    assert_equal 422, last_response.status
  end

  def test_scan_with_no_metadata_still_saves_stub
    res = scan("9780441013593")
    assert_equal "created", res["status"]
    assert_equal "ISBN 9780441013593", res["book"]["title"]
  end

  def test_pages_render
    Shelf::Enricher.import(fixture("goodreads_library_export.csv"))
    id = Shelf::Book.first(title: "Dune").id
    post "/books/#{id}/borrows", borrowed_by: "Sam"
    %W[/ /?status=read&sort=read /?q=herbert /books/#{id} /books/#{id}/edit /books/new /scan /borrows /compare /import].each do |path|
      get path
      assert last_response.ok?, "#{path} → #{last_response.status}\n#{last_response.body[0, 500]}"
    end
    get "/?q=herbert"
    assert_includes last_response.body, "Dune"
    refute_includes last_response.body, "Catching Fire"
    get "/compare"
    assert_includes last_response.body, "+0.73"
    get "/borrows"
    assert_includes last_response.body, "Sam"
  end

  def test_edit_review_and_log_read
    Shelf::Enricher.import(fixture("goodreads_library_export.csv"))
    b = Shelf::Book.first(title: "Catching Fire")
    patch "/books/#{b.id}", book: { title: "Catching Fire", rating: "3.75", review: "Better than the first.", status: "read" }
    assert last_response.redirect?
    post "/books/#{b.id}/reads", started_on: "2024-01-01", finished_on: "2024-01-09"
    b.refresh
    assert_equal [3.75, "Better than the first.", Date.today, "read", 1], [b.rating, b.review, b.reviewed_on, b.status, b.reads.size]
    refute b.owned, "unchecked checkbox clears owned"

    patch "/books/#{b.id}", book: { rating: "3.3" }
    assert_includes last_response.body, "quarter steps"

    get "/books/#{b.id}/review.json"
    review = JSON.parse(last_response.body)
    assert_equal ["Review", "Catching Fire", 3.75], [review["@type"], review.dig("itemReviewed", "name"), review.dig("reviewRating", "ratingValue")]
  end

  def test_borrow_lifecycle
    b = Shelf::Book.create(title: "Piranesi", authors: "Susanna Clarke")
    post "/books/#{b.id}/borrows", borrowed_by: "Mom", borrowed_on: "2026-11-01"
    loan = b.reload.current_borrow
    assert_equal "Mom", loan.borrowed_by
    post "/borrows/#{loan.id}/return", returned_on: "2026-11-15"
    assert_nil b.reload.current_borrow
    assert_equal 14, loan.reload.days_out
  end

  def test_exports
    Shelf::Enricher.import(fixture("goodreads_library_export.csv"))
    get "/export.json"
    assert_equal 3, JSON.parse(last_response.body)["itemListElement"].size
    assert_match(/attachment/, last_response.headers["Content-Disposition"])
    get "/export.csv"
    assert_equal 4, CSV.parse(last_response.body).size
  end

  def test_import_upload
    post "/import", file: Rack::Test::UploadedFile.new(File.join(FIXTURES, "storygraph_export.csv"), "text/csv")
    assert last_response.redirect?
    assert_equal 3, Shelf::Book.count
  end
  def test_inline_rating_requires_read_or_dnf
    b = Shelf::Book.create(title: "Piranesi", status: "want")
    patch "/books/#{b.id}/rating", rating: "4"
    assert_equal 422, last_response.status
    assert_match(/read/, JSON.parse(last_response.body)["error"])
    assert_nil b.refresh.rating

    b.update(status: "read")
    patch "/books/#{b.id}/rating", rating: "4.25"
    assert last_response.ok?, last_response.body
    assert_equal [4.25, "read"], JSON.parse(last_response.body).values_at("rating", "status")
    assert_equal [4.25, 0, Date.today], [b.refresh.rating, b.reads.size, b.reviewed_on]
  end

  def test_import_promotes_rated_to_read_books
    csv = File.read(File.join(FIXTURES, "goodreads_library_export.csv")).sub(",0,4.34,Scholastic", ",4,4.34,Scholastic")
    r = Shelf::Enricher.import(csv)
    assert_empty r.errors
    assert_equal ["read", 4.0], Shelf::Book.first(title: "Catching Fire").values.values_at(:status, :rating)
  end

  def test_inline_rating_keeps_dnf_and_can_clear
    b = Shelf::Book.create(title: "Gormenghast", status: "dnf", rating: 2.0)
    patch "/books/#{b.id}/rating", rating: ""
    assert_equal [nil, "dnf"], [b.refresh.rating, b.status]
  end

  def test_inline_rating_rejects_bad_values
    b = Shelf::Book.create(title: "X", status: "read")
    patch "/books/#{b.id}/rating", rating: "4.1"
    assert_equal 422, last_response.status
    patch "/books/#{b.id}/rating", rating: "lots"
    assert_equal 422, last_response.status
    assert_nil b.refresh.rating
  end

  def test_finish_json_and_html
    b = Shelf::Book.create(title: "X", status: "reading")
    header "Accept", "application/json"
    post "/books/#{b.id}/finish"
    assert_equal "read", JSON.parse(last_response.body)["status"]
    assert_equal [Date.today], b.refresh.reads.map(&:finished_on)

    header "Accept", "text/html"
    header "Referer", "/books/#{b.id}"
    post "/books/#{b.id}/finish"
    assert last_response.redirect?
  end

  def test_list_and_book_page_render_widgets
    b = Shelf::Book.create(title: "Widget Book", status: "read", rating: 3.5)
    w = Shelf::Book.create(title: "Unread Book", status: "want")
    get "/"
    assert_includes last_response.body, %(data-id="#{b.id}" data-rating="3.5")
    assert_includes last_response.body, %(data-rate-for="#{w.id}" hidden)
    assert_includes last_response.body, %(action="/books/#{w.id}/finish")
    refute_includes last_response.body, %(action="/books/#{b.id}/finish")
    get "/books/#{b.id}"
    assert_includes last_response.body, %(class="stars")
    get "/books/#{w.id}"
    refute_includes last_response.body, %(class="stars")
  end
  def test_borders_sticker_is_recognized
    res = scan("001629995600110000000003")
    assert_equal 422, last_response.status
    assert_equal ["invalid", true, "Store sticker, not an ISBN"], res.values_at("status", "sticker", "message")
    refute scan("12345")["sticker"], "short junk is just invalid"
    refute scan("978044101359351699")["sticker"], "ISBN + price add-on still scans"
  end

  def test_scanned_books_are_owned_and_owned_tab
    scan("9780547928227")
    assert Shelf::Book.first(isbn13: "9780547928227").owned
    unowned = Shelf::Book.create(title: "Library copy", status: "read")
    rescanned = Shelf::Book.create(title: "Dune", isbn13: "9780441013593")
    scan("9780441013593")
    assert rescanned.refresh.owned

    get "/?owned=1"
    assert_includes last_response.body, "The Hobbit"
    assert_includes last_response.body, "Dune"
    refute_includes last_response.body, "Library copy"
    assert_match(/All <small>2</, last_response.body, "tab counts follow the owned filter")

    get "/?owned=0"
    assert_includes last_response.body, "Library copy"
    refute_includes last_response.body, "Dune"

    get "/?status=owned" # old links still work
    refute_includes last_response.body, "Library copy"

    # owned + status compose
    get "/?owned=1&status=want"
    assert_includes last_response.body, "Dune"
    refute_includes last_response.body, "Library copy"
    assert_includes last_response.body, %(href="/?status=read&amp;owned=1")
    get "/?owned=1&status=read"
    assert_includes last_response.body, "Nothing matches"

    unowned.update(owned: true)
    get "/?owned=1&q=library"
    assert_includes last_response.body, "Library copy"
    assert_match(/All <small>1</, last_response.body, "tab counts follow search too")
  end

  def test_unknown_status_filter_shows_all
    Shelf::Book.create(title: "Anything")
    get "/?status=bogus"
    assert_includes last_response.body, "Anything"
  end

  def test_mark_unread_undoes_read
    b = Shelf::Book.create(title: "Oops", status: "want")
    b.add_read(finished_on: Date.new(2019, 1, 1))
    post "/books/#{b.id}/finish"                      # accidental ✓ Read
    patch "/books/#{b.id}/rating", rating: "3.5"
    b.refresh
    assert_equal ["read", 3.5, 2], [b.status, b.rating, b.reads.size]

    get "/books/#{b.id}"
    assert_includes last_response.body, "↺ Unread"
    assert_includes last_response.body, "removes your 3.5★ rating and the read logged today"

    post "/books/#{b.id}/unread"
    b.refresh
    assert_equal ["want", nil, [Date.new(2019, 1, 1)]], [b.status, b.rating, b.reads.map(&:finished_on)]
    get "/books/#{b.id}"
    refute_includes last_response.body, "↺ Unread"
  end

  def test_edit_status_off_read_clears_rating
    b = Shelf::Book.create(title: "Rated", status: "read", rating: 4.0, review: "Kept.")
    patch "/books/#{b.id}", book: { title: "Rated", status: "want", rating: "4.0", review: "Kept." }
    assert last_response.redirect?, last_response.body[0, 300]
    follow_redirect!
    assert_includes last_response.body, "Cleared your rating"
    assert_equal ["want", nil, "Kept."], [b.refresh.status, b.rating, b.review]

    # typing a *new* rating on an unread book is still an error
    patch "/books/#{b.id}", book: { status: "want", rating: "2" }
    assert_includes last_response.body, "books you&#39;ve read"
  end
end
