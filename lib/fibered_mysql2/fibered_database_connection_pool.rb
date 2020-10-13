# frozen_string_literal: true

# This class behaves the same as ActiveRecord's ConnectionPool, but synchronizes with fibers rather than threads.

# Note - trace statements have been commented out.  This is useful trace but we do not want it on by default.
#        When we have configurable logging we can put this back and have it off by default.

require 'em-synchrony'
require 'em-synchrony/thread'
require 'fibered_mysql2/fibered_mutex_with_waiter_priority'

EventMachine::Synchrony::Thread::Mutex.prepend(FiberedMysql2::FiberedMutexWithWaiterPriority)

module FiberedMysql2
  class FiberedConditionVariable < MonitorMixin::ConditionVariable
    def initialize(monitor)
      @monitor = monitor
      @cond = EM::Synchrony::Thread::ConditionVariable.new
    end
  end

  # From Ruby's MonitorMixin, with all occurrences of Thread changed to Fiber
  module FiberedMonitorMixin
    def self.extend_object(obj)
      super
      obj.__send__(:mon_initialize)
    end

    #
    # Attempts to enter exclusive section.  Returns +false+ if lock fails.
    #
    def mon_try_enter
      if @mon_owner != Fiber.current
        @mon_mutex.try_lock or return false
        @mon_owner = Fiber.current
        @mon_count = 0
      end
      @mon_count += 1
      true
    end

    #
    # Enters exclusive section.
    #
    def mon_enter
      if @mon_owner != Fiber.current
        @mon_mutex.lock
        @mon_owner = Fiber.current
        @mon_count = 0
      end
      @mon_count += 1
    end

    #
    # Leaves exclusive section.
    #
    def mon_exit
      mon_check_owner
      @mon_count -= 1
      if @mon_count == 0
        @mon_owner = nil
        @mon_mutex.unlock
      end
    end

    #
    # Enters exclusive section and executes the block.  Leaves the exclusive
    # section automatically when the block exits.  See example under
    # +MonitorMixin+.
    #
    def mon_synchronize
      mon_enter
      begin
        yield
      ensure
        begin
          mon_exit
        rescue => ex
          ActiveRecord::Base.logger.error("Exception occurred while executing mon_exit: #{ex}")
        end
      end
    end
    alias synchronize mon_synchronize

    #
    # Creates a new FiberedConditionVariable associated with the
    # receiver.
    #
    def new_cond
      FiberedConditionVariable.new(self)
    end

    private

    # Initializes the FiberedMonitorMixin after being included in a class
    def mon_initialize
      @mon_owner = nil
      @mon_count = 0
      @mon_mutex = EM::Synchrony::Thread::Mutex.new
    end

    def mon_check_owner
      @mon_owner == Fiber.current or raise FiberError, "current fiber not owner"
    end

    def mon_enter_for_cond(count)
      @mon_owner = Fiber.current
      @mon_count = count
    end

    # returns the old mon_count
    def mon_exit_for_cond
      count = @mon_count
      @mon_owner = nil
      @mon_count = 0
      count
    end
  end

  module FiberedDatabaseConnectionPool
    include FiberedMonitorMixin

    module Adapter_4_2
      def cached_connections
        @reserved_connections
      end
    end

    module Adapter_5_2
      def cached_connections
        @thread_cached_conns
      end
    end

    case Rails::VERSION::MAJOR
    when 4
      include Adapter_4_2
    when 5, 6
      include Adapter_5_2
    end

    def initialize(connection_spec)
      connection_spec.config[:reaping_frequency] and raise "reaping_frequency is not supported (the ActiveRecord Reaper is thread-based)"

      super(connection_spec)

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

    if Rails::VERSION::MAJOR > 4
      def release_connection(owner_thread = Fiber.current)
        if (conn = @thread_cached_conns.delete(connection_cache_key(owner_thread)))
          checkin(conn)
        end
      end
    end

    def current_connection_id
      case Rails::VERSION::MAJOR
      when 4
        ActiveRecord::Base.connection_id ||= Fiber.current.object_id
      else
        connection_cache_key(current_thread)
      end
    end

    def checkout(checkout_timeout = @checkout_timeout)
      begin
        reap_connections
      rescue => ex
        ActiveRecord::Base.logger.error("Exception occurred while executing reap_connections: #{ex}")
      end
      if Rails::VERSION::MAJOR > 4
        super
      else
        super()
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
