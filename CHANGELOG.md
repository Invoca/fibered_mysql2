# CHANGELOG for `fibered_mysql2`

Inspired by [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

Note: this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - Unreleased
### Changed
- Dropped support for `EM`, `EM::Synchrony` in favor of Ruby 3.2 and `Async`.

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

[1.0.0]: https://github.com/Invoca/fibered_mysql2/compare/v0.2.0..v1.0.0
[0.2.0]: https://github.com/Invoca/fibered_mysql2/compare/v0.1.5..v0.2.0
[0.1.5]: https://github.com/Invoca/fibered_mysql2/compare/v0.1.4..v0.1.5
[0.1.4]: https://github.com/Invoca/fibered_mysql2/compare/v0.1.3..v0.1.4
[0.1.3]: https://github.com/Invoca/fibered_mysql2/compare/v0.1.2..v0.1.3
[0.1.2]: https://github.com/Invoca/fibered_mysql2/compare/v0.1.1..v0.1.2
[0.1.1]: https://github.com/Invoca/fibered_mysql2/compare/v0.1.0..v0.1.1
[0.1.0]: https://github.com/Invoca/fibered_mysql2/tree/v0.1.0
