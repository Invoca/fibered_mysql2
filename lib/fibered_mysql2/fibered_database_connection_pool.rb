# frozen_string_literal: true

# This class behaves the same as ActiveRecord's ConnectionPool, but synchronizes with fibers rather than threads.

# Note - trace statements have been commented out.  This is useful trace but we do not want it on by default.
#        When we have configurable logging we can put this back and have it off by default.

require 'em-synchrony'
require 'em-synchrony/thread'
require 'fibered_mysql2/fibered_mutex_with_waiter_priority'

EventMachine::Synchrony::Thread::Mutex.prepend(FiberedMysql2::FiberedMutexWithWaiterPriority)

module FiberedMysql2
  class FiberedConditionVariable
    EXCEPTION_NEVER = {Exception => :never}.freeze
    EXCEPTION_IMMEDIATE = {Exception => :immediate}.freeze

    #
    # FIXME: This isn't documented in Nutshell.
    #
    # Since MonitorMixin.new_cond returns a ConditionVariable, and the example
    # above calls while_wait and signal, this class should be documented.
    #
    class Timeout < Exception; end

    #
    # Releases the lock held in the associated monitor and waits; reacquires the lock on wakeup.
    #
    # If +timeout+ is given, this method returns after +timeout+ seconds passed,
    # even if no other thread doesn't signal.
    #
    def wait(timeout = nil)
      Thread.handle_interrupt(EXCEPTION_NEVER) do
        @monitor.__send__(:mon_check_owner)
        count = @monitor.__send__(:mon_exit_for_cond)
        begin
          Thread.handle_interrupt(EXCEPTION_IMMEDIATE) do
            @cond.wait(@monitor.instance_variable_get(:@mon_mutex), timeout)
          end
          return true
        ensure
          @monitor.__send__(:mon_enter_for_cond, count)
        end
      end
    end

    #
    # Calls wait repeatedly while the given block yields a truthy value.
    #
    def wait_while
      while yield
        wait
      end
    end

    #
    # Calls wait repeatedly until the given block yields a truthy value.
    #
    def wait_until
      until yield
        wait
      end
    end

    #
    # Wakes up the first thread in line waiting for this lock.
    #
    def signal
      @monitor.__send__(:mon_check_owner)
      @cond.signal
    end

    #
    # Wakes up all threads waiting for this lock.
    #
    def broadcast
      @monitor.__send__(:mon_check_owner)
      @cond.broadcast
    end

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

    # Initializes the FiberedMonitorMixin after being included in a class
    def mon_initialize
      @mon_owner = nil
      @mon_count = 0
      @mon_mutex = EM::Synchrony::Thread::Mutex.new
    end

    def mon_check_owner
      @mon_owner == Fiber.current or raise FiberError, "current fiber not owner"
    end

    private

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

    module Adapter_5_2
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
          ActiveRecord::Base.logger.error("Exception occurred while executing reap_connections: #{ex}")
        end
        super
      end

      def release_connection(owner_thread = Fiber.current)
        if (conn = @thread_cached_conns.delete(connection_cache_key(owner_thread)))
          checkin(conn)
        end
      end
    end
    include Adapter_5_2

    def initialize(pool_config)
      if pool_config.db_config.reaping_frequency
        pool_config.db_config.reaping_frequency > 0 and raise "reaping_frequency is not supported (the ActiveRecord Reaper is thread-based)"
      end

      super(pool_config)

      @reaper = nil # no need to keep a reference to this since it does nothing in this sub-class
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
