# Changelog

All notable changes to this project. Versions follow `MAJOR.MINOR.PATCH`.

## [3.7.3] - 2026-11-21 (first public release)
### Added
- Site configuration in one CONFIGURATION block, or in a root-owned
  `/etc/server_update.conf` (see `server_update.conf.example`).
- `OLD_CORE_NAMES` / `OLD_MAP` settings for migrating from a retired Nexus.
- Warning when `ZONES` still contains the example URLs.
### Changed
- Newest kernel = newest kernel of the **running flavour** (UEK/RHCK,
  -generic/-fips), ordered by install time on rpm systems.

## [3.7.2]
### Changed
- `security_pending` in RESULT/JSON = security updates left **after** the run;
  new field `security_before`.

## [3.7.1]
### Added
- `--batch` plain output for Ansible; JSON result file
  `/var/log/server_update/last_result.json`.
- Lock file holds the owner pid; stale locks are recovered.
### Changed
- `-y` never prompts, even when a tty exists (`ssh -tt`).
- SIGHUP is ignored so an SSH drop does not kill a running upgrade.
