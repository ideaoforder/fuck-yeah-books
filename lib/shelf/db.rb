require "sequel"

module Shelf
  ROOT = File.expand_path("../..", __dir__)

  DB =
    if ENV["SHELF_DB"] == ":memory:"
      Sequel.sqlite
    else
      Sequel.sqlite(ENV.fetch("SHELF_DB") { File.join(ROOT, "db", "shelf.sqlite3") })
    end

  Sequel.extension :migration
  Sequel::Migrator.run(DB, File.join(ROOT, "db", "migrations"))
end
