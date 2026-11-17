require_relative "test_helper"

class SchemaTest < ShelfTest
  def schemer
    require "json_schemer"
    JSONSchemer.schema(Pathname(File.join(Shelf::ROOT, "public/schema/booklog.schema.json")))
  rescue LoadError
    skip "json_schemer not installed"
  end

  def test_exports_validate_against_schema
    s = schemer
    Shelf::Enricher.import(fixture("goodreads_library_export.csv"))
    Shelf::Enricher.import(fixture("storygraph_export.csv"))
    books = Shelf::Book.order(:id).all
    doc = JSON.parse(JSON.generate(Shelf::Booklog.export(books)))
    assert s.valid?(doc), s.validate(doc).map { _1["error"] }.first(3).join("\n")
    review = JSON.parse(JSON.generate(Shelf::Booklog.review(books.first)))
    assert s.valid?(review)
  end

  def test_bundled_example_is_valid
    s = schemer
    assert s.valid?(JSON.parse(File.read(File.join(Shelf::ROOT, "public/schema/example.booklog.json"))))
  end
end
