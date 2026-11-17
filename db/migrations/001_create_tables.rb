Sequel.migration do
  change do
    create_table(:books) do
      primary_key :id
      String  :isbn13, index: true
      String  :isbn10
      String  :title
      String  :subtitle
      String  :authors                       # "; "-separated, first is primary
      String  :publisher
      Integer :published_year
      Integer :pages
      String  :format                        # hardcover paperback ebook audiobook other
      String  :cover_url
      String  :status, null: false, default: "want" # want reading read dnf
      TrueClass :owned, null: false, default: false

      Float   :rating                        # 0.25..5.0 in quarter steps
      String  :review, text: true
      Date    :reviewed_on
      String  :tags                          # comma-separated shelves/tags
      String  :notes, text: true             # private notes
      Date    :added_on

      String  :openlibrary_id                # edition, e.g. OL7353617M
      String  :openlibrary_work              # work, e.g. OL82563W
      String  :goodreads_id
      String  :storygraph_id                 # SG UID when there's no ISBN
      Float   :gr_avg_rating
      Float   :ol_avg_rating
      Integer :ol_rating_count
      DateTime :looked_up_at

      DateTime :created_at
      DateTime :updated_at
    end

    create_table(:reads) do
      primary_key :id
      foreign_key :book_id, :books, null: false, on_delete: :cascade, index: true
      Date :started_on
      Date :finished_on
    end

    create_table(:borrows) do
      primary_key :id
      foreign_key :book_id, :books, null: false, on_delete: :cascade, index: true
      String :borrowed_by, null: false
      Date   :borrowed_on, null: false
      Date   :returned_on
      String :notes
    end
  end
end
