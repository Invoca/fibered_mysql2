# frozen_string_literal: true

require_relative '../../lib/active_record/connection_adapters/fibered_mysql2_adapter'

# Needs a real MySQL server, so it is pending (with the reason below) unless FIBERED_MYSQL2_TEST_MYSQL_HOST is set, e.g.
#   docker run -d --rm -p 127.0.0.1:23306:3306 -e MYSQL_ALLOW_EMPTY_PASSWORD=yes mysql:8.0
#   FIBERED_MYSQL2_TEST_MYSQL_HOST=127.0.0.1 FIBERED_MYSQL2_TEST_MYSQL_PORT=23306 bundle exec rspec
RSpec.describe FiberedMysql2::FiberedMysql2Adapter, "connecting to a real MySQL server from the reactor" do
  before do
    ENV["FIBERED_MYSQL2_TEST_MYSQL_HOST"] or skip("needs a MySQL server: set FIBERED_MYSQL2_TEST_MYSQL_HOST (and _PORT)")
  end

  let(:config) do
    {
      host:            ENV["FIBERED_MYSQL2_TEST_MYSQL_HOST"],
      port:            Integer(ENV.fetch("FIBERED_MYSQL2_TEST_MYSQL_PORT", "3306")),
      username:        ENV.fetch("FIBERED_MYSQL2_TEST_MYSQL_USERNAME", "root"),
      password:        ENV.fetch("FIBERED_MYSQL2_TEST_MYSQL_PASSWORD", ""),
      connect_timeout: 5
    }
  end

  it "returns clients, connected on other threads, that run async queries on the reactor" do
    results = []
    errors = []

    EM.run do
      pending_fibers = 20
      20.times do |index|
        Fiber.new do
          client = described_class.new_client(config)
          results << client.query("SELECT #{index} AS i, CONNECTION_ID() AS id").first
          client.close
        rescue => ex
          errors << ex
        ensure
          pending_fibers -= 1
          EM.stop if pending_fibers.zero?
        end.resume
      end
    end

    expect(errors).to eq([])
    expect(results.map { |row| row["i"] }).to match_array(0...20)
    expect(results.map { |row| row["id"] }.uniq.size).to eq(20)
  end

  it "reconnects and retries a transaction's BEGIN after the server kills the connection (connection_retries: 1)",
     if: Rails.gem_version >= "7.1" do
    # A separate class, so this does not replace the pool other examples set up on ActiveRecord::Base.
    stub_const("NonblockingConnectSpecRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    NonblockingConnectSpecRecord.establish_connection(config.merge(adapter: "fibered_mysql2", connection_retries: 1))
    connection_ids = []
    error = nil

    EM.run do
      Fiber.new do
        connection = NonblockingConnectSpecRecord.connection
        connection_ids << connection.select_value("SELECT CONNECTION_ID()")
        Mysql2::Client.new(config).tap { |killer| killer.query("KILL #{connection_ids.first}") }.close

        connection.transaction { connection_ids << connection.select_value("SELECT CONNECTION_ID()") }
      rescue => ex
        error = ex
      ensure
        NonblockingConnectSpecRecord.remove_connection
        EM.stop
      end.resume
    end

    expect(error).to be_nil
    expect(connection_ids.size).to eq(2)
    expect(connection_ids.last).not_to eq(connection_ids.first)
  end
end
