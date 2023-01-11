# frozen_string_literal: true

require_relative '../../lib/fibered_mysql2/fibered_mysql2_connection_factory'

RSpec.describe FiberedMysql2::FiberedMysql2ConnectionFactory do
  let(:client) { double(Mysql2::EM::Client) }
  let(:stub_mysql_client_result) { Struct.new(:fields, :to_a).new([], []) }
  let(:connection) { ActiveRecord::Base.connection }

  before do
    allow(client).to receive(:query).and_return(stub_mysql_client_result)
    ActiveRecord::Base.establish_connection(
      :adapter => 'fibered_mysql2',
      :database => 'widgets',
      :username => 'root',
      :pool => 10
    )
  end

  context "transactions" do
    before do
      allow(client).to receive(:query_options) { {} }
      allow(client).to receive(:escape) { |query| query }
      allow(client).to receive(:ping) { true }
      allow(client).to receive(:server_info).and_return({ version: "5.7.27" })
      allow(Mysql2::EM::Client).to receive(:new) { |config| client }
    end

    it "should work with basic nesting" do
      if Rails::VERSION::MAJOR == 6
        allow(connection).to receive(:supports_lazy_transactions?).and_return(false)
      end


      expect(client).to receive(:query).with("BEGIN").and_return(stub_mysql_client_result)
      expect(client).to receive(:query).with("show tables").and_return(stub_mysql_client_result)
      expect(client).to receive(:query).with("COMMIT").and_return(stub_mysql_client_result)

      connection.transaction do
        connection.exec_query("show tables")
      end
    end
  end
end
