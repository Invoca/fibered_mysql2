# frozen_string_literal: true

require 'active_model'
require 'active_record/errors'
require 'active_record/connection_adapters/mysql2_adapter'

module AsyncMysql2
  module Adapter_6
    def lease
      if (ot = owner_task)
        msg = +"Cannot lease connection; "
        if ot == (current_task = (Async::Task.current if Async::Task.current?))
          msg << "it is already leased by the current Async::Task."
        else
          msg << "it is already in use by a different Async::Task: #{ot}. " \
                  "Current Async::Task: #{current_task}."
        end
        raise ::ActiveRecord::ActiveRecordError, msg
      end

      @owner = Async::Task.current
    end

    def expire
      if (ot = owner_task)
        # Because we are actively releasing connections from dead tasks, we only want
        # to enforce that we're expiring the current task's connection, iff the owner
        # of the connection is still alive.
        if ot.alive? && ot != (current_task = (Async::Task.current if Async::Task.current?))
          raise ::ActiveRecord::ActiveRecordError, "Cannot expire connection; " \
            "it is owned by a different Async::Task: #{ot}. " \
            "Current Async::Task: #{current_task}."
        end

        @idle_since = ::Concurrent.monotonic_time
        @owner = nil
      else
        raise ::ActiveRecord::ActiveRecordError, "Cannot expire connection; it is not currently leased."
      end
    end

    def steal!
      if (ot = owner_task)
        if ot != (current_task = (Async::Task.current if Async::Task.current?))
          pool.send :remove_connection_from_thread_cache, self, ot

          @owner = current_task
        end
      else
        raise ::ActiveRecord::ActiveRecordError, "Cannot steal connection; it is not currently leased."
      end
    end

    private

    def owner_task
      @owner.nil? || @owner.is_a?(Async::Task) or
        raise "@owner must be an Async::Task! Found #{@owner.inspect}"
      @owner
    end
  end

  class AsyncMysql2Adapter < ::ActiveRecord::ConnectionAdapters::Mysql2Adapter
    case ::Rails::VERSION::MAJOR
    when 6
      include Adapter_6
    else
      raise ArgumentError, "unexpected Rails version #{Rails::VERSION::MAJOR}"
    end

    def initialize(*args)
      super
    end
  end
end
