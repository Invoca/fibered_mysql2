# frozen_string_literal: true

RSpec.describe FiberedMysql2 do
  describe 'VERSION' do
    subject { FiberedMysql2::VERSION }
    it { should_not be_nil }
  end
end
