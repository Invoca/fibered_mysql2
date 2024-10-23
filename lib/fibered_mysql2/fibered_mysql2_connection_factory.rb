# frozen_string_literal: true

require_relative '../active_record/connection_adapters/fibered_mysql2_adapter'

module EM::Synchrony
  module ActiveRecord
    _ = Adapter_4_2
    module Adapter_4_2
      def configure_connection
        super                   # undo EM::Synchrony's override here
      end

      def transaction(*args)
        super                   # and here
      end

      _ = TransactionManager
      class TransactionManager < _
        # Overriding the em-synchrony override to bring it up to rails 6 requirements.
        # Changes from the original Rails 6 source are:
        #   1. the usage of _current_stack created by em-synchrony instead of the Rails provided @stack instance variable
        #   2. the usage of Fiber.current.object_id as a part of the savepoint transaction name
        #
        # Original EM Synchrony Source:
        # https://github.com/igrigorik/em-synchrony/blob/master/lib/em-synchrony/activerecord_4_2.rb#L35-L44
        #
        # Original Rails Source:
        # https://github.com/rails/rails/blob/6-0-stable/activerecord/lib/active_record/connection_adapters/abstract/transaction.rb#L205-L224
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
      end
    end
  end
end

module FiberedMysql2
  module FiberedMysql2ConnectionFactory
    def fibered_mysql2_connection(raw_config)
      config = raw_config.symbolize_keys
      config[:flags] ||= 0

      if config[:flags].kind_of? Array
        config[:flags].push "FOUND_ROWS"
      else
        config[:flags] |= Mysql2::Client::FOUND_ROWS
      end
      config[:username] = 'root' if config[:username].nil?

      client = FiberedMysql2Adapter.new_client(config)
      FiberedMysql2Adapter.new(client, logger, nil, config)
    end
  end
end

ActiveRecord::Base.class.prepend(FiberedMysql2::FiberedMysql2ConnectionFactory)
