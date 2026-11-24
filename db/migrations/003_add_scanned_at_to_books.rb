# Books added by scanning are the physical copy you own, so they win as the
# canonical edition when duplicates are merged.
Sequel.migration do
  change do
    alter_table(:books) do
      add_column :scanned_at, DateTime
    end
  end
end
