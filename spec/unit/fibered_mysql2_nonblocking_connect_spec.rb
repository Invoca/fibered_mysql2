# frozen_string_literal: true

require_relative '../../lib/active_record/connection_adapters/fibered_mysql2_adapter'

RSpec.describe FiberedMysql2::FiberedMysql2Adapter, "connecting without blocking the reactor" do
  let(:query_result) { Struct.new(:fields, :to_a).new([], []) }
  let(:client) { stub_client }

  def stub_client(ping: true)
    instance_double(Mysql2::EM::Client).tap do |client|
      allow(client).to receive_messages(query_options: {}, server_info: { version: "8.0.36" }, ping: ping, closed?: false,
                                        query: query_result, close: nil)
      allow(client).to receive(:escape) { |value| value }
    end
  end

  # Runs the block in a fiber on the reactor (as em-synchrony does) while a 100 ms periodic timer counts ticks.
  # A fiber that is never resumed fails the example after 10 s instead of hanging the suite.
  def in_reactor_fiber
    result = RuntimeError.new("the reactor fiber did not finish within 10 s")
    ticks = 0
    EM.run do
      EM.add_timer(10) { EM.stop }
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

  # The handler runs on the connect thread, so everything it needs is evaluated here, on the example's thread.
  def stub_slow_connect(seconds:, result: client)
    raise_result = result.is_a?(Exception)
    FakeConnect.handler = lambda do |*|
      sleep seconds
      raise_result ? raise(result) : result
    end
  end

  def connect_threads
    FakeConnect.call_threads
  end

  # Runs a second reactor briefly, which flushes any EM.next_tick left over from the previous one.
  def run_another_reactor
    EM.run { EM.add_timer(0.2) { EM.stop } }
  end

  describe ".new_client" do

    context "when the reactor is not running" do
      it "connects on the calling thread" do
        stub_slow_connect(seconds: 0)

        expect(described_class.new_client({})).to eq(client)
        expect(connect_threads).to eq([Thread.current])
      end
    end

    context "when called from a fiber on the reactor thread" do
      it "connects on another thread and keeps the reactor running meanwhile" do
        stub_slow_connect(seconds: 1)

        result, ticks = in_reactor_fiber { described_class.new_client({}) }

        expect(result).to eq(client)
        expect(connect_threads.size).to eq(1)
        expect(connect_threads.first).not_to eq(Thread.current)
        expect(ticks).to be >= 5
      end

      it "raises NoDatabaseError for an unknown database" do
        stub_slow_connect(seconds: 0, result: Mysql2::Error.new("Unknown database", nil, 1049))

        result, = in_reactor_fiber { described_class.new_client({}) }

        expect(result).to be_a(ActiveRecord::NoDatabaseError)
      end

      [2003, 2005, 1040, 1045].each do |error_number|
        it "raises ConnectionNotEstablished for MySQL error #{error_number}" do
          stub_slow_connect(seconds: 0, result: Mysql2::Error.new("failed", nil, error_number))

          result, = in_reactor_fiber { described_class.new_client({}) }

          expect(result).to be_a(ActiveRecord::ConnectionNotEstablished)
          expect(result.message).to eq("failed")
        end
      end

      it "re-raises other errors from the connect thread with the caller's frames in the backtrace" do
        stub_slow_connect(seconds: 0, result: TypeError.new("bad config value"))

        result, = in_reactor_fiber { described_class.new_client({}) }

        expect(result).to be_a(TypeError)
        expect(result.message).to eq("bad config value")
        # The thread's own backtrace never reaches new_client; only the appended caller frames do.
        expect(result.backtrace).to include(a_string_matching(/fibered_mysql2_adapter\.rb:\d+:in .*new_client/))
      end

      it "raises ConnectionNotEstablished when the connect thread is killed" do
        FakeConnect.handler = ->(*) { Thread.current.kill }

        result, = in_reactor_fiber { described_class.new_client({}) }

        expect(result).to be_a(ActiveRecord::ConnectionNotEstablished)
        expect(result.message).to match(/connect thread ended without returning a client/)
      end

      it "keeps waiting when the fiber is resumed before the connect finishes" do
        stub_slow_connect(seconds: 0.5)
        result = nil

        EM.run do
          waiter = Fiber.new do
            result = described_class.new_client({})
            EM.stop
          end
          waiter.resume
          EM.add_timer(0.1) { waiter.resume } # a spurious resume while the connect is still running
          EM.add_timer(2) { EM.stop }
        end

        expect(result).to eq(client)
      end

      it "closes the client when the waiting fiber is unwound before the connect finishes" do
        stub_slow_connect(seconds: 0.3)
        expect(client).to receive(:close)
        error = nil

        EM.run do
          waiter = Fiber.new do
            described_class.new_client({})
          rescue => ex
            error = ex
          end
          waiter.resume
          EM.add_timer(0.1) { waiter.raise(RuntimeError, "caller gave up") }
          EM.add_timer(0.8) { EM.stop }
        end

        expect(error).to be_a(RuntimeError)
      end

      it "does not resume the fiber in a later reactor when the reactor stops during the connect, and closes the client" do
        stub_slow_connect(seconds: 0.5)
        expect(client).to receive(:close)
        resumed = false

        EM.run do
          Fiber.new do
            described_class.new_client({})
            resumed = true
          end.resume
          EM.add_timer(0.1) { EM.stop }
        end
        connect_threads.each(&:join)
        run_another_reactor

        expect(resumed).to eq(false)
      end
    end

    context "when called from the reactor's root fiber" do
      it "waits for the connect without yielding, and no resume or close happens afterwards" do
        stub_slow_connect(seconds: 0.2)
        expect(client).not_to receive(:close)
        result = nil

        EM.run do
          result = described_class.new_client({})
          EM.stop
        end
        run_another_reactor

        expect(result).to eq(client)
        expect(connect_threads.first).not_to eq(Thread.current)
      end
    end

    context "with a database host that does not answer" do
      # A non-routable address: the TCP connect gets no answer, so it waits for the full connect_timeout.
      let(:blackhole_host) { ENV.fetch("FIBERED_MYSQL2_BLACKHOLE_HOST", "10.255.255.1") }
      let(:config) { { host: blackhole_host, username: "root", connect_timeout: 2 } }

      def connect_and_count_ticks
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result, ticks = in_reactor_fiber { yield }
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        require_blackholed_connect!(elapsed)
        [result, ticks]
      end

      # The network has to drop the connect for these examples to mean anything. In CI that is a failure, not a skip.
      def require_blackholed_connect!(elapsed)
        return if elapsed >= 1.5

        message = "#{blackhole_host} failed fast (#{elapsed.round(2)} s) instead of timing out; set FIBERED_MYSQL2_BLACKHOLE_HOST " \
                  "to an address this network drops"
        ENV["CI"] ? raise(message) : skip(message)
      end

      it "keeps the reactor running for the whole connect_timeout" do
        result, ticks = connect_and_count_ticks { described_class.new_client(config) }

        expect(result).to be_a(ActiveRecord::ConnectionNotEstablished)
        expect(ticks).to be >= 15
      end

      it "(for comparison) blocks the reactor when Mysql2::EM::Client connects inline" do
        result, ticks = connect_and_count_ticks { Mysql2::EM::Client.new(config) }

        expect(result).to be_a(Mysql2::Error)
        expect(ticks).to be <= 1 # an overdue tick may still fire once before EM.stop takes effect
      end
    end
  end

  describe "#verify! on a connection the server has closed" do
    let(:old_client) { stub_client(ping: false) }
    let(:adapter) { described_class.new(old_client, Logger.new(nil), [], {}) }
    let(:raw_connection_ivar) { Rails.gem_version >= "7.1" ? :@raw_connection : :@connection }

    it "reconnects through new_client off the reactor thread" do
      stub_slow_connect(seconds: 0)

      result, = in_reactor_fiber { adapter.verify! }

      expect(result).not_to be_a(Exception)
      expect(connect_threads.size).to eq(1)
      expect(connect_threads.first).not_to eq(Thread.current)
      expect(adapter.instance_variable_get(raw_connection_ivar)).to eq(client)
    end
  end

  describe "#reconnect! with connection_retries: 1", if: Rails.gem_version >= "7.1" do
    let(:adapter) { described_class.new(client, Logger.new(nil), [], { connection_retries: 1 }) }

    it "retries a fast connect failure after a backoff and reconnects, off the reactor thread" do
      attempts = 0
      reconnected_client = client
      FakeConnect.handler = lambda do |*|
        attempts += 1
        attempts == 1 ? raise(Mysql2::Error.new("Can't connect to MySQL server", nil, 2003)) : reconnected_client
      end
      expect(adapter).to receive(:backoff).with(1).and_call_original

      result, = in_reactor_fiber { adapter.reconnect! }

      expect(result).not_to be_a(Exception)
      expect(attempts).to eq(2)
      expect(connect_threads).to all(satisfy { |thread| thread != Thread.current })
      expect(adapter.instance_variable_get(:@raw_connection)).to eq(client)
    end

    it "raises ConnectionNotEstablished after two failed attempts" do
      FakeConnect.handler = ->(*) { raise Mysql2::Error.new("Can't connect to MySQL server", nil, 2003) }

      result, = in_reactor_fiber { adapter.reconnect! }

      expect(result).to be_a(ActiveRecord::ConnectionNotEstablished)
      expect(connect_threads.size).to eq(2)
    end
  end
end
