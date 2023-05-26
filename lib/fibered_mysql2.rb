# frozen_string_literal: true

require 'async'
require 'fibered_mysql2/version'
require_relative '../lib/active_record/connection_adapters/fibered_mysql2_adapter'
require 'fibered_mysql2/fibered_database_connection_pool'
require 'fibered_mysql2/fibered_mutex_with_waiter_priority'
require 'fibered_mysql2/fibered_mysql2_connection_factory'

module FiberedMysql2
  class Error < StandardError; end
  # Your code goes here...
end
