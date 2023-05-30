# frozen_string_literal: true

require 'active_model'
require 'active_record/errors'
require 'active_record/connection_adapters/mysql2_adapter'

module FiberedMysql2
  module FiberedMysql2Adapter_6
    def lease
      if (of = owner_fiber)
        msg = +"Cannot lease connection; "
        if of == Fiber.current
          msg << "it is already leased by the current Fiber."
        else
          msg << "it is already in use by a different Fiber: #{of}. " \
                  "Current Fiber: #{Fiber.current}."
        end
        raise ::ActiveRecord::ActiveRecordError, msg
      end

      @owner = Fiber.current
    end

    def expire
      if (of = owner_fiber)
        # Because we are actively releasing connections from dead fibers, we only want
        # to enforce that we're expiring the current fiber's connection, iff the owner
        # of the connection is still alive.
        if of.alive? && of != Fiber.current
          raise ::ActiveRecord::ActiveRecordError, "Cannot expire connection; " \
            "it is owned by a different Fiber: #{of}. " \
            "Current Fiber: #{Fiber.current}."
        end

        @idle_since = ::Concurrent.monotonic_time
        @owner = nil
      else
        raise ::ActiveRecord::ActiveRecordError, "Cannot expire connection; it is not currently leased."
      end
    end

    def steal!
      if (of = owner_fiber)
        if of != Fiber.current
          pool.send :remove_connection_from_thread_cache, self, of

          @owner = Fiber.current
        end
      else
        raise ::ActiveRecord::ActiveRecordError, "Cannot steal connection; it is not currently leased."
      end
    end

    private

    def owner_fiber
      @owner.nil? || @owner.is_a?(Fiber) or
        raise "@owner must be a Fiber! Found #{@owner.inspect}"
      @owner
    end
  end

  class FiberedMysql2Adapter < ::ActiveRecord::ConnectionAdapters::Mysql2Adapter
    case ::Rails::VERSION::MAJOR
    when 6
      include FiberedMysql2Adapter_6
    else
      raise ArgumentError, "unexpected Rails version #{Rails::VERSION::MAJOR}"
    end

    def initialize(*args)
      super
    end
  end
end
