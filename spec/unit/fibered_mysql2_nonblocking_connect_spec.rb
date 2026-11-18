# frozen_string_literal: true

require_relative '../../lib/active_record/connection_adapters/fibered_mysql2_adapter'

RSpec.describe FiberedMysql2::FiberedMysql2Adapter, "connecting without blocking the reactor" do
  # A non-routable address: the TCP connect gets no answer, so it waits for the full connect_timeout.
  BLACKHOLE_HOST = ENV.fetch("FIBERED_MYSQL2_BLACKHOLE_HOST", "10.255.255.1")

  let(:client) { double(Mysql2::EM::Client) }

  # Runs the block in a fiber on the reactor (as em-synchrony does) while a 100 ms periodic timer counts ticks.
  def in_reactor_fiber
    result = nil
    ticks = 0
    EM.run do
      EM.add_periodic_timer(0.1) { ticks += 1 }
      Fiber.new do
        result = begin
                   yield
                 rescue => ex
                   ex
                 end
        EM.stop
      end.resume
    end
    [result, ticks]
  end

  def stub_slow_connect(seconds:, threads:, result: client)
    allow(Mysql2::EM::Client).to receive(:new) do
      threads << Thread.current
      sleep seconds
      result.is_a?(Exception) ? raise(result) : result
    end
  end

  describe ".new_client" do
    let(:connect_threads) { [] }

    context "when the reactor is not running" do
      it "connects on the calling thread" do
        stub_slow_connect(seconds: 0, threads: connect_threads)

        expect(described_class.new_client({})).to eq(client)
        expect(connect_threads).to eq([Thread.current])
      end
    end

    context "when called from a fiber on the reactor thread" do
      it "connects on another thread and keeps the reactor running meanwhile" do
        stub_slow_connect(seconds: 1, threads: connect_threads)

        result, ticks = in_reactor_fiber { described_class.new_client({}) }

        expect(result).to eq(client)
        expect(connect_threads.size).to eq(1)
        expect(connect_threads.first).not_to eq(Thread.current)
        expect(ticks).to be >= 5
      end

      it "raises NoDatabaseError for an unknown database" do
        stub_slow_connect(seconds: 0, threads: connect_threads, result: Mysql2::Error.new("Unknown database", nil, 1049))

        result, = in_reactor_fiber { described_class.new_client({}) }

        expect(result).to be_a(ActiveRecord::NoDatabaseError)
      end

      [2003, 2005, 1040, 1045].each do |error_number|
        it "raises ConnectionNotEstablished for MySQL error #{error_number}" do
          stub_slow_connect(seconds: 0, threads: connect_threads, result: Mysql2::Error.new("failed", nil, error_number))

          result, = in_reactor_fiber { described_class.new_client({}) }

          expect(result).to be_a(ActiveRecord::ConnectionNotEstablished)
          expect(result.message).to eq("failed")
        end
      end
    end

    context "when called from the reactor's root fiber" do
      it "waits for the connect without yielding" do
        stub_slow_connect(seconds: 0.2, threads: connect_threads)
        result = nil

        EM.run do
          result = described_class.new_client({})
          EM.stop
        end

        expect(result).to eq(client)
        expect(connect_threads.first).not_to eq(Thread.current)
      end
    end

    context "with a database host that does not answer" do
      let(:config) { { host: BLACKHOLE_HOST, username: "root", connect_timeout: 2 } }

      def connect_and_count_ticks
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result, ticks = in_reactor_fiber { yield }
        [result, ticks, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
      end

      it "keeps the reactor running for the whole connect_timeout" do
        result, ticks, elapsed = connect_and_count_ticks { described_class.new_client(config) }
        elapsed >= 1.5 or skip("#{BLACKHOLE_HOST} failed fast (#{elapsed.round(2)} s) instead of timing out on this network")

        expect(result).to be_a(ActiveRecord::ConnectionNotEstablished)
        expect(ticks).to be >= 15
      end

      it "(for comparison) blocks the reactor when Mysql2::EM::Client connects inline" do
        result, ticks, elapsed = connect_and_count_ticks { Mysql2::EM::Client.new(config) }
        elapsed >= 1.5 or skip("#{BLACKHOLE_HOST} failed fast (#{elapsed.round(2)} s) instead of timing out on this network")

        expect(result).to be_a(Mysql2::Error)
        expect(ticks).to eq(0)
      end
    end
  end

  describe "#reconnect! with connection_retries: 1", if: Rails.gem_version >= "7.1" do
    let(:adapter) { described_class.new(client, Logger.new(nil), [], { connection_retries: 1 }) }
    let(:connect_threads) { [] }

    before do
      allow(client).to receive(:query_options) { {} }
      allow(client).to receive(:escape) { |query| query }
      allow(client).to receive(:query).and_return(Struct.new(:fields, :to_a).new([], []))
      allow(client).to receive(:server_info).and_return({ version: "8.0.36" })
      allow(client).to receive(:close)
      allow(client).to receive(:closed?).and_return(false)
    end

    it "retries a fast connect failure after a backoff and reconnects, off the reactor thread" do
      attempts = 0
      allow(Mysql2::EM::Client).to receive(:new) do
        connect_threads << Thread.current
        attempts += 1
        attempts == 1 ? raise(Mysql2::Error.new("Can't connect to MySQL server", nil, 2003)) : client
      end
      expect(adapter).to receive(:backoff).with(1).and_call_original

      result, = in_reactor_fiber { adapter.reconnect! }

      expect(result).not_to be_a(Exception)
      expect(attempts).to eq(2)
      expect(connect_threads).to all(satisfy { |thread| thread != Thread.current })
      expect(adapter.instance_variable_get(:@raw_connection)).to eq(client)
    end

    it "raises ConnectionNotEstablished after two failed attempts" do
      allow(Mysql2::EM::Client).to receive(:new).and_raise(Mysql2::Error.new("Can't connect to MySQL server", nil, 2003))

      result, = in_reactor_fiber { adapter.reconnect! }

      expect(result).to be_a(ActiveRecord::ConnectionNotEstablished)
      expect(Mysql2::EM::Client).to have_received(:new).twice
    end
  end
end
