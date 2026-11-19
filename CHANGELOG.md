# CHANGELOG for `fibered_mysql2`

Inspired by [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

Note: this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] - 2026-11-18
### Changed
- On the EventMachine reactor thread, `FiberedMysql2Adapter.new_client` now connects on a separate thread and yields the
  calling fiber until the connect finishes, so a database that does not answer no longer stops the reactor for
  `connect_timeout` on every connect attempt, including each Rails 7.1 `connection_retries` attempt. Off the reactor
  thread it connects inline as before. On the reactor's root fiber, which cannot yield, the connect runs on the separate
  thread but the root fiber blocks until it finishes, so the reactor stops for the connect as before. Errors map as
  before: 1049 raises `ActiveRecord::NoDatabaseError` and any other `Mysql2::Error` raises
  `ActiveRecord::ConnectionNotEstablished`.
  - Each connect in progress uses one thread, which ends when the connect does (bounded by `connect_timeout`; mysql2
    uses 120 s when it is not set).
  - If the reactor stops during a connect, the waiting fiber is not resumed in a later reactor, and the client is closed.
    If the waiting fiber is unwound before the connect finishes, the client is closed too.
  - Other errors raised while connecting keep the caller's frames in their backtrace. A connect thread that ends
    without a client raises `ActiveRecord::ConnectionNotEstablished`.
- `FiberedDatabaseConnectionPool#connection` no longer holds the pool monitor around `checkout` (as in Rails, each cache
  key belongs to one fiber). Other fibers can check connections in and out while a new connection is connecting, and
  `checkout_timeout` applies to them.

### Notes
- Any fiber other than the root fiber on the reactor thread now yields while a connection connects, including fibers not
  driven by EventMachine (for example an `Enumerator`'s). The connection's first queries already yielded the same way.
- `Timeout.timeout` around a connect is not supported under the reactor: the timeout fires while the fiber is waiting
  and the exception escapes the reactor instead of reaching the caller (as it already did for queries). Use an
  EventMachine timer instead.
- Rails 7.1's `reconnect!` waits between attempts with `Kernel#sleep` (`backoff`). That blocks the reactor unless the app
  routes `sleep` on the reactor to a fiber-aware sleep (for example exceptional_synchrony's
  `Kernel.em_synchrony_sleep_hook` set to `EM::Synchrony.sleep`).

## [0.4.0] - 2025-08-21
### Added
- Support for Rails 7.1.

### Removed
- Removed support for Rails 6.
- Removed usage of EventMachine::Synchrony ActiveRecord Mysql adapter. This adapter code was extremely old and we were overriding their patches back to the current ActiveRecord version.

## [0.3.1] - 2024-10-30
### Fixed
- Fixed bug in FiberedMysqlAdapter.new_client that was causing `uninitialized constant` errors.

## [0.3.0] - 2024-10-23
### Added
- Support for Rails 7.0.

### Removed
- Removed support for Rails 6.0 and Rails 5.

### Changed
- Clean up FiberedMysql2ConnectionFactory#fibered_mysql2_connection to better match Mysql2Adapter behavior.
- Change FiberedMysql2::FiberedDatabaseConnectionPool#initialize to match ActiveRecord::ConnectionAdapters::ConnectionPool#initialize arguments.

## [0.2.1] - 2024-08-19
### Fixed
- Fixed bugs in Rails 6.1

## [0.2.0] - 2023-01-12
### Added
- Added support for Rails 6+ by adding knowledge of lazy transactions to the adapter.

## [0.1.5] - 2022-03-25
### Changed
- Upgraded Bundler to 2.2.29 and Ruby to 2.7.5. Removed support for Rails 4.
- Modified FiberedMysql2::FiberedConditionVariable class to ensure compatibility with newer Ruby versions.

## [0.1.4] - 2021-06-25
### Fixed
- Disable the ConnectionPool::Reaper in Rails 5 and 6 as it was in 4. This is important since it is
threaded, not fibered.

## [0.1.3] - 2021-06-17
### Fixed
- When checking that @owner is a Fiber, allow nil.

## [0.1.2] - 2021-06-16
### Fixed
- Added checking to be certain that @owner is never overwritten with a non-Fiber by another mixin.

## [0.1.1] - 2021-02-12
### Fixed
- Fixed bug with Rails 5+ adapter where connections that have `steal!` called on them were not having their owner updated to the current Fiber, which would then cause an exception when trying to expire the connection (this showed up with the Rails 5 `ConnectionPool::Reaper` that reaps unused connections)

### Changed
- Updated Rails 6 dependency to 6.0.x for now as 6.1+ requires a newer version of the mysql gem (0.5+) that we do not yet support


## [0.1.0] - 2020-10-23
### Added
- Added an adapter for Rails 4, 5, and 6.
- Added appraisals for Rails 4, 5, and 6.
- Added TravisCI unit test pipeline.
- Added coverage reports via Coveralls.

[0.2.0]: https://github.com/Invoca/fibered_mysql2/compare/v0.1.5..v0.2.0
[0.1.5]: https://github.com/Invoca/fibered_mysql2/compare/v0.1.4..v0.1.5
[0.1.4]: https://github.com/Invoca/fibered_mysql2/compare/v0.1.3..v0.1.4
[0.1.3]: https://github.com/Invoca/fibered_mysql2/compare/v0.1.2..v0.1.3
[0.1.2]: https://github.com/Invoca/fibered_mysql2/compare/v0.1.1..v0.1.2
[0.1.1]: https://github.com/Invoca/fibered_mysql2/compare/v0.1.0..v0.1.1
[0.1.0]: https://github.com/Invoca/fibered_mysql2/tree/v0.1.0
