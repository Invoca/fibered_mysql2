# frozen_string_literal: true

require_relative '../active_record/connection_adapters/fibered_mysql2_adapter'

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
