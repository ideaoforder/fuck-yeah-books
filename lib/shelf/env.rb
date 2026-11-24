module Shelf
  # Minimal .env loader: KEY=value lines, # comments, optional quotes and
  # `export`. Real environment variables always win over the file.
  module Env
    LINE = /\A\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*\z/

    module_function

    def load(path)
      return unless File.file?(path)
      File.foreach(path) do |line|
        next if line.strip.empty? || line.lstrip.start_with?("#")
        m = line.chomp.match(LINE) or next
        key, value = m.captures
        value = if value =~ /\A(["'])(.*)\1\z/ then Regexp.last_match(2)
                else value.sub(/\s+#.*\z/, "") # trailing comment on unquoted values
                end
        ENV[key] ||= value
      end
    end
  end
end

Shelf::Env.load(File.expand_path("../../.env", __dir__)) unless ENV["APP_ENV"] == "test"
