module Shelf
  # ISBN-10/13 validation and conversion. Everything is stored as ISBN-13.
  module ISBN
    module_function

    def clean(str)
      str.to_s.upcase.gsub(/[^0-9X]/, "")
    end

    # Returns a valid ISBN-13 string or nil. Accepts ISBN-10, ISBN-13, hyphens,
    # Goodreads' ="..." wrapping, etc.
    def normalize(str)
      d = clean(str)
      if d.length == 13 && d.start_with?("978", "979") && valid13?(d) then d
      elsif d.length == 10 && valid10?(d) then to13(d)
      end
    end

    # Barcode scanners read the EAN-13 on the back cover. Some also read the
    # 2- or 5-digit price add-on to its right and append it (15 or 18 digits).
    def from_scan(code)
      d = clean(code)
      d = d[0, 13] if [15, 18].include?(d.length)
      normalize(d)
    end

    def valid10?(d)
      return false unless d.match?(/\A\d{9}[\dX]\z/)
      sum = d.chars.each_with_index.sum { |c, i| (c == "X" ? 10 : c.to_i) * (10 - i) }
      (sum % 11).zero?
    end

    def valid13?(d)
      return false unless d.match?(/\A\d{13}\z/)
      sum = d.chars.each_with_index.sum { |c, i| c.to_i * (i.even? ? 1 : 3) }
      (sum % 10).zero?
    end

    def to13(d10)
      body = "978" + d10[0, 9]
      body + check13(body)
    end

    def to10(d13)
      return nil unless d13&.start_with?("978")
      body = d13[3, 9]
      sum = body.chars.each_with_index.sum { |c, i| c.to_i * (10 - i) }
      check = (11 - sum % 11) % 11
      body + (check == 10 ? "X" : check.to_s)
    end

    def check13(body12)
      sum = body12.chars.each_with_index.sum { |c, i| c.to_i * (i.even? ? 1 : 3) }
      ((10 - sum % 10) % 10).to_s
    end
  end
end
