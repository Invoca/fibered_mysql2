# frozen_string_literal: true

RSpec.describe AsyncMysql2 do
  describe 'VERSION' do
    subject { AsyncMysql2::VERSION }
    it { should_not be_nil }
  end
end
