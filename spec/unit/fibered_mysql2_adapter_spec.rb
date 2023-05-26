# frozen_string_literal: true

require_relative '../../lib/active_record/connection_adapters/fibered_mysql2_adapter'

RSpec.describe FiberedMysql2::FiberedMysql2Adapter do
  let(:client) { double(Mysql2::Client) }
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

    it { in_concurrent_environment { should eq(Async::Task.current) } }

    if Rails::VERSION::MAJOR > 4
      context 'if the connection is already being used' do
        it 'by the current Async::Task' do
          in_concurrent_environment do
            adapter.lease
            expect { subject }.to raise_exception(ActiveRecord::ActiveRecordError, "Cannot lease connection; it is already leased by the current Async::Task.")
          end
        end

        it 'by another Async::Task' do
          in_concurrent_environment do
            adapter.lease
            new_task = Async do
              expect { subject }.to raise_exception(ActiveRecord::ActiveRecordError, /Cannot lease connection; it is already in use by a different Async::Task:/)
            end
            new_task.wait
          end
        end
      end
    end
  end

  if Rails::VERSION::MAJOR > 4
    context '#expire' do
      subject { adapter.expire }

      context 'if the connection is not in use' do
        it 'raises' do
          in_concurrent_environment do
            expect { subject }.to raise_exception(ActiveRecord::ActiveRecordError, "Cannot expire connection; it is not currently leased.")
          end
        end
      end

      context 'if the connection is being used' do
        it { in_concurrent_environment { adapter.lease; should be_nil } }

        it 'by a different Async::Task' do
          in_concurrent_environment do
            adapter.lease
            new_task = Async do
              expect { subject }.to raise_exception(ActiveRecord::ActiveRecordError, /Cannot expire connection; it is owned by a different Async::Task:/)
            end
            new_task.wait
          end
        end
      end
    end

    context '#steal!' do
      subject { adapter.steal! }

      context 'if the connection is not in use' do
        it 'raises' do
          expect { subject }.to raise_exception(ActiveRecord::ActiveRecordError, "Cannot steal connection; it is not currently leased.")
        end
      end

      context 'if the connection is being used' do
        it do
          in_concurrent_environment do
            ActiveRecord::Base.establish_connection(
              adapter: 'fibered_mysql2',
              database: 'widgets',
              username: 'root',
              pool: 10
            )

            adapter.pool = ActiveRecord::Base.connection_pool
            adapter.lease

            should be_nil
          end
        end

        it 'by a different Async::Task' do
          in_concurrent_environment do
            ActiveRecord::Base.establish_connection(
              adapter: 'fibered_mysql2',
              database: 'widgets',
              username: 'root',
              pool: 10
            )

            adapter.pool = ActiveRecord::Base.connection_pool
            adapter.lease

            new_task = Async { subject }
            new_task.wait

            expect(adapter.owner).to eq(new_task)
          end
        end
      end
    end

    context 'other mixins' do
      it 'raises if @owner has been overwritten with a non-Fiber' do
        adapter.instance_variable_set(:@owner, Thread.new { })

        expect { adapter.expire }.to raise_exception(RuntimeError, /@owner must be an Async::Task!/i)
      end

      it "doesn't raise if @owner is nil" do
        adapter.instance_variable_set(:@owner, nil)

        expect { adapter.send(:owner_task) }.to_not raise_exception
      end
    end
  end
end
