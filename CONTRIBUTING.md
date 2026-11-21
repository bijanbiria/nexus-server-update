# Contributing

Thanks for helping! This script runs as root on production servers, so
changes are reviewed carefully.

1. Read [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md), especially
   *Coding rules*, *Contracts you must not break* and *Danger zones*.
2. Open an issue first for larger changes, so we can agree on the approach.
3. One topic per pull request. Keep Bash 3.2 compatibility.
4. Run before pushing:
   ```bash
   bash -n server_update.sh
   shellcheck -S error server_update.sh
   ```
5. Test on throw-away VMs: `-n -v`, then `--no-update`, then a normal run,
   then `--check` after reboot. Write the OS versions and mode
   (nexus/native) you tested in the pull request.
6. For behaviour changes bump `VERSION`, update the header changelog and
   `CHANGELOG.md`.
7. **Never commit real hostnames, IP addresses, internal repository names,
   salts or password hashes.** Site data belongs in `/etc/server_update.conf`.
