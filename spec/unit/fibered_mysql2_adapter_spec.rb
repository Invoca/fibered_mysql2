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
    expect(client).to receive(:query) do |*args|
      query_args << args
      stub_mysql_client_result
    end.at_least(1).times
    allow(client).to receive(:server_info).and_return({ version: "5.7.27" })
  end

  it { should be_instance_of(FiberedMysql2::FiberedMysql2Adapter) }

  context '#lease' do
    subject { adapter.lease }

    it { should eq(Fiber.current) }

    if Rails::VERSION::MAJOR > 4
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
  end

  if Rails::VERSION::MAJOR > 4
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
  end
end
