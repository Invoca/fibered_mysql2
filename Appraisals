# frozen_string_literal: true

require "appraisal/matrix"

appraisal_matrix(rails: [">= 7.0", "< 7.2"]) do |rails:|
  if rails < "7.1"
    gem "mutex_m"
  end
end
