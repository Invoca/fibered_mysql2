# frozen_string_literal: true

require_relative '../../lib/active_record/connection_adapters/fibered_mysql2_adapter'

RSpec.describe FiberedMysql2::FiberedMysql2Adapter do
  let(:client) { double(Mysql2::EM::Client) }
  let(:logger) { Logger.new(STDOUT) }
  let(:options) { [] }
  let(:config) { {} }

  subject { FiberedMysql2::FiberedMysql2Adapter.new(client, logger, options, config) }

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

  it 'returns a FiberedMysql2Adapter' do
    expect(subject).to be_instance_of(FiberedMysql2::FiberedMysql2Adapter)
  end

  context '#lease' do
    it 'returns the current Fiber if the connection is not in use' do
      expected_owner = Fiber.current
      expect(subject.lease).to eq(expected_owner)
    end

    case Rails::VERSION::MAJOR
    when 4
      it 'returns nil when the connection is in use' do
        subject.lease
        expect(subject.lease).to be_nil
      end
    when 5, 6
      it 'raises if connection is already used by the current Fiber' do
        subject.lease
        expect{ subject.lease }.to raise_exception(ActiveRecord::ActiveRecordError, "Cannot lease connection, it is already leased by the current fiber.")
      end

      it 'raises is the connection is used by another Fiber' do
        subject.lease

        new_fiber = Fiber.new { subject.lease }
        expect{ new_fiber.resume }.to raise_exception(ActiveRecord::ActiveRecordError, /Cannot lease connection, it is already in use by a different fiber/)
      end
    end
  end

  if Rails::VERSION::MAJOR > 4
    context '#expire' do
      it 'sets the connection @owner to nil when in use' do
        subject.lease
        expect(subject.expire).to be_nil
      end

      it 'raises if the connection is not in use' do
        expect{ subject.expire }.to raise_exception(ActiveRecord::ActiveRecordError, "Cannot expire connection, it is not currently leased.")
      end

      it 'raises if the connection is owned by a different Fiber' do
        subject.lease

        new_fiber = Fiber.new { subject.expire }
        expect{ new_fiber.resume }.to raise_exception(ActiveRecord::ActiveRecordError, /Cannot expire connection.+it is owned by a different fiber/)
      end
    end
  end
end
