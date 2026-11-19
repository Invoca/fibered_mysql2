# frozen_string_literal: true

# Fails any example that leaves a thread running. The adapter connects on separate threads under the reactor, so a
# connect thread that outlives its example would run into the next one (and its stubs) or block process exit.
# This runs before rspec-mocks verifies and resets the example's doubles, so a leaked thread is killed while they are
# still valid.
module ThreadLeakGuard
  # A connect thread that has already queued its EM.next_tick may need a moment to exit, so threads get a shared grace
  # window to finish before they count as leaked.
  GRACE_SECONDS = 2

  def self.leaked_threads
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + GRACE_SECONDS
    Thread.list.select do |thread|
      thread != Thread.current && thread.alive? &&
        !thread.join([deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max)
    end
  end
end

RSpec.configure do |config|
  config.after do |example|
    leaked = ThreadLeakGuard.leaked_threads
    next if leaked.empty?

    leaked.each do |thread|
      thread.kill
      thread.join(1)
    end
    raise "#{example.full_description} left #{leaked.size} thread(s) running: #{leaked.map(&:inspect).join(', ')}"
  end
end
