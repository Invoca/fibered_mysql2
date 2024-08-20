# frozen_string_literal: true

require 'fibered_mysql2/fibered_database_connection_pool'
require 'monitor'

class AsyncTaskHelper
  attr_accessor :tasks
  attr_reader :trace

  def initialize
    @trace = []
    @tasks = []
  end

  def add_trace(message)
    @trace << message
  end

  def wait(task)
    @tasks[task].wait
  end
end

RSpec.describe FiberedMysql2::FiberedDatabaseConnectionPool do
  let(:async_task_helper) { AsyncTaskHelper.new }

  context "fiber-aware Monitor" do
    let(:monitor) { Monitor.new }
    let(:gate) { [0]*3 }
    let(:condition) { monitor.new_cond }

    it "should implement mutual exclusion" do
      in_concurrent_environment do
        monitor
        async_task_helper.tasks = (0...2).map do |i|
          Async do
            async_task_helper.add_trace "task #{i} begin"
            monitor.synchronize do
              async_task_helper.add_trace "task #{i} LOCK"
              async_task_helper.add_trace "task #{i} gate"
              while gate[i] == 0
                sleep(0.001)
              end
              async_task_helper.add_trace "task #{i} UNLOCK"
            end
            async_task_helper.add_trace "task #{i} end"
          end
        end

        sleep(0.001)
        gate[1] = 1
        sleep(0.001)
        gate[0] = 1
        sleep(0.002)
        async_task_helper.wait 0
        async_task_helper.wait 1

        expect(async_task_helper.trace).to eq([
                                 "task 0 begin",
                                 "task 0 LOCK",
                                 "task 0 gate",
                                 "task 1 begin",
                                 "task 0 UNLOCK",
                                 "task 0 end",
                                 "task 1 LOCK",
                                 "task 1 gate",
                                 "task 1 UNLOCK",
                                 "task 1 end"
                             ])
      end
    end

    it "should keep a ref count on the mutex (compete after 1st lock)" do
      in_concurrent_environment do
        monitor
        async_task_helper.tasks = (0...2).map do |i|
          Async do
            async_task_helper.add_trace "task #{i} begin"
            monitor.synchronize do
              async_task_helper.add_trace "task #{i} LOCK"
              async_task_helper.add_trace "task #{i} gate 1"
              while gate[i] == 0
                sleep(0.001)
              end
              monitor.synchronize do
                async_task_helper.add_trace "task #{i} LOCK"
                async_task_helper.add_trace "task #{i} gate 2"
                while gate[i] != 2
                  sleep(0.001)
                end
                async_task_helper.add_trace "task #{i} UNLOCK"
              end
              async_task_helper.add_trace "task #{i} UNLOCK"
            end
            async_task_helper.add_trace "task #{i} end"
          end
        end

        sleep(0.001)
        gate[0] = 1
        sleep(0.001)
        gate[1] = 1
        sleep(0.001)
        gate[0] = 2
        sleep(0.001)
        gate[1] = 2

        async_task_helper.wait 0
        async_task_helper.wait 1

        expect(async_task_helper.trace).to eq([
                                    "task 0 begin",
                                    "task 0 LOCK",
                                    "task 0 gate 1",
                                    "task 1 begin",
                                    "task 0 LOCK",
                                    "task 0 gate 2",
                                    "task 0 UNLOCK",
                                    "task 0 UNLOCK",
                                    "task 0 end",
                                    "task 1 LOCK",
                                    "task 1 gate 1",
                                    "task 1 LOCK",
                                    "task 1 gate 2",
                                    "task 1 UNLOCK",
                                    "task 1 UNLOCK",
                                    "task 1 end",
                                  ])
      end
    end

    it "should keep a ref count on the mutex (compete after 2st lock)" do
      in_concurrent_environment do
        monitor
        async_task_helper.tasks = (0...2).map do |i|
          Async do
            async_task_helper.add_trace "task #{i} begin"
            monitor.synchronize do
              async_task_helper.add_trace "task #{i} LOCK"
              async_task_helper.add_trace "task #{i} gate 1"
              while gate[i] == 0
                sleep(0.001)
              end
              monitor.synchronize do
                async_task_helper.add_trace "task #{i} LOCK"
                async_task_helper.add_trace "task #{i} gate 2"
                while gate[i] != 2
                  sleep(0.001)
                end
                async_task_helper.add_trace "task #{i} UNLOCK"
              end
              async_task_helper.add_trace "task #{i} UNLOCK"
            end
            async_task_helper.add_trace "task #{i} end"
          end
        end

        sleep(0.001)
        gate[0] = 2
        sleep(0.001)
        gate[1] = 1
        sleep(0.001)
        sleep(0.001)
        gate[1] = 2

        async_task_helper.wait 0
        async_task_helper.wait 1

        expect(async_task_helper.trace).to eq([
                                        "task 0 begin",
                                        "task 0 LOCK",
                                        "task 0 gate 1",
                                        "task 1 begin",
                                        "task 0 LOCK",
                                        "task 0 gate 2",
                                        "task 0 UNLOCK",
                                        "task 0 UNLOCK",
                                        "task 0 end",
                                        "task 1 LOCK",
                                        "task 1 gate 1",
                                        "task 1 LOCK",
                                        "task 1 gate 2",
                                        "task 1 UNLOCK",
                                        "task 1 UNLOCK",
                                        "task 1 end",
                                      ])
      end
    end

    it "should implement wait/signal on the condition with priority over other mutex waiters" do
      in_concurrent_environment do
        condition
        async_task_helper.tasks = { 0 => :wait, 1 => :signal, 2 => nil }.map do |i, condition_handling|
          Async do
            async_task_helper.add_trace "task #{i} begin"
            monitor.synchronize do
              async_task_helper.add_trace "task #{i} LOCK"
              monitor.synchronize do
                async_task_helper.add_trace "task #{i} LOCK"
                async_task_helper.add_trace "task #{i} gate 1"
                while gate[i] == 0
                  sleep(0.001)
                end
                case condition_handling
                when :wait
                  async_task_helper.add_trace "task #{i} WAIT"
                  condition.wait
                  async_task_helper.add_trace "task #{i} UNWAIT"
                when :signal
                  async_task_helper.add_trace "task #{i} SIGNAL"
                  condition.signal
                  async_task_helper.add_trace "task #{i} UNSIGNAL"
                end
                async_task_helper.add_trace "task #{i} UNLOCK"
              end
              async_task_helper.add_trace "task #{i} UNLOCK"
            end
            async_task_helper.add_trace "task #{i} end"
          end
        end

        sleep(0.001)
        gate[0] = 1
        sleep(0.001)
        gate[1] = 1
        sleep(0.001)
        gate[2] = 1
        sleep(0.002)
        async_task_helper.wait 0
        async_task_helper.wait 1
        async_task_helper.wait 2

        expect(async_task_helper.trace).to eq([
                                 "task 0 begin",
                                 "task 0 LOCK",
                                 "task 0 LOCK",    # task 0 locks the mutex
                                 "task 0 gate 1",
                                 "task 1 begin",
                                 # task 1 yields because it can't lock the mutex
                                 "task 2 begin",
                                 # task 2 yields because it can't lock the mutex
                                 "task 0 WAIT",
                                 # task 0 yields while waiting for condition to be signaled
                                 "task 1 LOCK",
                                 "task 1 LOCK",
                                 "task 1 gate 1",
                                 "task 1 SIGNAL",
                                 "task 1 UNSIGNAL",
                                 "task 1 UNLOCK",
                                 "task 1 UNLOCK",
                                 "task 1 end",
                                 # task 1 yields to task 0 that was waiting for the signal (this takes priority over task 2 that was already waiting on the mutex)
                                 "task 0 UNWAIT",
                                 "task 0 UNLOCK",
                                 "task 0 UNLOCK",
                                 "task 0 end",
                                 "task 2 LOCK",
                                 "task 2 LOCK",
                                 "task 2 gate 1",
                                 "task 2 UNLOCK",
                                 "task 2 UNLOCK",
                                 "task 2 end"
                               ])
      end
    end
  end

  context ActiveRecord::ConnectionAdapters::ConnectionPool::Queue do
    let(:name) { 'primary' }
    let(:config) {{ database: 'rr_prod', host: 'master.ringrevenue.net' }}
    let(:adapter_method) { :mysql2 }
    let(:spec) do
      if ActiveRecord.gem_version < "6.1"
        ActiveRecord::ConnectionAdapters::ConnectionSpecification.new(name, config, adapter_method)
      else
        ActiveRecord::ConnectionAdapters::PoolConfig.new(name, ActiveRecord::DatabaseConfigurations::HashConfig.new("staging", "staging", config))
      end
    end

    let(:cp) { ActiveRecord::ConnectionAdapters::ConnectionPool.new(spec) }
    let(:queue) { cp.instance_variable_get(:@available) }

    let(:connection) { double(Object, lease: true) }
    let(:polled) { [] }

    context "poll" do
      it "should return added entries immediately" do
        in_concurrent_environment do
          queue.add(connection)
          task = Async { polled << queue.poll(connection) }
          task.wait
          expect(polled).to eq([connection])
        end
      end

      it "should block when queue is empty" do
        in_concurrent_environment do
          task = Async { polled << queue.poll(10) }
          sleep(0.001)
          queue.add(connection)
          task.wait
          expect(polled).to eq([connection])
        end
      end
    end

    context 'Reaper' do
      subject { ActiveRecord::ConnectionAdapters::ConnectionPool.new(spec) }
      it 'should be explicitly disabled and therefore not start up a reaper thread' do
        threads_before = Thread.list
        subject
        expect(Thread.list - threads_before).to be_empty
      end
    end
  end

  context ActiveRecord::ConnectionAdapters::ConnectionPool do
    let(:client) { double(Mysql2::Client) }
    let(:pool_size) { 10 }
    let(:establish_connection) do
      ActiveRecord::Base.establish_connection(
        :adapter => 'fibered_mysql2',
        :database => 'widgets',
        :username => 'root',
        :pool => pool_size
      )
    end

    before :each do
      allow(client).to receive(:query_options) { {} }
      allow(client).to receive(:escape) { |query| query }
      allow(client).to receive(:ping) { true }
      allow(client).to receive(:close)
      allow(client).to receive(:info).and_return({ version: "5.7.27" })
      allow(client).to receive(:server_info).and_return({ version: "5.7.27" })
      allow(Mysql2::Client).to receive(:new) { |config| client }

      establish_connection
    end

    after :each do
      in_concurrent_environment do
        f = Async { ActiveRecord::Base.remove_connection }
        f.wait
      end
    end

    context "with more than 1 connection in the pool" do
      it "should serve separate connections per fiber" do
        in_concurrent_environment do
          expected_query = "SET  @@SESSION.sql_mode = CONCAT(CONCAT(@@sql_mode, ',STRICT_ALL_TABLES'), ',NO_AUTO_VALUE_ON_ZERO'),  @@SESSION.sql_auto_is_null = 0, @@SESSION.wait_timeout = 2147483"
          expect(client).to receive(:query) do |*args|
            expect(args).to eq([expected_query])
          end.exactly(2).times

          c0 = ActiveRecord::Base.connection
          c1 = nil
          task_fiber = nil
          task = Async { c1 = ActiveRecord::Base.connection; task_fiber = Fiber.current }
          task.wait

          expect(c0).to be
          expect(c1).to be
          expect(c1).to_not eq(c0)
          expect(c0.owner).to eq(Fiber.current)
          expect(c1.owner).to eq(task_fiber)
          expect(c0.in_use?).to be_truthy
          expect(c1.in_use?).to be_truthy
        end
      end

      it "should reclaim connections when the fiber has exited" do
        in_concurrent_environment do
          expect(client).to receive(:query) { }.exactly(2).times

          reap_connection_count = Rails::VERSION::MAJOR > 4 ? 5 : 3
          expect(ActiveRecord::Base.connection_pool).to receive(:reap_connections).with(no_args).exactly(reap_connection_count).times.and_call_original

          ActiveRecord::Base.connection
          c1 = nil
          c1_owner = nil
          task1_fiber = nil
          task1 = Async { c1 = ActiveRecord::Base.connection; c1_owner = c1.owner; task1_fiber = Fiber.current }
          task1.wait

          c2 = nil
          c2_owner = nil
          task2_fiber = nil
          task2 = Async { c2 = ActiveRecord::Base.connection; c2_owner = c2.owner; task2_fiber = Fiber.current }
          task2.wait

          expect(c1_owner).to eq(task1_fiber)
          expect(c2_owner).to eq(task2_fiber)
          expect(c1.object_id).to eq(c2.object_id)
        end
      end
    end

    context "with only 1 connection in the pool" do
      let(:pool_size) { 1 }

      it "should hand off connection on checkin to any task waiting on checkout" do
        expect(client).to receive(:query) { }.at_least(1).times

        in_concurrent_environment do
          expect(ActiveRecord::Base.connection_pool).to receive(:reap_connections).with(no_args).exactly(4).times.and_call_original

          c0 = ActiveRecord::Base.connection
          connection_pool = c0.pool

          c1 = nil
          task1_fiber = nil
          task1 = Async { task1_fiber = Fiber.current; c1 = ActiveRecord::Base.connection }

          sleep(0.001)

          expect(task1_fiber).to be
          expect(c1).to eq(nil) # should block because there is only one connection

          connection_pool.checkin(c0)
          task1.wait
          while task1_fiber.alive?
            sleep(0.00001)
          end

          expect(c1).to eq(c0)

          ActiveRecord::Base.connection # Reset owner before calling remove_connection
        end
      end
    end
  end
end
