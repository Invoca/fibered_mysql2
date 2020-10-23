# frozen_string_literal: true

require_relative '../../lib/fibered_mysql2/fibered_mysql2_connection_factory'

RSpec.describe FiberedMysql2::FiberedMysql2ConnectionFactory do
  let(:client) { double(Mysql2::EM::Client) }
  
  before do
    ActiveRecord::Base.establish_connection(
      :adapter => 'fibered_mysql2',
      :database => 'widgets',
      :username => 'root',
      :pool => 10
    )
  end

  context "transactions" do
    it "should work with basic nesting" do
      allow(client).to receive(:query_options) { {} }
      allow(client).to receive(:escape) { |query| query }
      query_args = []
      stub_mysql_client_result = Struct.new(:fields, :to_a).new([], [])
      expect(client).to receive(:query) do |*args|
        query_args << args
        stub_mysql_client_result
      end.at_least(1).times
      allow(client).to receive(:ping) { true }
      allow(client).to receive(:server_info).and_return({ version: "5.7.27" })

      allow(Mysql2::EM::Client).to receive(:new) { |config| client }

      connection = ActiveRecord::Base.connection
      if Rails::VERSION::MAJOR == 6
        allow(connection).to receive(:supports_lazy_transactions?).and_return(false)
      end

      connection.transaction do
        connection.exec_query("show tables")
      end
      rails_specific_arg = case Rails::VERSION::MAJOR
                           when 4
                             "SET  @@SESSION.sql_auto_is_null = 0, @@SESSION.wait_timeout = 2147483, @@SESSION.sql_mode = 'STRICT_ALL_TABLES'"
                           else
                             "SET  @@SESSION.sql_mode = CONCAT(CONCAT(@@sql_mode, ',STRICT_ALL_TABLES'), ',NO_AUTO_VALUE_ON_ZERO'),  @@SESSION.sql_auto_is_null = 0, @@SESSION.wait_timeout = 2147483"
                           end
      expect(query_args).to eq([
                                   [rails_specific_arg],
                                   ["BEGIN"],
                                   ["show tables"],
                                   ["COMMIT"]
                               ])
    end
  end
end
