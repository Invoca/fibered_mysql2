# frozen_string_literal: true

require 'em-synchrony'
require 'active_model'
require 'active_record/errors'
require 'active_record/connection_adapters/mysql2_adapter'
require 'em-synchrony/mysql2'

module FiberedMysql2
  module FiberedMysql2Adapter_7_0
    def lease
      if in_use?
        msg = "Cannot lease connection, ".dup
        if owner_fiber == Fiber.current
          msg << "it is already leased by the current fiber."
        else
          msg << "it is already in use by a different fiber: #{owner_fiber}. " \
                  "Current fiber: #{Fiber.current}."
        end
        raise ::ActiveRecord::ActiveRecordError, msg
      end

      @owner = Fiber.current
    end

    def expire
      if in_use?
        # Because we are actively releasing connections from dead fibers, we only want
        # to enforce that we're expiring the current fibers connection, iff the owner
        # of the connection is still alive.
        if owner_fiber.alive? && owner_fiber != Fiber.current
          raise ::ActiveRecord::ActiveRecordError, "Cannot expire connection, " \
            "it is owned by a different fiber: #{owner_fiber}. " \
            "Current fiber: #{Fiber.current}."
        end

        @idle_since = ::Concurrent.monotonic_time
        @owner = nil
      else
        raise ::ActiveRecord::ActiveRecordError, "Cannot expire connection, it is not currently leased."
      end
    end

    def steal!
      if in_use?
        if owner_fiber != Fiber.current
          pool.send :remove_connection_from_thread_cache, self, owner_fiber

          @owner = Fiber.current
        end
      else
        raise ::ActiveRecord::ActiveRecordError, "Cannot steal connection, it is not currently leased."
      end
    end

    private

    def owner_fiber
      @owner.nil? || @owner.is_a?(Fiber) or
        raise "@owner must be a Fiber! Found #{@owner.inspect}"
      @owner
    end
  end

  module FiberedMysql2Adapter_7_1
    def expire
      if in_use?
        # Because we are actively releasing connections from dead fibers, we only want
        # to enforce that we're expiring the current fibers connection, iff the owner
        # of the connection is still alive.
        if @owner.alive? && @owner != ActiveSupport::IsolatedExecutionState.context
          raise ::ActiveRecord::ActiveRecordError, "Cannot expire connection, " \
            "it is owned by a different fiber: #{@owner}. " \
            "Current fiber: #{ActiveSupport::IsolatedExecutionState.context}."
        end

        @idle_since = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @owner = nil
      else
        raise ::ActiveRecord::ActiveRecordError, "Cannot expire connection, it is not currently leased."
      end
    end
  end

  class FiberedMysql2Adapter < ::ActiveRecord::ConnectionAdapters::Mysql2Adapter
    if Rails.gem_version < "7.1"
      include FiberedMysql2Adapter_7_0
    else
      include FiberedMysql2Adapter_7_1
    end

    class << self
      # Copied from Mysql2Adapter, except with the EM Mysql2 client
      def new_client(config)
        connect_client(config)
      rescue Mysql2::Error => error
        if error.error_number == 1049
          raise ActiveRecord::NoDatabaseError.new, error.message
        else
          raise ActiveRecord::ConnectionNotEstablished, error.message
        end
      end

      private

      # Mysql2::Client#initialize connects synchronously (mysql_real_connect), so on the reactor thread it would
      # stop EventMachine for up to connect_timeout. There, connect on a separate thread (the native connect releases
      # the GVL) and yield the calling fiber until it is done. Elsewhere, connect inline as before.
      def connect_client(config)
        if EM.reactor_running? && EM.reactor_thread?
          connect_client_off_reactor(config)
        else
          Mysql2::EM::Client.new(config)
        end
      end

      def connect_client_off_reactor(config)
        fiber = Fiber.current
        waiting = false
        done = false

        connect_thread = Thread.new do
          Thread.current.report_on_exception = false
          Mysql2::EM::Client.new(config)
        ensure
          # EM.next_tick is safe to call from another thread; the block runs on the reactor thread.
          EM.next_tick do
            done = true
            fiber.resume if waiting
          end
        end

        begin
          waiting = true
          Fiber.yield until done
        rescue FiberError
          # The root fiber cannot yield: wait for the connect, blocking the reactor as before.
        ensure
          waiting = false
        end

        connect_thread.value
      end
    end
  end
end
