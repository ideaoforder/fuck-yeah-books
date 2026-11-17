require_relative "test_helper"

class ImportExportTest < ShelfTest
  include Shelf

  def test_goodreads_import
    r = Enricher.import(fixture("goodreads_library_export.csv"))
    assert_equal [3, 0, []], [r.created, r.updated, r.errors]

    dune = Book.first(isbn13: "9780441013593")
    assert_equal "Dune", dune.title # series suffix stripped
    assert_equal 5.0, dune.rating
    assert_equal 4.27, dune.gr_avg_rating
    assert_equal "Spice.\n\nWorms & politics.", dune.review
    assert_equal "paperback", dune.format
    assert_equal "sci-fi, favorites", dune.tags
    assert dune.owned
    assert_equal [Date.new(2021, 3, 14)], dune.reads.map(&:finished_on)

    omens = Book.first(title: "Good Omens")
    assert_nil omens.isbn13
    assert_equal ["Terry Pratchett", "Neil Gaiman"], omens.author_list
    assert_equal "ebook", omens.format

    cf = Book.first(title: "Catching Fire")
    assert_equal "want", cf.status
    assert_nil cf.rating
  end

  def test_storygraph_merges_into_goodreads_import
    Enricher.import(fixture("goodreads_library_export.csv"))
    r = Enricher.import(fixture("storygraph_export.csv"))
    assert_equal [2, 1], [r.created, r.updated]

    dune = Book.first(isbn13: "9780441013593")
    assert_equal 5.0, dune.rating, "existing rating is kept"
    assert_equal [[nil, Date.new(2021, 3, 14)], [Date.new(2024, 5, 20), Date.new(2024, 6, 2)]],
                 dune.reads.map { [_1.started_on, _1.finished_on] }, "same finish date isn't duplicated"

    pira = Book.first(title: "Piranesi")
    assert_equal 4.5, pira.rating
    assert_equal [[Date.new(2023, 2, 10), Date.new(2023, 2, 19)]], pira.reads.map { [_1.started_on, _1.finished_on] }

    wolfe = Book.first(title: "The Book of the New Sun")
    assert_equal ["dnf", "a1b2c3d4-uid", "ebook"], [wolfe.status, wolfe.storygraph_id, wolfe.format]
  end

  def test_reimport_is_idempotent
    Enricher.import(fixture("goodreads_library_export.csv"))
    r = Enricher.import(fixture("goodreads_library_export.csv"))
    assert_equal [0, 3], [r.created, r.updated]
    assert_equal 3, Book.count
    assert_equal 2, Read.count
  end

  def test_booklog_json_roundtrip_is_lossless
    Enricher.import(fixture("goodreads_library_export.csv"))
    Enricher.import(fixture("storygraph_export.csv"))
    Book.first(title: "Piranesi").add_borrow(borrowed_by: "Sam", borrowed_on: Date.new(2024, 1, 2))
    Book.first(title: "Piranesi").update(notes: "lend to mom next", rating: 4.25)
    first = Booklog.export(Book.order(:id).all)

    setup # wipe
    r = Enricher.import(JSON.generate(first))
    assert_equal 5, r.created
    second = Booklog.export(Book.order(:id).all)

    strip = ->(doc) { doc.merge("dateCreated" => nil) }
    assert_equal strip.(first), strip.(second)
  end

  def test_goodreads_csv_roundtrip
    Enricher.import(fixture("goodreads_library_export.csv"))
    Enricher.import(fixture("storygraph_export.csv"))
    csv = Exporters::GoodreadsCsv.call(Book.order(:id).all)
    assert_equal Exporters::GoodreadsCsv::HEADERS, CSV.parse_line(csv)

    before = Book.order(:id).map { [_1.title, _1.isbn13, _1.status, _1.rating&.round(half: :up)&.to_f, _1.last_read_on] }
    setup
    Enricher.import(csv)
    after = Book.order(:id).map { [_1.title, _1.isbn13, _1.status, _1.rating, _1.last_read_on] }
    assert_equal before, after
  end

  def test_standalone_schema_org_review_import
    json = {
      "@context" => "https://schema.org", "@type" => "Review",
      "itemReviewed" => { "@type" => "Book", "name" => "Middlemarch", "author" => [{ "name" => "George Eliot" }] },
      "reviewRating" => { "@type" => "Rating", "ratingValue" => 9, "bestRating" => 10, "worstRating" => 1 },
      "reviewBody" => "Long, worth it."
    }
    Enricher.import(JSON.generate(json))
    b = Book.first(title: "Middlemarch")
    assert_equal [4.5, "Long, worth it.", "read"], [b.rating, b.review, b.status]
  end

  def test_unknown_file_is_rejected
    assert_raises(ArgumentError) { Enricher.import("foo,bar\n1,2\n") }
  end
end
