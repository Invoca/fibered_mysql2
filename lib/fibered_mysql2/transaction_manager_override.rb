# frozen_string_literal: true

require "active_record"

module FiberedMysql2
  module TransactionManagerOverride
    class TransactionManager < ::ActiveRecord::ConnectionAdapters::TransactionManager
      def initialize(*args)
        super
        @stack = Hash.new { |h, k| h[k] = [] }
      end

      def current_transaction #:nodoc:
        _current_stack.last || NULL_TRANSACTION
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

    def reset_transaction #:nodoc:
      @transaction_manager = ::FiberedMysql2::TransactionManagerOverride::TransactionManager.new(self)
    end
  end
end
