# frozen_string_literal: true

# Replaces Mysql2::EM::Client.new with a plain Ruby handler for the current example.
#
# On the reactor thread the adapter calls Mysql2::EM::Client.new on a separate connect thread. An rspec-mocks message
# stub invoked from that thread intermittently crashed the Ruby VM (a segfault while freeing a Mutex, during the run or at
# exit), so the specs fake the constructor here instead and keep test doubles off the connect thread.
module FakeConnect
  LOCK = Mutex.new

  module ClientNew
    def new(*args, **kwargs)
      if (handler = FakeConnect.handler)
        FakeConnect.record_call
        handler.call(*args, **kwargs)
      else
        super
      end
    end
  end

  class << self
    attr_accessor :handler

    # The thread each faked connect ran on, in call order.
    def call_threads
      LOCK.synchronize { (@call_threads ||= []).dup }
    end

    def record_call
      LOCK.synchronize { (@call_threads ||= []) << Thread.current }
    end

    def reset!
      LOCK.synchronize { @call_threads = [] }
      self.handler = nil
    end
  end
end

Mysql2::EM::Client.singleton_class.prepend(FakeConnect::ClientNew)

RSpec.configure do |config|
  config.after { FakeConnect.reset! }
end
