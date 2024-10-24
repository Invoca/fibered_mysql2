# frozen_string_literal: true

# This class behaves the same as ActiveRecord's ConnectionPool, but synchronizes with fibers rather than threads.

module FiberedMysql2
  module FiberedDatabaseConnectionPool
    def cached_connections
      @thread_cached_conns
    end

    def current_connection_id
      connection_cache_key(current_thread)
    end

    def checkout(checkout_timeout = @checkout_timeout)
      begin
        reap_connections
      rescue => ex
        ActiveRecord::Base.logger.error("Exception occurred while executing reap_connections: #{ex.class}: #{ex.message}")
      end
      super
    end

    def release_connection(owner = Fiber.current)
      if (conn = @thread_cached_conns.delete(connection_cache_key(owner)))
        checkin(conn)
      end
    end

    def initialize(connection_spec, *args, **keyword_args)
      if ActiveRecord.gem_version < "6.1"
        connection_spec.config[:reaping_frequency] and raise "reaping_frequency is not supported (the ActiveRecord Reaper is thread-based)"
        connection_spec.config[:reaping_frequency] = nil # starting in Rails 5, this defaults to 60 if not explicitly set
      elsif connection_spec.db_config.reaping_frequency
        connection_spec.db_config.reaping_frequency > 0 and raise "reaping_frequency is not supported (the ActiveRecord Reaper is thread-based)"
      end

      super(connection_spec, *args, **keyword_args)

      @reaper = nil # no need to keep a reference to this since it does nothing in this sub-class

      # note that @reserved_connections is a ThreadSafe::Cache which is overkill in a fibered world, but harmless
    end

    def connection
      # this is correctly done double-checked locking
      # (ThreadSafe::Cache's lookups have volatile semantics)
      if (result = cached_connections[current_connection_id])
        result
      else
        synchronize do
          if (result = cached_connections[current_connection_id])
            result
          else
            cached_connections[current_connection_id] = checkout
          end
        end
      end
    end

    def reap_connections
      cached_connections.values.each do |connection|
        unless connection.owner.alive?
          checkin(connection)
        end
      end
    end

    private

    #--
    # This hook-in method allows for easier monkey-patching fixes needed by
    # JRuby users that use Fibers.
    def connection_cache_key(fiber)
      fiber
    end

    def current_thread
      Fiber.current
    end
  end
end

ActiveRecord::ConnectionAdapters::ConnectionPool.prepend(FiberedMysql2::FiberedDatabaseConnectionPool)
