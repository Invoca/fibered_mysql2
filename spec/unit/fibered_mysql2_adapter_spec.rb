# frozen_string_literal: true

require_relative '../../lib/active_record/connection_adapters/fibered_mysql2_adapter'

RSpec.describe FiberedMysql2::FiberedMysql2Adapter do
  let(:client) { double(Mysql2::EM::Client) }
  let(:logger) { Logger.new(STDOUT) }
  let(:options) { [] }
  let(:config) { {} }
  let(:adapter) { FiberedMysql2::FiberedMysql2Adapter.new(client, logger, options, config) }

  subject { adapter }

  before do
    allow(client).to receive(:query_options) { {} }
    allow(client).to receive(:escape) { |query| query }
    query_args = []
    stub_mysql_client_result = Struct.new(:fields, :to_a).new([], [])
    allow(client).to receive(:query) do |*args|
      query_args << args
      stub_mysql_client_result
    end.at_least(1).times
    allow(client).to receive(:server_info).and_return({ version: "5.7.27" })
  end

  it { should be_instance_of(FiberedMysql2::FiberedMysql2Adapter) }

  describe ".new_client" do
    subject(:new_client) { described_class.new_client(config) }
    let(:config) { {} }
    before do
      allow_any_instance_of(Mysql2::EM::Client).to receive(:connect) {  true }
    end
    context "when the connection is successful" do
      it { is_expected.to be_a(Mysql2::EM::Client) }
    end

    context "when the connection is unsuccessful" do
      before do
        allow(Mysql2::EM::Client).to receive(:new).and_raise(Mysql2::Error.new("error", nil, error_number))
      end

      context "when the error is a bad database error" do
        let(:error_number) { 1049 }

        it "raises a NoDatabaseError" do
          expect { new_client }.to raise_error(ActiveRecord::NoDatabaseError)
        end
      end

      context "when the error is an access denied error" do
        let(:error_number) { 1045 }

        it "raises a DatabaseConnectionError" do
          expect { new_client }.to raise_error(ActiveRecord::DatabaseConnectionError)
        end
      end

      context "when the error is a connection host error" do
        let(:error_number) { 2003 }

        it "raises a DatabaseConnectionError" do
          expect { new_client }.to raise_error(ActiveRecord::DatabaseConnectionError)
        end
      end

      context "when the error is an unknown host error" do
        let(:error_number) { 2005 }

        it "raises a DatabaseConnectionError" do
          expect { new_client }.to raise_error(ActiveRecord::DatabaseConnectionError)
        end
      end

      context "when the error is not a known error" do
        let(:error_number) { 1234 }

        it "raises a ConnectionNotEstablished error" do
          expect { new_client }.to raise_error(ActiveRecord::ConnectionNotEstablished)
        end
      end
    end
  end

  context '#lease' do
    subject { adapter.lease }

    it { should eq(Fiber.current) }

    context 'if the connection is already being used' do
      before { adapter.lease }

      it 'by the current Fiber' do
        expect{ subject }.to raise_exception(ActiveRecord::ActiveRecordError, "Cannot lease connection, it is already leased by the current fiber.")
      end

      it 'by another Fiber' do
        new_fiber = Fiber.new { subject }
        expect{ new_fiber.resume }.to raise_exception(ActiveRecord::ActiveRecordError, /Cannot lease connection, it is already in use by a different fiber/)
      end
    end
  end

  context '#expire' do
    subject { adapter.expire }

    context 'if the connection is not in use' do
      it 'raises' do
        expect{ subject }.to raise_exception(ActiveRecord::ActiveRecordError, "Cannot expire connection, it is not currently leased.")
      end
    end

    context 'if the connection is being used' do
      before { adapter.lease }

      it { should be_nil }

      it 'by a different Fiber' do
        new_fiber = Fiber.new { subject }
        expect{ new_fiber.resume }.to raise_exception(ActiveRecord::ActiveRecordError, /Cannot expire connection.+it is owned by a different fiber/)
      end
    end
  end

  context '#steal!' do
    subject { adapter.steal! }

    context 'if the connection is not in use' do
      it 'raises' do
        expect { subject }.to raise_exception(ActiveRecord::ActiveRecordError, "Cannot steal connection, it is not currently leased.")
      end
    end

    context 'if the connection is being used' do
      before do
        ActiveRecord::Base.establish_connection(
          adapter: 'fibered_mysql2',
          database: 'widgets',
          username: 'root',
          pool: 10
        )

        adapter.pool = ActiveRecord::Base.connection_pool
        adapter.lease
      end

      it { should be_nil }

      it 'by a different Fiber' do
        new_fiber = Fiber.new { subject }
        new_fiber.resume

        expect(adapter.owner).to eq(new_fiber)
      end
    end
  end

  context 'other mixins' do
    it 'raises if @owner has been overwritten with a non-Fiber' do
      adapter.instance_variable_set(:@owner, Thread.new { })

      expect { adapter.expire }.to raise_exception(RuntimeError, /@owner must be a Fiber!/i)
    end

    it "doesn't raise if @owner is nil" do
      adapter.instance_variable_set(:@owner, nil)

      expect { adapter.send(:owner_fiber) }.to_not raise_exception
    end
  end
end
