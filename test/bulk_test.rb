require_relative "test_helper"

class BulkTest < ShelfTest
  include Rack::Test::Methods
  include Shelf
  def app = Shelf::App

  def books
    @a = Book.create(title: "A", status: "want", tags: "family")
    @b = Book.create(title: "B", status: "read", rating: 4.0)
    @c = Book.create(title: "C", status: "reading", owned: true)
  end

  def test_set_status_skips_books_that_cant_take_it
    books
    r = Bulk.apply([@a.id, @b.id, @c.id], "status", "not_interested")
    assert_equal [2, 1], [r.changed, r.skipped]
    assert_match(/skipped: B is rated \(clear the rating first\)/, r.to_s)
    assert_equal %w[not_interested read not_interested], [@a, @b, @c].map { _1.refresh.status }
  end

  def test_owned_tags_delete
    books
    Bulk.apply([@a.id, @b.id], "owned")
    assert_equal [true, true, true], [@a, @b, @c].map { _1.refresh.owned }
    Bulk.apply([@c.id], "unowned")
    refute @c.refresh.owned

    Bulk.apply([@a.id, @b.id], "add_tag", "kids")
    assert_equal ["family, kids", "kids"], [@a.refresh.tags, @b.refresh.tags]
    Bulk.apply([@a.id, @b.id], "remove_tag", "KIDS")
    assert_equal ["family", nil], [@a.refresh.tags, @b.refresh.tags]

    @b.add_read(finished_on: Date.today)
    r = Bulk.apply([@b.id, @c.id], "delete")
    assert_equal 2, r.changed
    assert_equal [@a.id], Book.select_map(:id)
    assert_equal 0, Read.count
  end

  def test_rejects_unknown_action_and_missing_value
    assert_raises(ArgumentError) { Bulk.apply([1], "explode") }
    assert_raises(ArgumentError) { Bulk.apply([1], "add_tag", " ") }
  end

  def test_bulk_route
    books
    header "Referer", "/?status=owned"
    post "/books/bulk", ids: [@a.id, @c.id], bulk_action: "status", value: "not_interested"
    assert last_response.redirect?
    assert_equal "/?status=owned", URI(last_response.location).request_uri
    assert_equal %w[not_interested not_interested], [@a, @c].map { _1.refresh.status }
    follow_redirect!
    assert_includes last_response.body, "2 books updated"

    post "/books/bulk", bulk_action: "owned"
    follow_redirect!
    assert_includes last_response.body, "Select some books first."
  end

  def test_list_has_bulk_controls_and_not_interested_tab
    books
    Bulk.apply([@a.id], "status", "not_interested")
    get "/"
    assert_includes last_response.body, %(id="bulk")
    assert_includes last_response.body, %(name="ids[]" value="#{@a.id}" form="bulk")
    assert_includes last_response.body, %(<option value="family">)
    get "/?status=not_interested"
    assert_includes last_response.body, "Not interested <small>1"
    assert_includes last_response.body, %(>A</a>)
    refute_includes last_response.body, %(>C</a>)
  end

  def test_not_interested_roundtrips_and_survives_reimport
    Enricher.import(fixture("goodreads_library_export.csv"))
    cf = Book.first(title: "Catching Fire")
    cf.update(status: "not_interested")

    # Re-importing the old to-read shelf doesn't undo it…
    Enricher.import(fixture("goodreads_library_export.csv"))
    assert_equal "not_interested", cf.refresh.status

    # …and it survives a Goodreads-CSV and Booklog round trip.
    csv = Exporters::GoodreadsCsv.call(Book.order(:id).all)
    assert_match(/Catching Fire.*not-interested/, csv)
    json = JSON.generate(Booklog.export(Book.order(:id).all))
    setup
    Enricher.import(csv)
    assert_equal "not_interested", Book.first(title: "Catching Fire").status
    setup
    Enricher.import(json)
    assert_equal "not_interested", Book.first(title: "Catching Fire").status
  end

  def test_not_interested_cannot_be_rated
    b = Book.create(title: "X", status: "not_interested")
    refute b.rateable?
    patch "/books/#{b.id}/rating", rating: "3"
    assert_equal 422, last_response.status
  end
end
