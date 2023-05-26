# frozen_string_literal: true

require 'coveralls'

Coveralls.wear!

require 'bundler/setup'
require 'rails'
require 'active_record'
require 'fibered_mysql2'
require "rspec/support/object_formatter"

module AsyncHelper
  def in_concurrent_environment(&block)
    Async(&block)
  end
end

RSpec.configure do |config|
  config.include AsyncHelper

  RSpec::Support::ObjectFormatter.default_instance.max_formatted_output_length = 2_000

  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
end
