# frozen_string_literal: true

module FiberedMysql2
  module HashConfigOverride
    # Override the reaping_frequency method to return nil so that the connection pool does not reap connections when in fibered mode.
    def reaping_frequency
      nil
    end
  end
end

if ActiveRecord.gem_version > "6.0"
  ActiveRecord::DatabaseConfigurations::HashConfig.prepend(FiberedMysql2::HashConfigOverride)
end
