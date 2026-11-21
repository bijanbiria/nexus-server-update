# server_update.sh

[![check](https://github.com/bijanbiria/nexus-server-update/actions/workflows/check.yml/badge.svg)](https://github.com/bijanbiria/nexus-server-update/actions/workflows/check.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Bash 3.2+](https://img.shields.io/badge/bash-3.2%2B-green)
![Distros](https://img.shields.io/badge/OL%20%7C%20Rocky%20%7C%20Alma%20%7C%20RHEL%20%7C%20Ubuntu%20%7C%20Debian%20%7C%20SLES-informational)

One Bash script that points a Linux server's package repositories at an
internal **Sonatype Nexus** mirror and then installs updates (security-only by
default), safely and with a full report. Built for air-gapped / closed
networks where servers cannot reach the internet but a Nexus proxy can.

- **One script, many distros:** Oracle Linux 7–10, Rocky / Alma 8–10, CentOS 7,
  RHEL, Ubuntu, Debian, SLES (dnf / yum / apt / zypper).
- **Security first:** installs only security updates unless you ask for more;
  per-severity (Critical / Important) where the OS provides the data.
- **Safe by design:** dry-run, plan + confirmation, backups of every repo file,
  automatic rollback when a core OS repo fails, lock against parallel runs,
  survives an SSH drop.
- **Self-healing:** cleans package cache on low disk, offers kernel cleanup and
  LVM extend, auto-disables broken third-party repos, handles GPG key and 404
  problems per repo.
- **Automation-ready:** `-y --batch` mode for Ansible / cron, machine-readable
  `RESULT` line and a JSON result file, clear exit codes.
- **Kernel aware:** detects "new kernel installed but not running" and "GRUB
  default points at an old kernel" (the two things vulnerability scanners
  complain about after patching).
- **Bonus:** reports (optionally upgrades) pip / npm / helm through Nexus and
  flags old Docker images.

> Developer documentation (architecture, every function, how to extend it
> safely): **[DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md)**

---

## Contents

1. [How it works](#how-it-works)
2. [Requirements](#requirements)
3. [Quick start](#quick-start)
4. [Configuration](#configuration)
5. [Nexus repository layout](#nexus-repository-layout)
6. [Options](#options)
7. [Exit codes](#exit-codes)
8. [Logs, backups and results](#logs-backups-and-results)
9. [Running from Ansible / cron](#running-from-ansible--cron)
10. [Modes: nexus vs native](#modes-nexus-vs-native)
11. [Security notes](#security-notes)
12. [FAQ / troubleshooting](#faq--troubleshooting)

---

## How it works

```
preflight (OS) -> disk check -> Nexus check -> repo plan -> confirm (y/N)
  -> apply repo config (backup first) -> refresh metadata (rollback on core failure)
  -> upgrade -> verify (what is still upgradable) -> app packages -> reboot check
```

In **nexus mode** the script:

1. Writes `nexus-os.repo` (yum/dnf) or `nexus-os.list` (apt) with the core OS
   repositories on your Nexus.
2. Walks every existing repo file. Known third-party vendors (Docker, Zabbix,
   PostgreSQL, Nginx, Elastic, …) are re-pointed to the matching Nexus proxy;
   anything that is not mirrored is **disabled in place** (never deleted).
3. Refreshes metadata. A broken third-party repo is disabled automatically; a
   broken **core** repo rolls everything back to the backup.
4. Upgrades inside the same major release (Ubuntu 22.04 stays 22.04, OL9 stays OL9).

In **native mode** (OS not mirrored on your Nexus, or Nexus unreachable) the
existing repositories are left untouched and only the upgrade runs.

## Requirements

- Bash 3.2+, run as root (`sudo`)
- `curl` or `wget`, `awk`, `sed`, GNU coreutils (`stat`, `df`, `sha256sum`, `timeout`)
- One of `dnf`, `yum`, `apt-get`, `zypper`
- A Nexus Repository Manager (3.x) with proxy repositories named as described in
  [Nexus repository layout](#nexus-repository-layout)
- Optional: `grubby` (kernel default fix), LVM tools (`lvextend`), `needs-restarting`,
  `python3` (pip / npm reports), `gpg` (key fingerprints in the report)

## Quick start

```bash
# 1. get the script
curl -O https://raw.githubusercontent.com/bijanbiria/nexus-server-update/main/server_update.sh
curl -O https://raw.githubusercontent.com/bijanbiria/nexus-server-update/main/server_update.conf.example

# 2. tell it where your Nexus is (see Configuration)
sudo install -o root -g root -m 600 server_update.conf.example /etc/server_update.conf
sudo vi /etc/server_update.conf

# 3. look before you leap: test everything, change nothing
sudo bash server_update.sh -n

# 4. run it (shows the plan, asks y/N)
sudo bash server_update.sh
```

Interactive runs without an action flag show a small menu:
*check only / security updates (default) / full update / configure repos only*.

## Configuration

All site-specific values live in **one place**. You have two options:

| Option | When to use |
|---|---|
| **A. `/etc/server_update.conf`** (recommended) | Keep the script identical to upstream; put your values in a root-owned file. Updating the script later never overwrites your settings. |
| **B. Edit the `CONFIGURATION` block** at the top of `server_update.sh` | Single self-contained file (e.g. when you compile it with `shc`). |

`/etc/server_update.conf` is **sourced as root**, so it is only read if it is
owned by root and not group/world writable; otherwise the script prints
`ignoring … must be owned by root…` and uses the built-in values. Use
`SU_CONF=/path/to/file` to point at another file.

A full template is in [`server_update.conf.example`](server_update.conf.example).

### `ZONES` (required)

One line per network zone. Four `|`-separated fields:

```
name | Nexus base for OS repos | Nexus base for 3rd-party repos | Nexus base for pip/npm/helm
```

```bash
ZONES='dmz|http://nexus-dmz.corp.local:8081/repository|http://nexus-dmz.corp.local:8081/repository|
internal|http://nexus.corp.local:8081/repository|http://nexus.corp.local:8081/repository|http://nexus-apps.corp.local:8081/repository'
```

- Each base is the Nexus URL **up to and including `/repository`**.
- Fields 2 and 3 may be the same server (most setups).
- Field 4 may be empty: the pip / npm / helm step is then skipped for that zone.
- Zone names are free text (`[a-z0-9_-]`). With only one zone, just write one line.
- The shipped values use `example.com` and do not resolve; the script warns
  (`ZONES still holds the example Nexus URLs`) until you change them.

**How the zone is chosen on a server** (first match wins):
`--zone NAME` / `ZONE=NAME` → interactive menu → zone saved by the last run in
`/etc/server_update.zone` → auto-detect (`--zone auto` probes every Nexus; if
more than one answers, the script stops with exit 10 and asks for `--zone`).

### `NX_EXTRA_HOSTS`, `OLD_CORE_NAMES`, `OLD_MAP` (optional, migrations only)

Only needed if your servers still have repo files pointing at an **old /
retired Nexus**. Leave them empty otherwise.

```bash
NX_EXTRA_HOSTS="old-nexus1.corp.local:8081 10.0.0.5:8081"

# repos on the old Nexus that were core OS repos -> simply dropped
# (nexus-os.repo / nexus-os.list replaces them)
OLD_CORE_NAMES="OL[0-9]*-baseos OL[0-9]*-appstream Ubuntu-Repository Ubuntu-Security"

# old repo name (glob) | repo on the new Nexus | upstream path(s) to try
OLD_MAP='OL*-[Dd]ocker-[Cc]e|docker-yum|linux/centos/$MAJOR/$ARCH/stable
Ubuntu-Nginx|nginx-apt|packages/ubuntu
Ubuntu-HashiCorp|hashicorp-apt|-'
```

Keep `OLD_MAP` in **single quotes**: `$MAJOR` and `$ARCH` are expanded by the
script, not by the shell.

### Access gate: `PW_SALT`, `PW_HASH` (optional)

A team password asked before anything runs (3 tries, exit 9 on failure).
Ansible / cron pass it in the `SU_PASS` environment variable.

```bash
printf '%s' "MY-SALT:MY-PASSWORD" | sha256sum
# put the salt in PW_SALT and the hex digest in PW_HASH
```

`PW_HASH="REPLACE_ME"` (the default) disables the gate. See
[Security notes](#security-notes) for what this does and does not protect.

### Tunables

Set in the config file, as environment variables, or (some) as options:

| Variable | Default | Meaning |
|---|---|---|
| `MIN_ROOT_MB` / `MIN_VAR_MB` / `MIN_BOOT_MB` / `MIN_TMP_MB` | 2048 / 2048 / 300 / 200 | free space required before upgrading |
| `KEEP_KERNELS` | 2 | newest kernels kept by automatic cleanup (`-y -a`) |
| `TIMEOUT` | 8 | seconds for each Nexus probe |
| `DOCKER_AGE` | 90 | flag running images older than this (days) |
| `NEXUS_OS` / `NEXUS_3P` / `NEXUS_APP` | from zone | override one Nexus base for a single run |

## Nexus repository layout

The script finds repositories **by name** on your Nexus, so create proxy
repositories with these names (or change the names in the script; see the
developer guide, *Recipes*). You only need the ones for the OS / vendors you use.

Most yum proxies are "AIO" style: they proxy the **vendor site root**, and the
script discovers the real path by trying the upstream URL path. E.g. for
OL9 BaseOS it probes `…/oraclelinux-aio/repo/OracleLinux/OL9/baseos/latest/x86_64/repodata/repomd.xml`.

**Core OS repositories**

| Nexus repo name | Format | Proxies |
|---|---|---|
| `oraclelinux-aio` | yum | `https://yum.oracle.com/` (root) |
| `rocky-aio` | yum | `https://dl.rockylinux.org/` (root) |
| `almalinux-aio` | yum | `https://repo.almalinux.org/` (root) |
| `ubuntu-archive` | apt | `http://archive.ubuntu.com/ubuntu/` |
| `ubuntu-security` | apt | `http://security.ubuntu.com/ubuntu/` |
| `debian-archive` | apt | `http://deb.debian.org/debian/` |
| `debian-security` | apt | `http://security.debian.org/debian-security/` |
| `ubuntu-esm-infra-aio`, `ubuntu-esm-apps-aio` | apt | Ubuntu Pro ESM (token configured on Nexus) – optional |

**Third-party repositories (yum)**: `epel-aio`, `docker-yum`, `zabbix-aio-yum`,
`nginx-yum`, `openresty-yum`, `pgdg-yum`, `mariadb-yum`, `elastic-aio-yum`,
`gitlab-yum`, `hashicorp-yum`, `redis-yum`, `nodejs-yum`, `haproxy-yum`,
`timescaledb-yum`.

**Third-party repositories (apt)**: `docker-apt`, `zabbix-aio-apt`, `nginx-apt`,
`pgdg-apt`, `hashicorp-apt`, `timescaledb-apt`, `redis-apt`, `openresty-apt`,
`gitlab-apt`, `haproxy-apt`, `drbd9-apt`, `mariadb-apt`, `nodejs-apt`,
`elastic-aio-apt`.

**App repositories (4th zone field)**

| Nexus repo name | Format | Used for |
|---|---|---|
| `pypi-public` | pypi proxy | `pip` (`…/pypi-public/simple`) |
| `npmjs-public` | npm proxy | `npm -g` |
| `helm-binary` | raw (hosted) | file `helm-latest-version` (e.g. `v3.16.2`) plus `helm-vX.Y.Z-linux-amd64.tar.gz` and its `.sha256sum` |
| `argo-helm`, `istio-helm`, `longhorn-helm`, `metallb-helm`, `rancher-helm`, `thanos-community-helm`, `vso-helm` | helm proxy | chart repositories |

The zone check calls `…/service/rest/v1/status` on each Nexus, so the Nexus REST
status endpoint must be reachable (it is anonymous by default).

## Options

| Option | Env | Description |
|---|---|---|
| `-n`, `--dry-run` | `DRY_RUN=1` | test everything, show the plan, change nothing |
| `-y`, `--yes` | `ASSUME_YES=1` | never ask (Ansible/cron); never prompts even with a tty |
| `--batch` | `BATCH=1` | plain output: no colours, no progress bar |
| `-r`, `--reboot` | `REBOOT=1` | reboot in 1 minute if a new kernel was installed |
| `--no-update` | `DO_UPDATE=0` | only configure repositories |
| `--security` | `LEVEL=security` | security updates only (**default**) |
| `--full` | `LEVEL=full` | all updates |
| `--level L` | `LEVEL=L` | `security` \| `critical` \| `important` \| `full` \| `none` |
| `-e`, `--exclude "a* b*"` | `EXCLUDE=` | packages to skip |
| `-a`, `--auto-fix` | `AUTO_FIX=1` | with `-y`: allow deep cleanup / kernel removal / LVM extend |
| `-f`, `--force` | `FORCE=1` | continue even if disk space is still low |
| `-v`, `--verbose` | `VERBOSE=1` | show full package-manager output |
| `--app-packages` | `APP_UPDATE=1` | point pip/npm/helm at Nexus **and** upgrade them |
| `--no-app` | `NO_APP=1` | skip the pip/npm/helm/docker step |
| `-z`, `--zone NAME` | `ZONE=` | zone name, or `auto` |
| `--check` | `CHECK=1` | read-only post-patch status (kernel, pending security, GRUB) |
| `-h`, `--help` | | help |

`critical` / `important` need per-advisory severity data: Oracle Linux has it,
Rocky/Alma sometimes, Ubuntu/Debian never. Without it the script falls back to
"all security" **and says so** in the report.

Examples:

```bash
sudo bash server_update.sh -n                          # what would happen?
sudo bash server_update.sh --check                     # after a reboot: all good?
sudo bash server_update.sh -y -e "k3s* docker* containerd*"
sudo bash server_update.sh -y --level critical -r --zone internal
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | bad option |
| 2 | OS not supported (no dnf/yum/apt/zypper) |
| 3 | Nexus / repo configuration failed (**rolled back**) |
| 4 | upgrade failed (repos stay configured) |
| 5 | not root |
| 6 | already running (lock held by a live process, or a package manager is busy) |
| 7 | low disk space |
| 8 | cancelled / no confirmation |
| 9 | wrong or missing password |
| 10 | zone unknown or ambiguous (use `--zone`) |

## Logs, backups and results

| Path | Content |
|---|---|
| `/var/log/server_update/<host>_<date>.log` | summary (what you saw on screen) |
| `/var/log/server_update/<host>_<date>_full.log` | full dnf/apt output, every command |
| `/var/log/server_update/<host>_<date>.json` | result of this run |
| `/var/log/server_update/last_result.json` | result of the last run (**missing = the run did not finish**) |
| `/var/backups/server_update/<date>/` | original repo files, pip.conf, npmrc, old helm binary |
| `/etc/server_update.zone` | zone used last time |

The last line of every run is a single `RESULT key=value …` line, for example:

```
RESULT host=web01 ip=10.0.0.7 zone=internal os=ol9 core=4 thirdparty=2 disabled=1 mode=nexus update=ok level=security packages=37 security_pending=0 security_before=12 crit=1 kernel=reboot uptodate=no pending=5 app_outdated=0 reboot_required=yes exit=0
```

`security_before` = security updates found before the run, `security_pending` =
security updates **left** after it.

## Running from Ansible / cron

```yaml
- name: Patch servers (security only)
  ansible.builtin.script: server_update.sh -y --batch --zone internal
  environment:
    SU_PASS: "{{ vault_server_update_password }}"   # only if the gate is on
  register: su
  failed_when: su.rc not in [0]

- name: Read result
  ansible.builtin.slurp:
    src: /var/log/server_update/last_result.json
  register: su_json
```

- Always use `-y` (never prompts) and `--batch` (clean logs).
- `SIGHUP` is ignored: if the SSH connection drops, the upgrade keeps running;
  read `last_result.json` afterwards.
- With `-y`, destructive self-healing (old kernels, logs, LVM extend) is **not**
  done unless you also pass `-a`.

## Modes: nexus vs native

| | nexus mode | native mode |
|---|---|---|
| OS | OL 7–10, Rocky/Alma 8–10, Ubuntu, Debian (CentOS 7 partial) | anything else (RHEL, SLES, …) |
| Repos | rewritten to Nexus (originals disabled, backed up) | untouched |
| Fallback | becomes native automatically if no Nexus answers or core repos are missing on Nexus | — |

## Security notes

- **Repo signatures stay on.** Every generated repo has `gpgcheck=1` / apt
  `signed-by`. Remote GPG keys are fetched *through the same Nexus repo*; their
  fingerprint is printed so you can verify it against the vendor.
- Nexus is often plain HTTP inside the network; package integrity then relies
  entirely on GPG signatures. Prefer HTTPS on Nexus if you can.
- `[trusted=yes]` apt sources are reported as a warning.
- Ubuntu ESM keys are taken only from the signed `ubuntu-pro-client` package,
  never from a raw download.
- `pip` is configured with `trusted-host` for the Nexus host.
- **The password gate is an access control for operators, not a secret store.**
  The salted SHA-256 is visible to anyone who can read the script. Compiling with
  `shc` (`shc -r -f server_update.sh -o server_update`) only hides it from casual
  reading. Use a long random password.
- Never commit your real `/etc/server_update.conf` (internal hostnames, hashes).

## FAQ / troubleshooting

**"core repos for … not found on Nexus – native mode"**
The core repo names or paths on your Nexus do not match. Run with `-n -v` and
look in the full log for the probed URLs.

**A third-party repo got disabled.** The `Notes` section of the summary says
why (`not on Nexus`, `GPG key missing`, `404`). Mirror it on Nexus or import
the key and run again.

**"package conflict … --nobest"** (dnf) Usually an `exclude=` line in
`dnf.conf`/`yum.conf`; the script shows the file. Interactive runs may retry
with `--nobest`; `-y` runs never do.

**"grub default is an OLD kernel"** Run the printed `grubby --set-default …`
command, then reboot. Interactive runs offer to do it.

**Stale lock** A lock whose process is gone is removed automatically, unless a
package manager is still running (exit 6, check by hand).

---

## Contributing and security

Pull requests are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md).
Please report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).
Changes per version: [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE) © 2026 Bijan Biria
