require_relative "test_helper"
require "tempfile"

class EnvTest < ShelfTest
  KEYS = %w[FYB_A FYB_B FYB_C FYB_D FYB_E FYB_SET].freeze

  def teardown = KEYS.each { ENV.delete(_1) }

  def test_parses_dotenv_and_never_overrides_real_env
    ENV["FYB_SET"] = "from shell"
    f = Tempfile.new(".env")
    f.write(<<~ENV)
      # a comment
      FYB_A=plain
      export FYB_B="double quoted # not a comment"
      FYB_C='single'
      FYB_D=value   # trailing comment

      FYB_E=
      FYB_SET=from file
      not a valid line
    ENV
    f.close
    Shelf::Env.load(f.path)
    assert_equal ["plain", "double quoted # not a comment", "single", "value", "", "from shell"],
                 KEYS.map { ENV[_1] }
  ensure
    f&.unlink
  end

  def test_missing_file_is_fine
    assert_nil Shelf::Env.load("/nonexistent/.env")
  end
end
