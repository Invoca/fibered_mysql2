# frozen_string_literal: true

module FiberedMysql2
  module FiberedMutexWithWaiterPriority
    # Note: @waiters is a bit confusing because the first waiter is actually the current fiber that has it locked;
    # the _rest_ of @waiters are the actual waiters
    def sleep(timeout = nil)
      unlock
      beg = Time.now
      current = Fiber.current
      @slept[current] = true
      if timeout
        timer = EM.add_timer(timeout) do
          _wakeup(current)
        end
        Fiber.yield
        EM.cancel_timer(timer) # if we resumed not via timer
      else
        Fiber.yield
      end
      @slept.delete(current)
      yield if block_given?

      # Invoca patch: inline lock that puts us at the front of the mutex @waiters queue instead of the back
      # ==========================
      @waiters.unshift(current)
      Fiber.yield if @waiters.size > 1
      # ==========================

      Time.now - beg
    end
  end
end
