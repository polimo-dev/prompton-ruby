# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.libs << "lib"
  task.test_files = FileList["test/**/*_test.rb"]
  task.warning = false
end

begin
  require "rubocop/rake_task"
  RuboCop::RakeTask.new(:lint)
rescue LoadError
  desc "rubocop is not installed"
  task(:lint) { abort "rubocop is not installed; run `bundle install`" }
end

task default: %i[test lint]
