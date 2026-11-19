# frozen_string_literal: true

require_relative '../../lib/fibered_mysql2/fibered_database_connection_pool'
require_relative '../../lib/fibered_mysql2/fibered_mysql2_connection_factory'

RSpec.describe FiberedMysql2::FiberedDatabaseConnectionPool, "while a new connection is connecting" do
  let(:query_result) { Struct.new(:fields, :to_a).new([], []) }
  let(:connect_delays) { Queue.new }

  def stub_client
    instance_double(Mysql2::EM::Client).tap do |client|
      allow(client).to receive_messages(query_options: {}, server_info: { version: "8.0.36" }, ping: true, closed?: false,
                                        query: query_result, abandon_results!: nil, close: nil)
      allow(client).to receive(:escape) { |value| value }
    end
  end

  def elapsed_since(started)
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  before do
    clients = Array.new(3) { stub_client }
    delays = connect_delays
    # Runs on the connect thread: each connect sleeps for its queued delay before returning a client.
    FakeConnect.handler = lambda do |*|
      sleep delays.pop
      clients.pop
    end

    stub_const("PoolConcurrencySpecRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    PoolConcurrencySpecRecord.establish_connection(adapter: "fibered_mysql2", database: "widgets", username: "root",
                                                   pool: 3, checkout_timeout: 0.5)
  end

  after { PoolConcurrencySpecRecord.remove_connection }

  it "lets other fibers check connections in and out" do
    pool = PoolConcurrencySpecRecord.connection_pool
    events = {}
    started = nil

    EM.run do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      connect_delays << 0
      holder = Fiber.new do
        pool.connection
        Fiber.yield
        checkin_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        pool.release_connection
        events[:checkin_seconds] = elapsed_since(checkin_started)
      end
      holder.resume

      EM.add_timer(0.05) do
        connect_delays << 1.0
        Fiber.new do
          pool.connection
          events[:slow_connected_at] = elapsed_since(started)
        end.resume
      end

      EM.add_timer(0.2) { holder.resume }

      EM.add_timer(0.3) do
        connect_delays << 0
        Fiber.new do
          pool.connection
          events[:fast_connected_at] = elapsed_since(started)
        rescue => ex
          events[:fast_error] = ex
        end.resume
      end

      EM.add_timer(1.5) { EM.stop }
    end

    expect(events[:fast_error]).to be_nil
    expect(events[:checkin_seconds]).to be < 0.1
    expect(events[:fast_connected_at]).to be < 0.6
    expect(events[:slow_connected_at]).to be >= 1.0
  end
end
