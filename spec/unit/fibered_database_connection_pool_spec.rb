# frozen_string_literal: true

require 'fibered_mysql2/fibered_database_connection_pool'

class TestMonitor
  include FiberedMysql2::FiberedMonitorMixin

  attr_reader :mon_count, :condition

  def initialize
    mon_initialize

    @condition = new_cond
  end
end

describe FiberedMysql2::FiberedDatabaseConnectionPool do
  before do
    @next_ticks = []
    @trace      = []
    allow(EM).to receive(:next_tick) { |&block| queue_next_tick(&block) }
  end

  context FiberedMysql2::FiberedMonitorMixin do
    let(:monitor) { TestMonitor.new }

    it "should implement mutual exclusion" do
      @fibers = (0...2).map do
        Fiber.new do |i|
          trace "fiber #{i} begin"
          monitor.synchronize do
            trace "fiber #{i} LOCK"
            trace "fiber #{i} yield"
            Fiber.yield
            trace "fiber #{i} UNLOCK"
          end
          trace "fiber #{i} end"
        end
      end

      resume 0
      resume 1
      resume 0
      resume 1

      expect(@trace).to eq([
                               "fiber 0 RESUME",
                               "fiber 0 begin",
                               "fiber 0 LOCK",
                               "fiber 0 yield",
                               "fiber 1 RESUME",
                               "fiber 1 begin",    # fiber 1 yields because it can't lock mutex
                               "fiber 0 RESUME",
                               "fiber 0 UNLOCK",
                               "next_tick queued",
                               # 1 yields back to 0
                               "fiber 0 end",
                               "next_tick.call",    # fiber 0 yields to fiber 1
                               "fiber 1 LOCK",
                               "fiber 1 yield",
                               "fiber 1 RESUME",
                               "fiber 1 UNLOCK",
                               "fiber 1 end"
                           ])
    end

    it "should keep a ref count on the mutex (yield after 1st lock)" do
      @fibers = (0...2).map do
        Fiber.new do |i|
          trace "fiber #{i} begin"
          monitor.synchronize do
            trace "fiber #{i} LOCK #{monitor.mon_count}"
            trace "fiber #{i} yield A"
            Fiber.yield
            monitor.synchronize do
              trace "fiber #{i} LOCK #{monitor.mon_count}"
              trace "fiber #{i} yield B"
              Fiber.yield
              trace "fiber #{i} UNLOCK #{monitor.mon_count}"
            end
            trace "fiber #{i} UNLOCK #{monitor.mon_count}"
          end
          trace "fiber #{i} end"
        end
      end

      resume 0
      resume 1
      resume 0
      resume 0
      resume 1
      resume 1

      expect(@trace).to eq([
                               "fiber 0 RESUME",
                               "fiber 0 begin",
                               "fiber 0 LOCK 1",
                               "fiber 0 yield A",
                               "fiber 1 RESUME",
                               "fiber 1 begin",
                               # fiber 1 yields because it can't get the lock
                               "fiber 0 RESUME",
                               "fiber 0 LOCK 2",
                               "fiber 0 yield B",
                               "fiber 0 RESUME",
                               "fiber 0 UNLOCK 2",
                               "fiber 0 UNLOCK 1",
                               "next_tick queued",
                               "fiber 0 end",
                               "next_tick.call",    # fiber 0 yields to fiber 1
                               "fiber 1 LOCK 1",
                               "fiber 1 yield A",
                               "fiber 1 RESUME",
                               "fiber 1 LOCK 2",
                               "fiber 1 yield B",
                               "fiber 1 RESUME",
                               "fiber 1 UNLOCK 2",
                               "fiber 1 UNLOCK 1",
                               "fiber 1 end"
                           ])
    end

    it "should keep a ref count on the mutex (yield after 2nd lock)" do
      @fibers = (0...2).map do
        Fiber.new do |i|
          trace "fiber #{i} begin"
          monitor.synchronize do
            trace "fiber #{i} LOCK #{monitor.mon_count}"
            trace "fiber #{i} yield A"
            Fiber.yield
            monitor.synchronize do
              trace "fiber #{i} LOCK #{monitor.mon_count}"
              trace "fiber #{i} yield B"
              Fiber.yield
              trace "fiber #{i} UNLOCK #{monitor.mon_count}"
            end
            trace "fiber #{i} UNLOCK #{monitor.mon_count}"
          end
          trace "fiber #{i} end"
        end
      end

      resume 0
      resume 0
      resume 1
      resume 0
      resume 1
      resume 1

      expect(@trace).to eq([
                               "fiber 0 RESUME",
                               "fiber 0 begin",
                               "fiber 0 LOCK 1",
                               "fiber 0 yield A",
                               "fiber 0 RESUME",
                               "fiber 0 LOCK 2",
                               "fiber 0 yield B",
                               "fiber 1 RESUME",
                               "fiber 1 begin",
                               # fiber 1 yields because it can't get the lock
                               "fiber 0 RESUME",
                               "fiber 0 UNLOCK 2",
                               "fiber 0 UNLOCK 1",
                               "next_tick queued",
                               "fiber 0 end",
                               "next_tick.call",    # fiber 0 yields to fiber 1
                               "fiber 1 LOCK 1",
                               "fiber 1 yield A",
                               "fiber 1 RESUME",
                               "fiber 1 LOCK 2",
                               "fiber 1 yield B",
                               "fiber 1 RESUME",
                               "fiber 1 UNLOCK 2",
                               "fiber 1 UNLOCK 1",
                               "fiber 1 end"
                           ])
    end

    it "should implement wait/signal on the condition with priority over other mutex waiters" do
      @fibers = (0...3).map do
        Fiber.new do |i, condition_handling|
          trace "fiber #{i} begin"
          monitor.synchronize do
            trace "fiber #{i} LOCK #{monitor.mon_count}"
            monitor.synchronize do
              trace "fiber #{i} LOCK #{monitor.mon_count}"
              trace "fiber #{i} yield"
              Fiber.yield
              case condition_handling
              when :wait
                trace "fiber #{i} WAIT"
                monitor.condition.wait
                trace "fiber #{i} UNWAIT"
              when :signal
                trace "fiber #{i} SIGNAL"
                monitor.condition.signal
                trace "fiber #{i} UNSIGNAL"
              end
              trace "fiber #{i} UNLOCK #{monitor.mon_count}"
            end
            trace "fiber #{i} UNLOCK #{monitor.mon_count}"
          end
          trace "fiber #{i} end"
        end
      end

      resume 0, :wait
      resume 1, :signal
      resume 2, nil
      resume 0
      resume 1
      resume 2

      expect(@trace).to eq([
                               "fiber 0 RESUME",
                               "fiber 0 begin",
                               "fiber 0 LOCK 1",
                               "fiber 0 LOCK 2",    # fiber 0 locks the mutex
                               "fiber 0 yield",
                               "fiber 1 RESUME",
                               "fiber 1 begin",
                               # fiber 1 yields because it can't lock the mutex
                               "fiber 2 RESUME",
                               "fiber 2 begin",
                               # fiber 2 yields because it can't lock the mutex
                               "fiber 0 RESUME",
                               "fiber 0 WAIT",
                               "next_tick queued",
                               # fiber 0 yields while waiting for condition to be signaled
                               "next_tick.call",    # fiber 0 yields mutex to fiber 1
                               "fiber 1 LOCK 1",
                               "fiber 1 LOCK 2",
                               "fiber 1 yield",
                               "fiber 1 RESUME",
                               "fiber 1 SIGNAL",
                               "next_tick queued",
                               "fiber 1 UNSIGNAL",
                               "fiber 1 UNLOCK 2",
                               "fiber 1 UNLOCK 1",
                               "next_tick queued",
                               "fiber 1 end",
                               "next_tick.call",
                               "next_tick.call",    # fiber 1 yields to fiber 0 that was waiting for the signal (this takes priority over fiber 2 that was already waiting on the mutex)
                               "fiber 0 UNWAIT",
                               "fiber 0 UNLOCK 2",
                               "fiber 0 UNLOCK 1",
                               "next_tick queued",
                               "fiber 0 end",
                               "next_tick.call",
                               "fiber 2 LOCK 1",
                               "fiber 2 LOCK 2",
                               "fiber 2 yield",
                               "fiber 2 RESUME",
                               "fiber 2 UNLOCK 2",
                               "fiber 2 UNLOCK 1",
                               "fiber 2 end"
                           ])
    end
  end

  context ActiveRecord::ConnectionAdapters::ConnectionPool::Queue do
    before do
      @timers     = []
      allow(EM).to receive(:add_timer) { |&block| queue_timer(&block); block }
      allow(EM).to receive(:cancel_timer) { |block| cancel_timer(block) }
    end

    context "poll" do
      it "should return added entries immediately" do
        spec = case Rails::VERSION::MAJOR
               when 4
                 ActiveRecord::ConnectionAdapters::ConnectionSpecification.new(
                     { database: 'rr_prod', host: 'master.ringrevenue.net' },
                     :em_mysql2
                 )
               else
                 ActiveRecord::ConnectionAdapters::ConnectionSpecification.new(
                     'primary',
                     { database: 'rr_prod', host: 'master.ringrevenue.net' },
                     :em_mysql2
                 )
               end

        cp = ActiveRecord::ConnectionAdapters::ConnectionPool.new(spec)
        connection = double(Object, lease: true)
        queue = cp.instance_variable_get(:@available)
        queue.add(connection)
        polled = []
        fiber = Fiber.new { polled << queue.poll(connection) }
        fiber.resume
        expect(polled).to eq([connection])
      end

      it "should block when queue is empty" do
        spec = case Rails::VERSION::MAJOR
               when 4
                 ActiveRecord::ConnectionAdapters::ConnectionSpecification.new(
                     { database: 'rr_prod', host: 'master.ringrevenue.net' },
                     :em_mysql2
                 )
               else
                 ActiveRecord::ConnectionAdapters::ConnectionSpecification.new(
                     'primary',
                     { database: 'rr_prod', host: 'master.ringrevenue.net' },
                     :em_mysql2
                 )
               end
        cp = ActiveRecord::ConnectionAdapters::ConnectionPool.new(spec)
        queue = cp.instance_variable_get(:@available)
        connection = double(Object, lease: true)
        polled = []
        fiber = Fiber.new { polled << queue.poll(10) }
        fiber.resume
        queue.add(connection)
        run_next_ticks
        expect(polled).to eq([connection])
      end
    end
  end

  context ActiveRecord::ConnectionAdapters::ConnectionPool do
    let(:client) { double(Mysql2::EM::Client) }

    context "with more than 1 connection in the pool" do
      before :each do
        ActiveRecord::Base.establish_connection(
          :adapter => 'fibered_mysql2',
          :database => 'widgets',
          :username => 'root',
          :pool => 10
        )
        allow(client).to receive(:query_options) { {} }
        allow(client).to receive(:escape) { |query| query }
        allow(client).to receive(:ping) { true }
        allow(client).to receive(:close)
        allow(client).to receive(:info).and_return({ version: "5.7.27" })
        allow(client).to receive(:server_info).and_return({ version: "5.7.27" })
        allow(Mysql2::EM::Client).to receive(:new) { |config| client }
      end

      after :each do
        EM.run do
          f = Fiber.new { ActiveRecord::Base.remove_connection }
          f.resume
          EM.stop
        end
      end

      it "should serve separate connections per fiber" do
        version_specific_expectation = if Rails::VERSION::MAJOR > 4
                                         "SET  @@SESSION.sql_mode = CONCAT(CONCAT(@@sql_mode, ',STRICT_ALL_TABLES'), ',NO_AUTO_VALUE_ON_ZERO'),  @@SESSION.sql_auto_is_null = 0, @@SESSION.wait_timeout = 2147483"
                                       else
                                         "SET  @@SESSION.sql_auto_is_null = 0, @@SESSION.wait_timeout = 2147483, @@SESSION.sql_mode = 'STRICT_ALL_TABLES'"
                                       end
        expect(client).to receive(:query) do |*args|
          expect(args).to eq([version_specific_expectation])
        end.exactly(2).times

        c0 = ActiveRecord::Base.connection
        c1 = nil
        fiber = Fiber.new { c1 = ActiveRecord::Base.connection }
        fiber.resume

        expect(c0).to be
        expect(c1).to be
        expect(c1).to_not eq(c0)
        expect(c0.owner).to eq(Fiber.current)
        expect(c1.owner).to eq(fiber)
        expect(c0.in_use?).to be
        expect(c1.in_use?).to be
      end

      it "should reclaim connections when the fiber has exited" do
        expect(client).to receive(:query) { }.exactly(2).times

        reap_connection_count = Rails::VERSION::MAJOR > 4 ? 5 : 3
        expect(ActiveRecord::Base.connection_pool).to receive(:reap_connections).with(no_args).exactly(reap_connection_count).times.and_call_original

        ActiveRecord::Base.connection
        c1 = nil
        fiber1 = Fiber.new { c1 = ActiveRecord::Base.connection }

        c2 = nil
        fiber2 = Fiber.new { c2 = ActiveRecord::Base.connection }

        fiber1.resume
        expect(c1.owner).to eq(fiber1)

        fiber2.resume
        expect(c2.owner).to eq(fiber2)

        expect(c1.object_id).to eq(c2.object_id)
      end
    end

    context "with only 1 connection in the pool" do
      before :each do
        ActiveRecord::Base.establish_connection(
          :adapter => 'fibered_mysql2',
          :database => 'widgets',
          :username => 'root',
          :pool => 1
        )
        allow(client).to receive(:query_options) { {} }
        allow(client).to receive(:escape) { |query| query }
        allow(client).to receive(:ping) { true }
        allow(client).to receive(:close)
        allow(client).to receive(:info).and_return({ version: "5.7.27" })
        allow(client).to receive(:server_info).and_return({ version: "5.7.27" })
        allow(Mysql2::EM::Client).to receive(:new) { |config| client }
      end

      after :each do
        ActiveRecord::Base.connection
        EM.run do
          f = Fiber.new { ActiveRecord::Base.remove_connection }
          f.resume
          EM.stop
        end
      end

      it "should hand off connection on checkin to any fiber waiting on checkout" do
        expect(client).to receive(:query) { }.exactly(1).times

        EM.run do
          reap_connection_count = Rails::VERSION::MAJOR > 4 ? 4 : 3
          expect(ActiveRecord::Base.connection_pool).to receive(:reap_connections).with(no_args).exactly(reap_connection_count).times.and_call_original

          c0 = ActiveRecord::Base.connection
          connection_pool = c0.pool
          c1 = nil

          fiber1 = Fiber.new do
            run_next_ticks
            c1 = ActiveRecord::Base.connection.tap { run_next_ticks }
          end
          fiber1.resume

          expect(c1).to eq(nil) # should block because there is only one connection

          connection_pool.checkin(c0)
          run_next_ticks

          expect(c1).to eq(c0)

          EM.stop
        end
      end
    end
  end

  private

  def trace(message)
    @trace << message
  end

  def queue_next_tick(&block)
    block or raise "Nil block passed!"
    trace "next_tick queued"
    @next_ticks << block
  end

  def run_next_ticks
    while (next_tick_block = @next_ticks.shift)
      @trace << "next_tick.call"
      next_tick_block.call
    end
  end

  def resume(fiber, *args)
    trace "fiber #{fiber} RESUME"
    @fibers[fiber].resume(fiber, *args)
    run_next_ticks
  end

  def queue_timer(&block)
    @timers << block
  end

  def cancel_timer(timer_block)
    @timers.delete_if { |block| block == timer_block }
  end
end
