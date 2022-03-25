# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "fibered_mysql2/version"

Gem::Specification.new do |spec|
  spec.name          = "fibered_mysql2"
  spec.version       = FiberedMysql2::VERSION
  spec.authors       = ["Invoca Development"]
  spec.email         = ["development@invoca.com"]

  spec.summary       = "An adapter for fibered mysql2"
  spec.homepage      = "https://github.com/Invoca/fibered_mysql2"

  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the 'allowed_push_host'
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  spec.metadata = {
    "allowed_push_host" => "https://rubygems.org",
    "homepage_uri"      => spec.homepage
  }

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files         = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency 'em-synchrony', '~> 1.0'
  spec.add_dependency 'rails', '>= 5.2', '< 7'
end
