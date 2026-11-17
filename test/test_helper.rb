ENV["SHELF_DB"] = ":memory:"
ENV["APP_ENV"] = "test"
require "minitest/autorun"
require "rack/test"
require_relative "../app"

FIXTURES = File.join(__dir__, "fixtures")

# Canned Open Library responses so tests never touch the network.
FAKE_OL = {
  "https://openlibrary.org/api/books?bibkeys=ISBN:9780547928227&format=json&jscmd=data" => {
    "ISBN:9780547928227" => {
      "key" => "/books/OL25426716M", "title" => "The Hobbit",
      "authors" => [{ "name" => "J.R.R. Tolkien" }], "publishers" => [{ "name" => "Mariner" }],
      "publish_date" => "2012", "number_of_pages" => 300,
      "cover" => { "medium" => "https://covers.openlibrary.org/b/id/1-M.jpg" },
      "identifiers" => { "goodreads" => ["5907"] }
    }
  },
  "https://openlibrary.org/isbn/9780547928227.json" => { "physical_format" => "Paperback", "works" => [{ "key" => "/works/OL262758W" }] },
  "https://openlibrary.org/works/OL262758W/ratings.json" => { "summary" => { "average" => 4.256, "count" => 812 } }
}.freeze

Shelf::Lookup.http = ->(url) { FAKE_OL[url] }

class ShelfTest < Minitest::Test
  def setup
    %i[borrows reads books].each { Shelf::DB[_1].delete }
  end

  def fixture(name) = File.read(File.join(FIXTURES, name))
end
