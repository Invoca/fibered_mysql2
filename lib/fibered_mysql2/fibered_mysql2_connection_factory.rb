# frozen_string_literal: true

require_relative '../active_record/connection_adapters/fibered_mysql2_adapter'

module FiberedMysql2
  module FiberedMysql2ConnectionFactory
    def fibered_mysql2_connection(raw_config)
      config = raw_config.symbolize_keys

      config[:username] = 'root' if config[:username].nil?
      config[:flags]    = Mysql2::Client::FOUND_ROWS if Mysql2::Client.const_defined?(:FOUND_ROWS)

      client =
          begin
            Mysql2::Client.new(config)
          rescue Mysql2::Error => error
            if error.message.include?("Unknown database")
              raise ActiveRecord::NoDatabaseError.new(error.message)
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
