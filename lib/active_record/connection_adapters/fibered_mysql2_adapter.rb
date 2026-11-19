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
      # the GVL) and yield the calling fiber until it is done. Off the reactor thread, connect inline as before.
      # On the reactor's root fiber, which cannot yield, the connect still runs on the separate thread, but the root
      # fiber blocks until it is done, so the reactor stops for the connect as it did before.
      def connect_client(config)
        if EM.reactor_running? && EM.reactor_thread?
          connect_client_off_reactor(config)
        else
          Mysql2::EM::Client.new(config)
        end
      end

      def connect_client_off_reactor(config)
        fiber = Fiber.current
        reactor_run = current_reactor_run
        waiting = false
        done = false
        abandoned = false

        connect_thread = Thread.new do
          Thread.current.report_on_exception = false
          Mysql2::EM::Client.new(config)
        ensure
          # EM.next_tick is safe to call from another thread; the block runs on the reactor thread.
          EM.next_tick do
            done = true
            if waiting && fiber.alive? && reactor_run.equal?(@current_reactor_run)
              fiber.resume
            elsif waiting || abandoned
              # Nobody will read the result: the reactor this connect started on has stopped (this tick is being
              # flushed by a later EM.run), or the waiting fiber was unwound. Close the client instead of leaking it.
              close_orphaned_client(connect_thread)
            end
          end
        end

        finished = false
        begin
          begin
            waiting = true
            Fiber.yield until done
          rescue FiberError
            # The root fiber cannot yield: block on the connect thread below, which stops the reactor for the connect
            # as an inline connect did.
          ensure
            waiting = false
          end

          client = connect_thread_result(connect_thread)
          finished = true
          client
        ensure
          # Unwound while waiting (for example by an exception raised into this fiber): let the tick close the client.
          abandoned = true unless finished || done
        end
      end

      # A token for the current EM.run, cleared when that reactor stops, so a connect that outlives its reactor
      # never resumes its fiber inside a later one. The shutdown hook that clears it is registered only when the token
      # is created, so once per reactor run; later connects in the same run reuse the token and register nothing.
      def current_reactor_run
        return @current_reactor_run if @current_reactor_run

        reactor_run = Object.new
        EM.add_shutdown_hook { @current_reactor_run = nil if @current_reactor_run.equal?(reactor_run) }
        @current_reactor_run = reactor_run
      end

      def connect_thread_result(connect_thread)
        connect_thread.value or
          raise ActiveRecord::ConnectionNotEstablished, "fibered_mysql2 connect thread ended without returning a client"
      rescue Mysql2::Error, ActiveRecord::ConnectionNotEstablished
        raise
      rescue StandardError => ex
        # Thread#value re-raises with the connect thread's backtrace only; add the caller's frames.
        ex.set_backtrace(Array(ex.backtrace) + caller)
        raise ex
      end

      def close_orphaned_client(connect_thread)
        connect_thread.value&.close
      rescue StandardError
        nil
      end
    end
  end
end
