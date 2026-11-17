require_relative "test_helper"

class ISBNTest < ShelfTest
  I = Shelf::ISBN

  def test_normalizes_isbn10_to_13
    assert_equal "9780441013593", I.normalize("0-441-01359-7")
    assert_equal "9780804429573", I.normalize("080442957X") # X check digit
  end

  def test_rejects_bad_checksums_and_junk
    assert_nil I.normalize("9780441013594")
    assert_nil I.normalize("=\"\"")
    assert_nil I.normalize("4006381333931") # EAN-13 that isn't a book
  end

  def test_goodreads_wrapping
    assert_equal "9780441013593", I.normalize(%(="9780441013593"))
  end

  def test_scanner_price_addon_is_stripped
    assert_equal "9780441013593", I.from_scan("978044101359351699")
    assert_equal "9780441013593", I.from_scan("97804410135931 2")
  end

  def test_to10
    assert_equal "0441013597", I.to10("9780441013593")
    assert_nil I.to10("9791032305690")
  end
end
