# frozen_string_literal: true

require 'fibered_mysql2/async_task'

RSpec.describe FiberedMysql2::AsyncTask do
  describe '.current_or_none' do
    subject { described_class.current_or_none }

    context 'when not in Async' do
      it { is_expected.to eq(:none) }
    end

    context 'when in Async at the root level' do
      it 'returns :root task' do
        in_concurrent_environment do
          is_expected.to eq(Async::Task.current)
        end
      end
    end

    context 'when in Async and a task' do
      it 'returns current task' do
        in_concurrent_environment do
          Async do |task|
            is_expected.to eq(task)
          end
        end
      end
    end
  end
end