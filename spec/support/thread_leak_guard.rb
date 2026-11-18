# frozen_string_literal: true

# Fails any example that leaves a thread running. The adapter connects on separate threads under the reactor, so a
# connect thread that outlives its example would run into the next one (and its stubs) or block process exit.
# This runs before rspec-mocks verifies and resets the example's doubles, so a leaked thread is killed while they are
# still valid.
RSpec.configure do |config|
  config.after do |example|
    # A connect thread that has already queued its EM.next_tick may need a moment to exit.
    leaked = Thread.list.select { |thread| thread != Thread.current && thread.alive? && !thread.join(0.5) }
    next if leaked.empty?

    leaked.each do |thread|
      thread.kill
      thread.join(1)
    end
    raise "#{example.full_description} left #{leaked.size} thread(s) running: #{leaked.map(&:inspect).join(', ')}"
  end
end
