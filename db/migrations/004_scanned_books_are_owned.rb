# Anything scanned (or added by ISBN/search) is a copy you have in hand.
Sequel.migration do
  up do
    from(:books).exclude(scanned_at: nil).update(owned: true)
  end

  down do
    # data-only; nothing to undo
  end
end
