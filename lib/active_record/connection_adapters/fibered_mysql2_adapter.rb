# frozen_string_literal: true

require 'em-synchrony'
require 'active_model'
require 'active_record/errors'
require 'active_record/connection_adapters/em_mysql2_adapter'

module FiberedMysql2
  module FiberedMysql2Adapter_4_2
    def lease
      synchronize do
        unless in_use?
          @owner = Fiber.current
        end
      end
    end
  end

  module FiberedMysql2Adapter_5_2
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

  class FiberedMysql2Adapter < ::ActiveRecord::ConnectionAdapters::EMMysql2Adapter
    case ::Rails::VERSION::MAJOR
    when 4
      include FiberedMysql2Adapter_4_2
    when 5
      include FiberedMysql2Adapter_5_2
    when 6
      include FiberedMysql2Adapter_5_2

      def supports_lazy_transactions?
        false
      end
    end

    def initialize(*args)
      super
    end
  end
end
