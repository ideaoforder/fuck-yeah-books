module Shelf
  # Bulk edits from the library list. Each book is updated on its own, so a
  # book that can't take the change (e.g. a rated book set back to "want")
  # is skipped and reported instead of failing the batch.
  module Bulk
    ACTIONS = {
      "status" => "Set status", "owned" => "Mark owned", "unowned" => "Mark not owned",
      "add_tag" => "Add tag", "remove_tag" => "Remove tag", "delete" => "Delete"
    }.freeze

    Result = Struct.new(:changed, :skipped, :errors) do
      def to_s
        msg = "#{changed} #{changed == 1 ? 'book' : 'books'} updated"
        msg += ". #{skipped} skipped: #{errors.uniq.first(2).join('; ')}" if skipped.positive?
        msg
      end
    end

    module_function

    def apply(ids, action, value = nil)
      raise ArgumentError, "Unknown action #{action.inspect}" unless ACTIONS.key?(action)
      value = value.to_s.strip
      raise ArgumentError, "#{ACTIONS[action]} needs a value" if %w[status add_tag remove_tag].include?(action) && value.empty?

      result = Result.new(0, 0, [])
      DB.transaction do
        Book.where(id: Array(ids).map(&:to_i)).each do |book|
          case action
          when "delete" then book.destroy
          when "status" then book.status = value
          when "owned" then book.owned = true
          when "unowned" then book.owned = false
          when "add_tag" then book.tags = (book.tag_list | [value]).join(", ")
          when "remove_tag" then book.tags = (book.tag_list.reject { _1.casecmp?(value) }).join(", ").then { _1.empty? ? nil : _1 }
          end
          next result.changed += 1 if action == "delete"

          if book.valid?
            result.changed += 1 if book.save_changes
          else
            result.skipped += 1
            result.errors << (book.errors[:rating].any? && action == "status" ?
                              "#{book.display_title} is rated (clear the rating first)" :
                              "#{book.display_title}: #{book.errors.full_messages.first}")
            book.refresh
          end
        end
      end
      result
    end
  end
end
