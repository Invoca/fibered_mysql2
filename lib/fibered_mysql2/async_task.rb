# frozen_string_literal: true

module FiberedMysql2
  module AsyncTask
    class << self
      # Adapted from https://github.com/socketry/async/blob/main/lib/async/task.rb#L236-L238
      def current_or_none
        Thread.current[:async_task] || :none
      end
    end
  end
end
