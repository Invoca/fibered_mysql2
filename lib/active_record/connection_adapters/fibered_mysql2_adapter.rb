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

    def reset_transaction #:nodoc:
      @transaction_manager = ::FiberedMysql2::FiberedMysql2Adapter_7_0::TransactionManager.new(self)
    end

    class TransactionManager < ::ActiveRecord::ConnectionAdapters::TransactionManager
      def initialize(...)
        super
        @stack = Hash.new { |h, k| h[k] = [] }
      end

      def current_transaction #:nodoc:
        _current_stack.last || ::ActiveRecord::ConnectionAdapters::TransactionManager::NULL_TRANSACTION
      end

      def open_transactions
        _current_stack.size
      end

      def begin_transaction(isolation: nil, joinable: true, _lazy: true)
        @connection.lock.synchronize do
          run_commit_callbacks = !current_transaction.joinable?
          transaction =
            if _current_stack.empty?
              ::ActiveRecord::ConnectionAdapters::RealTransaction.new(@connection, isolation:, joinable:, run_commit_callbacks: run_commit_callbacks)
            else
              ::ActiveRecord::ConnectionAdapters::SavepointTransaction.new(@connection, "active_record_#{Fiber.current.object_id}_#{open_transactions}", _current_stack.last, isolation:, joinable:, run_commit_callbacks: run_commit_callbacks)
            end

          if @connection.supports_lazy_transactions? && lazy_transactions_enabled? && _lazy
            @has_unmaterialized_transactions = true
          else
            transaction.materialize!
          end
          _current_stack.push(transaction)
          transaction
        end
      end

      # Overriding the ActiveRecord::TransactionManager#materialize_transactions method to use
      # fiber safe the _current_stack instead of the @stack instance variable. when marterializing
      # transactions.
      def materialize_transactions
        return if @materializing_transactions
        return unless @has_unmaterialized_transactions

        @connection.lock.synchronize do
          begin
            @materializing_transactions = true
            _current_stack.each { |t| t.materialize! unless t.materialized? }
          ensure
            @materializing_transactions = false
          end
          @has_unmaterialized_transactions = false
        end
      end

      # Overriding the ActiveRecord::TransactionManager#commit_transaction method to use
      # fiber safe the _current_stack instead of the @stack instance variable. when marterializing
      # transactions.
      def commit_transaction
        @connection.lock.synchronize do
          transaction = _current_stack.last

          begin
            transaction.before_commit_records
          ensure
            _current_stack.pop
          end

          transaction.commit
          transaction.commit_records
        end
      end

      # Overriding the ActiveRecord::TransactionManager#rollback_transaction method to use
      # fiber safe the _current_stack instead of the @stack instance variable. when marterializing
      # transactions.
      def rollback_transaction(transaction = nil)
        @connection.lock.synchronize do
          transaction ||= _current_stack.pop
          transaction.rollback
          transaction.rollback_records
        end
      end

      private

      def _current_stack
        @stack[Fiber.current.object_id]
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
    if ::ActiveRecord.gem_version < "7.1"
      include FiberedMysql2Adapter_7_0
    end

    class << self
      # Copied from Mysql2Adapter, except with the EM Mysql2 client
      def new_client(config)
        Mysql2::EM::Client.new(config)
      rescue Mysql2::Error => error
        if error.error_number == 1049
          raise ActiveRecord::NoDatabaseError.new, error.message
        else
          raise ActiveRecord::ConnectionNotEstablished, error.message
        end
      end
    end
  end
end
