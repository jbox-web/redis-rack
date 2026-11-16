# frozen_string_literal: true

require 'bundler/setup'
require 'bundler/gem_tasks'
require 'redis-store/testing/tasks'
require 'rspec/core/rake_task'

# redis-store-testing wires the default task to redis:test:run, which it
# defines as a Minitest runner: replace it with RSpec.
Rake::Task['redis:test:run'].clear

namespace :redis do
  namespace :test do
    RSpec::Core::RakeTask.new(:run)
  end
end
