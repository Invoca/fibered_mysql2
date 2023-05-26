# frozen_string_literal: true

require 'async'
require 'async_mysql2/version'
require_relative '../lib/active_record/connection_adapters/async_mysql2_adapter'
require 'async_mysql2/fibered_database_connection_pool'
require 'async_mysql2/fibered_mutex_with_waiter_priority'
require 'async_mysql2/connection_factory'

module AsyncMysql2
  class Error < StandardError; end
end
