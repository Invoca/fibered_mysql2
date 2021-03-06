[![Coverage Status](https://coveralls.io/repos/github/Invoca/fibered_mysql2/badge.svg?branch=master)](https://coveralls.io/github/Invoca/fibered_mysql2?branch=master)

# FiberedMysql2

FiberedMysql2 adds Fiber support to `ActiveRecord::ConnectionAdapters::EMMysql2Adapter`

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'fibered_mysql2'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install fibered_mysql2

## Support
Tested with Rails versions 4.2, 5.2, and 6.0.

## Usage

Behaves the same as `ActiveRecord::ConnectionAdapters::EMMysql2Adapter` but with added Fiber safety while leasing/expiring connections.
```ruby
connection = FiberedMysql2::FiberedMysql2Adapter.new(client, logger, options, config)
connection.lease
connection.expire # Rails 5+ only
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/invoca/fibered_mysql2.
