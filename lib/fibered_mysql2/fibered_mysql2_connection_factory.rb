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
        if Rails::VERSION::MAJOR > 5
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
          def begin_transaction(options = {})
            @connection.lock.synchronize do
              run_commit_callbacks = !current_transaction.joinable?
              transaction =
                  if _current_stack.empty?
                    ::ActiveRecord::ConnectionAdapters::RealTransaction.new(@connection, options, run_commit_callbacks: run_commit_callbacks)
                  else
                    ::ActiveRecord::ConnectionAdapters::SavepointTransaction.new(@connection, "active_record_#{Fiber.current.object_id}_#{open_transactions}", _current_stack.last, options,
                                                                                 run_commit_callbacks: run_commit_callbacks)
                  end

              if @connection.supports_lazy_transactions? && lazy_transactions_enabled? && options[:_lazy] != false
                @has_unmaterialized_transactions = true
              else
                transaction.materialize!
              end
              _current_stack.push(transaction)
              transaction
            end
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

      config[:username] = 'root' if config[:username].nil?
      config[:flags]    = Mysql2::Client::FOUND_ROWS if Mysql2::Client.const_defined?(:FOUND_ROWS)

      client =
          begin
            Mysql2::EM::Client.new(config)
          rescue Mysql2::Error => error
            if error.message.include?("Unknown database")
              raise ActiveRecord::NoDatabaseError.new(error.message, error)
            else
              raise
            end
          end

      options = [config[:host], config[:username], config[:password], config[:database], config[:port], config[:socket], 0]
      FiberedMysql2Adapter.new(client, logger, options, config)
    end
  end
end

ActiveRecord::Base.class.prepend(FiberedMysql2::FiberedMysql2ConnectionFactory)
