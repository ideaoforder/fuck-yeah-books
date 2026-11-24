# Pairs you've told us are *not* the same book, so they stop showing up.
Sequel.migration do
  change do
    create_table(:not_duplicates) do
      foreign_key :book_a_id, :books, null: false, on_delete: :cascade
      foreign_key :book_b_id, :books, null: false, on_delete: :cascade
      primary_key %i[book_a_id book_b_id]
    end
  end
end
