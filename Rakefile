require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.pattern = "test/**/*_test.rb"
  t.warning = false
end

task default: :test

desc "Fetch covers, metadata and Open Library ratings for books never looked up (ALL=1 to refresh everything)"
task :enrich do
  ruby "bin/enrich #{'--all' if ENV['ALL']}"
end
