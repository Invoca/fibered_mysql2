# frozen_string_literal: true

require_relative '../../lib/fibered_mysql2/hash_config_override'

RSpec.describe FiberedMysql2::HashConfigOverride, if: ActiveRecord.gem_version >= "6.1" do
  describe "#reaping_frequency" do
    subject { hash_config.reaping_frequency }
    let(:hash_config) do
      ActiveRecord::DatabaseConfigurations::HashConfig.new('staging', 'staging', { reaping_frequency: 30 })
    end

    it { is_expected.to be_nil }
  end
end
