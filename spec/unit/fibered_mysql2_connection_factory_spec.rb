# frozen_string_literal: true

require_relative '../../lib/fibered_mysql2/fibered_mysql2_connection_factory'

RSpec.describe FiberedMysql2::FiberedMysql2ConnectionFactory do
  let(:stub_mysql_client_result) { Struct.new(:fields, :to_a).new([], []) }

  describe "#fibered_mysql2_connection" do
    let(:client) { double(Mysql2::EM::Client) }

    context 'when fibered_mysql2 adapter is used' do
      subject { ActiveRecord::Base.connection }

      before do
        expect(Mysql2::EM::Client).to receive(:new).and_return(client)
        allow(client).to receive(:query_options) { {} }
        allow(client).to receive(:server_info).and_return({ version: "5.7.27" })
        allow(client).to receive(:ping) { true }
        allow(client).to receive(:query).and_return(stub_mysql_client_result)
        ActiveRecord::Base.establish_connection(
          :adapter => 'fibered_mysql2',
          :database => 'widgets',
          :username => 'root',
          :pool => 10
        )
      end

      it { is_expected.to be_a(FiberedMysql2::FiberedMysql2Adapter) }
    end
  end

  describe "transactions" do
    let(:client) { double(Mysql2::EM::Client) }
    let(:logger) { Logger.new(STDOUT) }
    let(:options) { [] }
    let(:config) { {} }
    let(:connection) { FiberedMysql2::FiberedMysql2Adapter.new(client, logger, options, config) }

    before do
      allow(client).to receive(:query_options) { {} }
      allow(client).to receive(:escape) { |query| query }
      allow(client).to receive(:ping) { true }
      allow(client).to receive(:server_info).and_return({ version: "5.7.27" })
      allow(client).to receive(:query).and_return(stub_mysql_client_result)
    end

    it "should work with basic nesting" do
      expect(client).to receive(:query).with("BEGIN").and_return(stub_mysql_client_result)
      expect(client).to receive(:query).with("show tables").and_return(stub_mysql_client_result)
      expect(client).to receive(:query).with("COMMIT").and_return(stub_mysql_client_result)

      connection.transaction do
        connection.exec_query("show tables")
      end
    end

    if Rails::VERSION::MAJOR >= 6
      context "with an empty transaction" do
        context "with lazy transactions disabled" do
          before { connection.disable_lazy_transactions! }

          it "starts and commits a transaction even without any queries" do
            expect(client).to receive(:query).with("BEGIN").and_return(stub_mysql_client_result)
            expect(client).to receive(:query).with("COMMIT").and_return(stub_mysql_client_result)

            connection.transaction do
              expect(connection.current_transaction.materialized?).to be_truthy
            end
          end
        end

        context "with lazy transactions enabled" do
          before { connection.enable_lazy_transactions! }

          it 'does not materialize a transaction without any queries' do
            expect(client).to_not receive(:query).with("BEGIN")
            expect(client).to_not receive(:query).with("COMMIT")

            connection.transaction do
              expect(connection.current_transaction.materialized?).to be_falsey
            end
          end

          it 'materializes a transaction when the first query is performed' do
            expect(client).to receive(:query).with("BEGIN").and_return(stub_mysql_client_result)
            expect(client).to receive(:query).with("show tables").and_return(stub_mysql_client_result)
            expect(client).to receive(:query).with("COMMIT").and_return(stub_mysql_client_result)

            connection.transaction do
              expect(connection.current_transaction.materialized?).to be_falsey
              connection.exec_query("show tables")
              expect(connection.current_transaction.materialized?).to be_truthy
            end
          end
        end
      end
    end
  end
end
