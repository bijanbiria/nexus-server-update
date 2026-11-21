# server_update.sh – Developer Guide

For people who want to **read, change, extend or contribute to** the script.
User documentation (install, configure, options) is in [README.md](README.md).

Line numbers refer to **v3.7.3 (public)**. They move with every change, so
find a function with:

```bash
grep -n '^function_name()' server_update.sh
```

---

## Contents

1. [Big picture](#1-big-picture)
2. [File map](#2-file-map)
3. [Coding rules (read before editing)](#3-coding-rules-read-before-editing)
4. [Global state](#4-global-state)
5. [Temporary files](#5-temporary-files)
6. [Function reference](#6-function-reference)
   - [6.1 Configuration, options, access gate](#61-configuration-options-access-gate)
   - [6.2 Output and logging](#62-output-and-logging)
   - [6.3 Result, JSON, lock](#63-result-json-lock)
   - [6.4 Generic helpers (HTTP, URL, repo discovery)](#64-generic-helpers-http-url-repo-discovery)
   - [6.5 OS detection](#65-os-detection)
   - [6.6 Mapping tables](#66-mapping-tables)
   - [6.7 Old-Nexus migration](#67-old-nexus-migration)
   - [6.8 YUM / DNF: plan](#68-yum--dnf-plan)
   - [6.9 Disk space and self-healing](#69-disk-space-and-self-healing)
   - [6.10 Kernels and GRUB](#610-kernels-and-grub)
   - [6.11 YUM / DNF: apply, refresh, upgrade](#611-yum--dnf-apply-refresh-upgrade)
   - [6.12 Update level (security / severity)](#612-update-level-security--severity)
   - [6.13 APT: core repos and Ubuntu ESM](#613-apt-core-repos-and-ubuntu-esm)
   - [6.14 APT: rewriting sources](#614-apt-rewriting-sources)
   - [6.15 APT: apply, refresh, upgrade](#615-apt-apply-refresh-upgrade)
   - [6.16 Progress bar](#616-progress-bar)
   - [6.17 Verify](#617-verify)
   - [6.18 Native mode](#618-native-mode)
   - [6.19 Plan view](#619-plan-view)
   - [6.20 App packages (pip / npm / helm / docker)](#620-app-packages-pip--npm--helm--docker)
   - [6.21 Zones](#621-zones)
   - [6.22 Welcome menu and check mode](#622-welcome-menu-and-check-mode)
   - [6.23 main()](#623-main)
7. [Contracts you must not break](#7-contracts-you-must-not-break)
8. [Danger zones](#8-danger-zones)
9. [Recipes (common changes)](#9-recipes-common-changes)
10. [Testing](#10-testing)
11. [Contributing](#11-contributing)
12. [Version history](#12-version-history)

---

## 1. Big picture

The script is one file, top to bottom:

```
config + options + password gate     (runs at load time)
helpers & function definitions       (nothing runs)
main "$@"                            (last line; skipped when NX_SOURCE_ONLY=1)
```

`main()` runs 11 numbered steps. Every step prints `[n/11] Name  STATUS  text`
via `step` + `status`.

```
 1 Preflight (OS)        detect_os, pick package manager, nexus|native mode
   (--check?)            run_check -> exit 0
 2 Disk space            check_disk  (self-healing)            fail -> exit 7
 3 Nexus connectivity    probe zone's Nexus; none -> native mode
 4 Repository plan       build_core_* + build_3p_* (+ handle_esm) -> $TMP files only
   (dry-run?)            -> finish 0
 5 Confirmation          y/N, or -y                            no  -> exit 8
 6 Apply repo config     backup + write files                  fail -> exit 3
 7 Refresh metadata      makecache / apt-get update; broken 3rd-party repos
                         auto-disabled; core failure -> rollback, exit 3
 8 Upgrade packages      level_menu + apply_level + upgrade_*  fail -> exit 4
 9 Verify up-to-date     what is still upgradable, security left
10 App packages          pip / npm / helm / docker
11 Reboot check          needs-restarting, kernel_state, GRUB fix, --reboot
   finish 0              summary + RESULT line + JSON
```

**Key design idea: plan first, change later.** Steps 1–4 only write into
`$TMP`. Nothing under `/etc` changes before step 6, and step 6 always takes a
backup first. Keep it that way.

**Two families, two modes.**

- `FAM` = `yum` (dnf/yum), `apt`, `zypper` – which code path is used.
- `MODE` = `nexus` (repos rewritten) or `native` (repos untouched). zypper is
  always native.

## 2. File map

| Lines | Section | What is there |
|---|---|---|
| 1–47 | header | description, changelog, exit codes |
| 48–89 | **CONFIGURATION** | `ZONES`, `NX_EXTRA_HOSTS`, `OLD_CORE_NAMES`, `OLD_MAP`, `PW_SALT`, `PW_HASH`, `/etc/server_update.conf` loader |
| 90–123 | defaults | all option variables with env-var defaults, interactivity detection |
| 125–200 | `usage`, option parser | `--help` text and `while case` loop |
| 226–233 | non-interactive | `-y` / `--batch` force `INTERACTIVE=0` |
| 236–266 | access gate | `pw_hash`, `check_password` (runs immediately) |
| 268–287 | runtime globals | paths, counters, colours |
| 289–406 | output | `say log note plan off step status run finish` |
| 408–448 | result / lock | `json_esc write_result take_lock` |
| 450–523 | helpers | `http_code probe suffixes url_path find_repo is_nexus lookup` |
| 525–552 | OS | `os_val detect_os` |
| 554–638 | tables | `yum_map yum_generic apt_map old_map is_old_core_name old_remap` |
| 640–716 | YUM plan | `core_yum is_core_yum parse_repo scan_yum` |
| 718–993 | disk / kernels | `disk_* ask clean_* list_kernels … kernel_menu lvm_extend check_disk` |
| 995–1106 | YUM build/apply | `build_core_yum build_3p_yum gpg_keys disable_yum_file apply_yum restore_yum` |
| 1108–1210 | update level | `classify_updates apply_level confirm_full level_menu` |
| 1212–1344 | YUM run | `yum_pm refresh_yum repo_ids_for_name nobest_prompt upgrade_yum reboot_need_yum` |
| 1346–1490 | APT core + ESM | `is_core_apt esm_* handle_esm build_core_apt` |
| 1492–1778 | APT run | `process_list process_sources build_3p_apt apply_apt restore_apt refresh_apt upgrade_apt …` |
| 1780–1827 | progress | `run_progress` |
| 1829–1885 | verify | `verify_uptodate` |
| 1887–1973 | native | `native_plan refresh_native upgrade_native reboot_need_zypper` |
| 1975–1990 | plan view | `dedupe show_plan` |
| 1993–2180 | app packages | `pip_owned app_pip app_npm helm_proxy_for app_helm app_docker app_packages` |
| 2182–2291 | zones | `tcp_ok zone_* url_host detect_zones auto_zone select_zone is_zone_url zone_remap` |
| 2293–2388 | menu / check | `welcome_menu find_last_run ago_text run_check` |
| 2390–2633 | **main** | the 11 steps |
| 2636 | entry | `[ "${NX_SOURCE_ONLY:-0}" = 1 ] \|\| main "$@"` |

## 3. Coding rules (read before editing)

These are not style preferences – breaking them breaks servers.

1. **`set -u` is on.** Every variable must be initialised before use. New
   globals go next to the others (lines 90–123 or 268–287) with a default.
   Use `${VAR:-}` when a variable may legitimately be unset.
2. **`LC_ALL=C`.** All parsing of dnf/apt output assumes English, C-locale
   output. Do not remove it.
3. **Bash 3.2 compatible.** No associative arrays (`declare -A`), no `mapfile`,
   no `${var,,}` / `${var^^}`, no `&>>`. Data is passed in **pipe-separated
   lines** (`a|b|c`) and read with `while IFS='|' read -r …`.
4. **Never `eval` or `source` data from the server.** `/etc/os-release` is read
   with `os_val` (sed + character filter). The only sourced file is the
   root-owned config file, after an ownership/permission check.
5. **Word splitting is deliberate** in a few places (`$EXCLUDE`, `$names`,
   `$BASES_OS`). When splitting a list that may contain globs (`k3s*`), wrap it
   with `set -f … set +f` so the shell does not expand it against the current
   directory.
6. **Screen vs logs.** Use `say` for anything the operator should read (it is
   also written to the summary log), `log` for debug detail (full log only),
   `note` for a line in the final *Notes* list, `run` to execute a command with
   output captured. Do not `echo` directly except for prompts (to `>&2`).
7. **Prompts read from `/dev/tty`**, never from stdin (stdin may be a pipe,
   e.g. `gpg -d script.gpg | bash`). Every prompt must have a non-interactive
   path that does not block (check `INTERACTIVE` and `ASSUME_YES`).
8. **Plan before apply.** Functions called before step 6 write only to `$TMP`.
9. **Note prefixes are a protocol:** `FAIL   `, `WARN   `, `OFF    `, `INFO   `
   (padded to 7 characters). `finish` colours by prefix; step 4 rewrites
   `FAIL` to `WARN` with `sed` when falling back to native mode.
10. **Every exit goes through `finish <code>`** (or `run_check`), which prints the
    summary, writes the JSON and removes `$TMP` and the lock. The only direct
    `exit`s are before the lock exists, or in `auto_zone`/`select_zone` which
    clean up themselves.

## 4. Global state

The script uses globals instead of return values. The important ones:

**Options** (set from env, config file, then command line)

| Variable | Values | Set by |
|---|---|---|
| `DRY_RUN ASSUME_YES BATCH VERBOSE FORCE AUTO_FIX REBOOT` | 0/1 | options |
| `DO_UPDATE` | 1 = upgrade, 0 = repos only | `--no-update`, welcome menu |
| `CHECK` | 1 = read-only report | `--check`, welcome menu |
| `LEVEL` | `security critical important full none` or empty | `--level`, menus |
| `ACTION_SET` | 1 if an action flag was given (skips welcome menu) | parser |
| `EXCLUDE` | space separated globs | `-e` |
| `APP_UPDATE NO_APP` | 0/1 | `--app-packages`, `--no-app` |
| `INTERACTIVE` | 1 if `/dev/tty` usable and not `-y`/`--batch` | load time |
| `TTY` | 1 if stdout is a terminal (colours, progress bar) | load time |

**Environment of this server**

| Variable | Example | Set by |
|---|---|---|
| `OS_ID OS_VER OS_CODE MAJOR ARCH` | `ol 9.4 "" 9 x86_64` | `detect_os` |
| `KEY` | `ol9`, `rocky9`, `ubuntu`, `sles15`, `unknown` | `detect_os` |
| `PKGMGR` | `dnf yum apt zypper` | main step 1 |
| `FAM` | `yum apt zypper` | main step 1 |
| `MODE` | `nexus native` | main steps 1, 3, 4 |
| `HOST IP TS` | | load time |

**Nexus / zone**

| Variable | Meaning |
|---|---|
| `ZONE ZONE_SRC` | chosen zone and how (`flag user saved auto`) |
| `NEXUS_OS NEXUS_3P` | bases of this zone (fields 2, 3) |
| `APP_NX` | base for pip/npm/helm (field 4) |
| `BASES_OS BASES_3P` | the bases that actually answered (step 3) – **use these in probes** |
| `NX_ALL_HOSTS` / `NX_HOSTS` | every Nexus host of every zone + `NX_EXTRA_HOSTS` (recognises "this URL is a Nexus") |
| `ZONE_HOSTS` | hosts of the current zone only |

**Counters and results** (end up in the summary and `RESULT` line)

`N_CORE N_3P N_OFF N_REPL N_DUP N_NAT` – repo counts;
`UPD` (`ok failed skipped cancelled dry-run`); `PKG` packages changed;
`SEV_CRIT SEV_IMP SEV_MOD SEV_LOW SEV_SEC SEV_OTHER SEV_GRADED` – before;
`SEC_AFTER PEND UTD` – after; `KSTATE RUN_K NEW_K DEF_K` – kernel;
`RBR` reboot required; `APP_OUT APP_TXT`; `UPG_SKIPPED NAT_FAIL`.

## 5. Temporary files

All in `$TMP` (`mktemp -d /tmp/server_update.XXXXXX`), removed by `finish`.

| File | Written by | Content |
|---|---|---|
| `report` (`$REPORT`) | `note`, `off` | notes shown at the end and in JSON |
| `used` (`$USED`) | build_* | every Nexus URL already used (duplicate detection) |
| `plan` | `plan` | `type\|name\|target` lines for `show_plan` |
| `sections` | `scan_yum` | parsed yum sections `file\|id\|enabled\|url\|gpgkey\|module_hotfixes` |
| `core` | `build_core_yum` | output of `core_yum` |
| `nexus-os.repo nexus-3p.repo` | build_*_yum | files to install in step 6 |
| `keys/` | `gpg_keys` | GPG keys fetched through Nexus |
| `nexus-os.list nexus-esm.list` | build_core_apt, handle_esm | apt sources to install |
| `apt/<n>` + `apt.map` | `build_3p_apt` | rewritten copy of each apt source file + `original\|copy` map |
| `kept` | process_* | `uri suite` already kept (duplicate detection) |
| `esmkeys/ esm_off pro/` | ESM | keys, old ESM sources to disable, extracted pro-client |
| `disk` | `disk_measure` | `mount\|avail_MB\|need_MB\|use%\|device` |
| `prog.out prog.st` | `run_progress` | command output and apt status-fd |
| `upg.out yumout aptupd apterr` | refresh/upgrade | copies of outputs for error parsing |
| `pk0 pk1` | main step 8 | package lists before/after (to count `PKG`) |
| `pending chk` | `verify_uptodate` | still-upgradable list |

## 6. Function reference

Format: **`name args`** (line) – what it does. *Edit notes* say what is safe to
change and what is not.

### 6.1 Configuration, options, access gate

**CONFIGURATION block** (48–89) – the only place with site data. Loads
`$SU_CONF` (default `/etc/server_update.conf`) if it is owned by uid 0 and has
no group/world write bit (`find -perm /022`).
*Edit notes:* add new site settings here **and** to `server_update.conf.example`
and README. Never weaken the ownership check – the file is sourced as root.

**`usage`** (125) – the `--help` text (heredoc, not quoted, so `$VERSION`,
`$MIN_ROOT_MB` … are expanded). *Edit:* keep it in sync with the parser and README.

**option parser** (202–224) – `while [ $# -gt 0 ]; case "$1"`. Options with a
value do `shift; VAR="${1:-}"`. Action options set `ACTION_SET=1`.
*Edit:* to add an option, add a `case` line, a default in the defaults block,
a line in `usage`, and (if it changes behaviour) a field in the `RESULT` line.

**`pw_hash pw`** (244) – `sha256("$PW_SALT:$pw")`.

**`check_password`** (246) – runs at load time, before anything else.
`PW_HASH=REPLACE_ME` → gate off. Else uses `$SU_PASS` (and unsets it) or asks up
to 3 times with echo off; exit 9 on failure.
*Edit notes:* keep `unset SU_PASS` and `stty echo` restore. Keep it before
`main`, so even `--dry-run` is protected.

### 6.2 Output and logging

| Function | Purpose |
|---|---|
| **`say text`** (291) | print to screen + summary log (ANSI colours stripped) |
| **`log text`** (293) | timestamped line in full log; with `-v` also on stderr. Masks `user:pass@` in URLs |
| **`note text`** (295) | add a line to the final Notes (`$REPORT`) + log. Start text with a 7-char prefix (`FAIL   ` …) |
| **`plan type name target`** (296) | add a line to the plan view. Types: `core 3p keep fix repl dup off use` |
| **`off id reason`** (297) | a repo that will be disabled: plan + note + `N_OFF++` |
| **`step name`** (299) | start a numbered step (`STEP++`), prints without newline |
| **`status OK\|WARN\|FAIL\|SKIP text`** (304) | end of the step line, coloured; also to summary |
| **`run cmd…`** (313) | run a command, output to full log (and screen with `-v`); returns its exit code |
| **`finish rc`** (319) | prints the summary block, the Notes, the `RESULT` line, writes JSON, cleans up, `exit rc` |

*Edit notes for `finish`:* add new summary lines freely, but **append** new
`key=value` pairs to the `RESULT` line, never rename or remove existing keys
(Ansible playbooks parse them). Values must not contain spaces.

### 6.3 Result, JSON, lock

**`json_esc s`** (411) – escapes `\ " TAB CR` for JSON.

**`write_result "k=v k=v…"`** (412) – turns the `RESULT` pairs into JSON
(numbers stay numbers), adds `version ts summary_log full_log backup notes[]`,
writes `<log>.json` and `last_result.json` (mode 640). Called by `finish` and
`run_check`. `last_result.json` is deleted at the start of `main`, so a missing
file means the run died before `finish`.

**`take_lock`** (433) – `mkdir $LOCK` (atomic). The dir holds `pid`. If the
owner pid is dead and no `dnf yum apt dpkg zypper rpm unattended-upgr` is
running, the stale lock is removed; otherwise exit 6.
*Edit notes:* do not replace `mkdir` with a file test (race). If you add a new
package-manager process name, add it to the `ps` regex.

### 6.4 Generic helpers (HTTP, URL, repo discovery)

**`http_code url`** (451) – HTTP status via curl (or wget: 200/000), always
`--noproxy '*'` and `-m $TIMEOUT`. `000` = no connection.

**`probe url yum|apt [suite]`** (460) – is there a repository at `url`?
yum: `url/repodata/repomd.xml` = 200. apt: `url/dists/<suite>/InRelease` or
`Release` = 200.

**`suffixes path`** (470) – `a/b/c` → `a/b/c`, `b/c`, `c` (longest first).

**`url_path url`** (479) – path part of a URL with `$releasever`,
`$releasever_major`, `$basearch`, `$arch` replaced by `$MAJOR` / `$ARCH`; other
`$vars` removed; query string and trailing `/` removed.

**`find_repo kind "names" "path" "bases" strict [suite]`** (490) – **the core
discovery algorithm.** For each Nexus repo *name*, each *base*, each *suffix*
of the upstream *path*: `probe base/name/suffix`. First hit is echoed. If
`strict=0` it also accepts the repo root `base/name`.

Example – upstream `https://download.docker.com/linux/centos/9/x86_64/stable`,
name `docker-yum`, strict 1 → tries
`…/docker-yum/linux/centos/9/x86_64/stable`, then `…/docker-yum/centos/9/x86_64/stable`,
`…/docker-yum/9/x86_64/stable`, … until `repomd.xml` answers.

*Edit notes:* this does many HTTP requests (names × bases × suffixes); keep
name lists short. `strict=1` is required for versioned products where the repo
root also contains (wrong) metadata.

**`is_nexus url`** (507) – does the URL contain any host from `$NX_HOSTS`?

**`lookup table-function url`** (510) – reads a table (`yum_map`, `apt_map`,
`yum_generic`), finds the **first** line whose pattern is a substring/glob of the
URL and whose OS list contains `$KEY` (or `*`). Sets `L_CANDS` (Nexus names),
`L_STRICT`, `L_PATH` (optional explicit path, `$MAJOR`/`$ARCH` expanded).

### 6.5 OS detection

**`os_val KEY`** (527) – value from `/etc/os-release`, quotes removed, only
`A-Za-z0-9._-` kept (no injection).

**`detect_os`** (528) – sets `OS_ID OS_VER OS_CODE MAJOR ARCH KEY`. Falls back to
`/etc/SuSE-release`, `centos-release`, `oracle-release`, `redhat-release`.
*Edit:* to support a new distro family, add its `ID` to the `case` that builds
`KEY` (see Recipe 9.4).

### 6.6 Mapping tables

Tables are functions that `cat` a **quoted** heredoc (`<<'EOF'`), so `$MAJOR`
stays literal and is expanded later by `lookup`. One rule per line,
`|`-separated. **Order matters – first match wins.**

**`yum_map`** (559) – `pattern | os keys | nexus names | strict | [path]`.
`-` as names = "internet-only, disable" (e.g. `openh264`, `epel-next`).
The optional 5th field gives the path for `mirrorlist=`/`metalink=` repos that
have no usable URL path (EPEL).

**`yum_generic`** (581) – vendor repos checked *after* the core test (any other
Oracle Linux repo → `oraclelinux-aio`).

**`apt_map`** (586) – `pattern | os keys | nexus names | strict`. Several names
are tried in order (ESM).

*Edit notes:* put more specific patterns **above** general ones (`epel*next`
must stay above `fedoraproject.org*epel`). Never use `|` inside a field.

### 6.7 Old-Nexus migration

Only used when a repo file points at a host in `NX_EXTRA_HOSTS`.

**`old_map`** (609) – prints `$OLD_MAP` (leading blanks stripped).
Format `pattern|new-repo|path1 path2…` (`-` = repo root).

**`is_old_core_name name`** (613) – does `name` match a glob in `$OLD_CORE_NAMES`?
Such repos are dropped because `nexus-os.*` replaces them. Uses `set -f`.

**`old_remap url kind [suite]`** (624) – repo name from the URL → first
matching `OLD_MAP` rule → `find_repo` on the new Nexus with each listed path
(strict), or the repo root for `-`. Echoes the new URL or returns 1.

### 6.8 YUM / DNF: plan

**`core_yum`** (642) – prints the core repos for this OS:
`id | nexus names | upstream path | gpg key file | required | enabled`.
OL7 `latest/optional/addons`; OL8–10 `baseos/appstream/addons`; Rocky/Alma
`BaseOS/AppStream/extras/CRB(PowerTools on 8)`; plus the UEK repo matching the
installed `kernel-uek` version (4.14→UEKR5, 5.4→R6, 5.15→R7, 6.12→R8).
CRB is enabled only if it was enabled before (`CRB_ON`).
*Edit:* new UEK release → add a line to the `case "$KEY:$uek"`. A repo with
`required=1` that is not found makes the whole plan fail → native mode.

**`is_core_yum url`** (680) – is this an original vendor core URL? (those are
replaced by `nexus-os.repo`, so the 3rd-party pass skips them).

**`parse_repo file`** (693) – awk parser for `.repo` files →
`file|id|enabled|url|gpgkey|module_hotfixes` per section (baseurl first, else
mirrorlist/metalink). Handles CRLF.

**`scan_yum`** (707) – parses every `/etc/yum.repos.d/*.repo` except our own
into `$TMP/sections`, sets `CRB_ON`.

### 6.9 Disk space and self-healing

**`disk_measure`** (720) – `df` for `/ /var /boot /tmp` (deduplicated by mount
point) → `$TMP/disk`, `DISK_TXT`. With `--no-update` the minimums are lowered.

**`disk_low`** / **`disk_full`** (737/738) – mounts below minimum / ≥ 90 % used.
**`fmt_mb n`** (739) – `2048` → `2G`.

**`ask question`** (742) – the yes/no for *risky self-healing*. Dry-run → no.
`-y` → yes only with `--auto-fix`. Non-interactive → no.
*Edit notes:* use `ask` for every new destructive action; do not read
`/dev/tty` directly.

**`clean_cache`** (758) – `dnf/yum clean all`, `zypper clean`, `apt-get clean`. Safe.

**`clean_deep`** (768) – `kernel_menu`; on apt `autoremove --purge` while
**protecting** remaining kernels (marked manual, then back to auto); deletes
rotated logs > 7 days **except** audit/secure/auth and our own logs; journal
vacuum to 200 MB.
*Danger:* keep the exclusions in the `find … -delete` line – audit logs are a
compliance requirement on most servers.

**`lvm_extend mount need avail device`** (919) – finds the LV of the mount, checks
VG free space, asks, `lvextend -r` by (missing + 2 GB) capped at VG free.

**`check_disk`** (937) – step 2: inode check (fails < 5000 free) → if OK and
> 90 % used, cleans cache → if low: clean cache, ask deep cleanup, try LVM
extend → still low: notes with hints, return 1 (exit 7) unless `--force`.

### 6.10 Kernels and GRUB

**`list_kernels`** (791) – installed kernels, **oldest first**, in `uname -r`
format. rpm: by **install time** (`rpm -q --last`), because `sort -V` orders
`5.2.el9uek` vs `5.el9uek` wrongly. apt: `sort -V`.

**`default_kernel`** (800) – `grubby --default-kernel` or `/boot/vmlinuz` link.

**`newest_installed_kernel`** (810) – newest kernel **of the same flavour** as the
running one (UEK vs RHCK; `-generic` vs `-fips` etc.). Never suggests a flavour
switch.

**`kernel_state`** (826) – sets `KSTATE`: `ok` (running = newest), `reboot`
(newest is the GRUB default, just reboot), `grub` (newest installed but default
points elsewhere). Also `RUN_K NEW_K DEF_K KMSG`.

**`fix_grub_default`** (842) – `grubby --set-default /boot/vmlinuz-$NEW_K`.

**`kernel_pkgs version`** (854) – all packages of one kernel version
(kernel, -core, -modules*, -devel / linux-*-<ver>).

**`kernel_menu`** (864) – lists kernels with size and flags; interactive: user
picks numbers; the running and default kernels can never be removed; warns if
fewer than 2 remain. `-y -a`: removes all except running, default and the newest
`KEEP_KERNELS`. rpm removal uses `--disablerepo='*'`.
*Danger:* the running/default protection is what keeps the server bootable.
Do not remove it.

### 6.11 YUM / DNF: apply, refresh, upgrade

**`build_core_yum`** (995) – for each `core_yum` line → `find_repo` on `BASES_OS`
→ writes `[nx-<id>]` sections (`gpgcheck=1`, `proxy=_none_`) to
`$TMP/nexus-os.repo`. Missing required repo → return 1.

**`build_3p_yum`** (1015) – for each **enabled** section in `$TMP/sections`, in this
order:
1. already a Nexus URL → if another zone/old Nexus: `zone_remap` or `old_remap`;
   probe it; old core names are dropped;
2. `yum_map` says `-` → disable (internet only);
3. `yum_map` match → `find_repo` on `BASES_3P`;
4. vendor core URL → skip (handled by core);
5. `yum_generic` match → `find_repo`;
6. anything else → disable.
Duplicates (same Nexus URL twice) are skipped. Output `$TMP/nexus-3p.repo`.

**`gpg_keys id "keys" hit`** (1058) – keeps `file://` keys; remote keys are fetched
through the same Nexus repo (trying URL suffixes), saved to `$TMP/keys`,
fingerprint added to the notes.

**`disable_yum_file file`** (1082) – inserts `enabled=0` after every section
header and drops existing `enabled=` lines. Writes with `cat > file` to keep
owner, mode and SELinux context.

**`apply_yum`** (1088) – backup `/etc/yum.repos.d` → disable all other repo files →
install `nexus-os.repo`, keys, `nexus-3p.repo` (removed if empty).

**`restore_yum`** (1102) – deletes all `.repo` files and copies the backup back.

**`yum_pm`** (1213) – `dnf` if present, else `yum`.

**`refresh_yum`** (1215) – `makecache` up to 6 times. Failing repo ids are parsed
from the output; if it is in `nexus-3p.repo` → disabled and retried; if it is a
core repo (or unknown) → **rollback** (`restore_yum`), return 1 (exit 3).

**`repo_ids_for_name nexus-repo`** (1247) – section ids whose baseurl lives in
that Nexus repo (maps a 404 URL back to a repo id).

**`nobest_prompt`** (1254) – on a dependency conflict shows the packages and the
`exclude=` line that usually causes it; asks whether to retry with `--nobest`.
Always "no" when non-interactive.

**`upgrade_yum`** (1280) – `dnf -y $YUM_OPTS $SEC_OPT upgrade $EX` in a retry loop
(max 4): dependency conflict → `nobest_prompt`; `Public key … not installed` or
404 in a **3rd-party** repo → `--disablerepo=<id> --skip-broken` and retry (noted
in `UPG_SKIPPED`); same problem in a **core** repo → stop with failure.

**`reboot_need_yum`** (1336) – `needs-restarting -r` (exit 1 = reboot), else
compares newest `/boot/vmlinuz-*` with `uname -r`.

### 6.12 Update level (security / severity)

**`classify_updates`** (1115) – counts updates **before** upgrading. yum:
`updateinfo summary` (Critical/Important/Moderate/Low) and
`--security check-update`; `SEV_GRADED=1` if any severity exists. apt: counts
`Inst` lines of `apt-get -s upgrade` from `-security`/ESM origins. Runs once
(`LEVEL_OK`).

**`apply_level`** (1145) – `LEVEL` → `SEC_OPT`, `SEC_MODE`, `LVL_TXT`.
yum: `--security` [+ `--sec-severity=…`]; without severity data critical/important
fall back to `--security` (and say so). apt: `SEC_OPT=__APT_SECURITY__` (a marker
handled in `upgrade_apt`). `full` → no option; `none` → skip.

**`confirm_full`** (1168) – extra warning before a full upgrade (interactive only).

**`level_menu`** (1181) – prints the counts; interactive: menu (5 choices with
severity data, 3 without); non-interactive: `LEVEL` stays as given or becomes
`security`.

### 6.13 APT: core repos and Ubuntu ESM

**`is_core_apt uri suite`** (1347) – official Ubuntu/Debian mirrors, or a local
mirror with path `ubuntu`/`debian`/`debian-security` and the server's codename.

**`ESM_REPO`, `ESM_BRANCHES`** (1372–1374) – ESM layout on Nexus:
`branch-path | suite suffixes | keyring name | key file in ubuntu-pro-client`.

**`esm_base`** (1376) – first base where `$ESM_REPO/` answers 200.

**`esm_get_key keyfile`** (1388) – ESM signing key: already in
`/usr/share/keyrings` → use it; else `apt-get download ubuntu-pro-client` (hash
verified by apt) and extract the keyring. Never downloads a raw key file.

**`handle_esm`** (1412) – Ubuntu only. Builds `$TMP/nexus-esm.list` for each
branch/suite that answers, with `signed-by`. Existing token-based `esm.ubuntu.com`
sources are queued for disabling (`$TMP/esm_off`).

**`build_core_apt`** (1460) – `ubuntu-archive`/`debian-archive` for `<codename>`,
`-updates`, `-backports`, and `ubuntu-security`/`debian-security` for
`<codename>-security` → `$TMP/nexus-os.list` with `signed-by` when the keyring
exists. Missing main → return 1 (native mode). Missing security → loud warning.

**`is_core_nexus url`** (1492) – Nexus URL whose repo name is a core name
(`CORE_NAMES`) or matches `OLD_CORE_NAMES`.

### 6.14 APT: rewriting sources

**`process_list file`** (1495) – rewrites one-line `.list` sources to stdout, line
by line. For each `deb`/`deb-src` line (options `[…]` preserved):
1. Nexus core URL already covered → commented out (`replaced by nexus-os.list`);
2. Nexus of another zone / old Nexus → remapped, or disabled;
3. wrong release (`suite_bad`: a known codename ≠ this server's) → re-pointed to
   the right codename if Nexus has it, else disabled;
4. Nexus URL → kept if it probes OK (duplicates disabled);
5. `apt_map` match → `find_repo`, rewritten to Nexus;
6. anything else that is not core → disabled.
Lines are never deleted, only commented with `# disabled by server_update <TS>: `.
Warns about `[trusted=yes]`.

**`process_sources file`** (1556) – same logic for deb822 `.sources` files (one
repo per file); disabling = `Enabled: no`.

**`build_3p_apt`** (1593) – runs `process_*` for `sources.list` and every file in
`sources.list.d` into `$TMP/apt/<n>`; `$TMP/apt.map` maps original → copy.

### 6.15 APT: apply, refresh, upgrade

**`apply_apt`** (1608) – backup sources + our apt.conf snippet → write every
rewritten copy over its original (`cat >`, keeps permissions) → install ESM keys,
disable old ESM sources → install `nexus-os.list` (+ `nexus-esm.list`) → write
`/etc/apt/apt.conf.d/99server-update-nexus` (`Proxy::<host> "DIRECT"` for every
Nexus host).

**`restore_apt`** (1631) – removes **all** of `sources.list.d/*` and the snippet,
copies the backup back.

**`APT_OPTS`** (1639) – phased updates included, 300 s timeout, keep existing
config files (`--force-confdef --force-confold`). `DEBIAN_FRONTEND=noninteractive`.

**`KNOWN_CODES`, `suite_bad suite`** (1642/1643) – codenames the script knows.
A suite whose first part is a known codename different from `$OS_CODE` is "bad".
*Edit:* **add new Ubuntu/Debian codenames here** when they are released,
otherwise wrong-release sources are not detected.

**`is_core_url url`** (1644) – URL starts with one of the core URLs in `$USED`.

**`apt_reason url`** (1647) – short human reason for a failing source
(`NO_PUBKEY`, the line after `Err:`, or the `E:` line).

**`disable_apt_url url`** (1656) – comments out every source line (or sets
`Enabled: no`) whose URI is a prefix of `url`. Never touches `nexus-os.list`.

**`refresh_apt`** (1684) – `apt-get update` up to 6 times; failing 3rd-party
URLs are disabled and retried; an `E:` on a core URL → **rollback**, return 1.
Only `W:` warnings → OK with a note.

**`apt_security_pkgs`** (1724) – packages whose `dist-upgrade -s` candidate comes
from a `-security` or ESM origin.

**`upgrade_apt`** (1734) – `--exclude` packages are temporarily `apt-mark hold`
(only those not already held, and unheld afterwards). Security mode: `install
--only-upgrade <security packages>` (or a no-op simulation if none). Full mode:
`dist-upgrade` (stays inside the release). Retries up to 3× disabling 3rd-party
sources that 404; a core 404 stops.

**`reboot_need_apt`** (1773) – `/var/run/reboot-required`.

**`pkg_list`** (1775) – sorted installed package list (to count changes).

### 6.16 Progress bar

**`run_progress apt|yum|spin cmd…`** (1783) – runs the command in the background,
output → `$TMP/prog.out`, fd 3 → `$TMP/prog.st`. Every second draws a bar:
apt from `APT::Status-Fd=3` (`dlstatus`/`pmstatus`), yum from `n/N` counters,
`spin` = spinner only. Without a TTY it just waits. Appends output to the full
log, returns the command's exit code.
*Edit notes:* callers read `$TMP/prog.out` afterwards – copy it before calling
`run_progress` again (it is truncated at start).

### 6.17 Verify

**`verify_uptodate`** (1831) – after the upgrade: zypper `list-updates`, apt
`update` + `apt list --upgradable`, yum `check-update` (exit 100 = updates,
1 = error). Fills `$TMP/pending`, `PEND`, `SEC_AFTER` (security updates **left**),
`UTD` (`yes no partial`). Shows up to 15 pending packages.

### 6.18 Native mode

**`native_plan`** (1892) – lists the enabled existing repos (yum sections, apt
lines and `.sources`, `zypper lr`) into the plan (first 12).

**`refresh_native`** (1920) – metadata refresh with short timeouts
(`skip_if_unavailable`); unreachable repos are collected in `NAT_FAIL` and
reported, never fatal.

**`upgrade_native`** (1944) – yum `update --skip-broken $SEC_OPT`, apt →
`upgrade_apt`, zypper `update` with temporary `addlock` for excludes (exit 103 =
zypper updated itself → run again; 100–106 informational; 102 = reboot).

**`reboot_need_zypper`** (1965) – `zypper needs-rebooting`, else kernel compare.

### 6.19 Plan view

**`dedupe`** (1977) – identical lines → `count|line`, first-seen order.

**`show_plan`** (1979) – prints `$TMP/plan` coloured by type and the "then: …"
line.

### 6.20 App packages (pip / npm / helm / docker)

Uses `APP_NX` (zone field 4). **Default is report-only**; `--app-packages`
configures and upgrades.

**`pip_owned python`** (2001) – names of packages whose `INSTALLER` is `pip`/`uv`
(so distro-owned packages are never upgraded by pip).

**`app_pip`** (2022) – with `--app-packages` writes `/etc/pip.conf` (backup first).
Lists outdated pip-owned packages via `$APP_NX/pypi-public/simple`; upgrades
them (adds `--break-system-packages` on PEP 668 systems).

**`app_npm`** (2064) – global registry → `$APP_NX/npmjs-public/`; `npm outdated -g`;
upgrades to `@latest`.

**`helm_proxy_for url`** (2096) – chart repo URL → Nexus helm proxy name.

**`app_helm`** (2105) – re-points known chart repos; compares `helm version` with
`$APP_NX/helm-binary/helm-latest-version`; upgrade only after `sha256sum -c`
passes; old binary saved in the backup dir. Also prints kubectl/trivy versions.

**`app_docker`** (2147) – report only: running images older than `DOCKER_AGE`
days. Never restarts docker.

**`app_packages`** (2163) – step 10 wrapper: skips if `--no-app`, no app Nexus,
Nexus not reachable (`/service/rest/v1/status`), or none of the tools exist.

### 6.21 Zones

**`tcp_ok host port`** (2184) – `/dev/tcp` connect with `timeout`.
**`zone_names`** / **`zone_field zone n`** / **`url_host url`** (2191–2193) – read `ZONES`.

**`zone_reachable zone`** (2196) – TCP connect **and** Nexus status API = 200
(firewalls that accept TCP but drop traffic are not enough).

**`detect_zones`** (2208) / **`auto_zone`** (2217) – probe all zones; exactly one
→ use it; none → `none` (native mode); several → exit 10.

**`select_zone`** (2226) – order: `--zone`/`ZONE` (incl. `auto`) → interactive
menu (shows saved zone, last run hint) → saved `/etc/server_update.zone`
(non-interactive) → auto. Validates the name (exit 10), sets
`NEXUS_OS NEXUS_3P`, saves the zone (not in dry-run), builds `NX_ALL_HOSTS`
and `ZONE_HOSTS`.

**`is_zone_url url`** (2282) – URL on the current zone's Nexus?
**`zone_remap url kind [suite]`** (2284) – same repo path on this zone's Nexus.

### 6.22 Welcome menu and check mode

**`welcome_menu`** (2296) – only interactive, no action flag, no `-y`, no `-n`.
Maps 1–4 to `CHECK=1`, `LEVEL=security`, `LEVEL=full`, `DO_UPDATE=0`.

**`find_last_run`** (2321) / **`ago_text`** (2333) – newest successful
non-dry-run summary log of this host → "N min/hours/days ago".

**`run_check`** (2342) – `--check`: kernel state, pending security/other updates,
"action needed" verdict, its own `RESULT` line (`check=1 … need_action=`), JSON,
cleanup, exit 0. Changes nothing (only `apt-get update` metadata).

### 6.23 main()

**`main`** (2390) – root check (exit 5) → `take_lock` → `$TMP` → traps (INT/TERM
clean up and exit 130; **HUP ignored** so an SSH drop does not kill dnf/apt) →
log dir → `select_zone` → banner → `welcome_menu` → steps 1–11 (see
[Big picture](#1-big-picture)).

Mode switches inside main:
- step 1: `KEY` not in the nexus list → native;
- step 3: zone `none` or no Nexus answers → native;
- step 4: core plan failed → native, counters reset, `FAIL` notes turned into
  `WARN`;
- native mode uses short timeouts (`YUM_OPTS`/`APT_OPTS` overwritten).

## 7. Contracts you must not break

External tools (Ansible, monitoring, people) depend on these:

| Contract | Where | Rule |
|---|---|---|
| Exit codes 0–10 | header, `usage`, `finish` calls | never reuse a code for another meaning; add new codes at the end |
| `RESULT` line keys | `finish`, `run_check` | append only; no spaces in values |
| JSON files and fields | `write_result` | same as RESULT; `last_result.json` deleted at start |
| Log / backup paths | 268–280 | `/var/log/server_update`, `/var/backups/server_update` |
| Generated file names | apply_* | `nexus-os.repo`, `nexus-3p.repo`, `nexus-os.list`, `nexus-esm.list`, `99server-update-nexus`, section ids `nx-<id>` – the script recognises its own files by these names on the next run |
| Comment markers | process_*, disable_* | `# disabled by server_update`, `# replaced by nexus-os.list` |
| Env-var names | defaults block | `DRY_RUN ASSUME_YES … SU_PASS ZONE LEVEL` |
| `NX_SOURCE_ONLY=1` | last line | sourcing for tests must not run `main` |

## 8. Danger zones

Changes here can make servers unbootable, unpatchable or silently insecure.
Get a second review and test on throw-away VMs.

| Area | Risk |
|---|---|
| `restore_yum` / `restore_apt` | they **delete** all repo files before copying the backup back. A wrong `$BAK_DIR` means no repos at all |
| `apply_*` order | backup must succeed **before** any file changes (`\|\| return 1`) |
| `kernel_menu`, `kernel_pkgs`, `clean_deep` | can remove the running/only kernel if protections are weakened; `kernel_pkgs` regex too wide = removes unrelated packages |
| `find … -delete` in `clean_deep` | exclusions protect audit/auth logs and our own logs |
| `lvm_extend` | resizes filesystems (`lvextend -r`) |
| `gpgcheck=1`, `signed-by`, `esm_get_key` | never set `gpgcheck=0` or `[trusted=yes]` to "make it work" |
| `check_password` and the config-file ownership check | security boundary |
| `refresh_*` core vs 3rd-party decision | a core repo misclassified as 3rd-party gets disabled instead of rolling back → server without OS updates |
| `upgrade_apt` hold/unhold | must only unhold what it held |
| `trap '' HUP` | removing it lets an SSH drop kill dnf/apt mid-transaction |
| `LC_ALL=C` | all output parsing depends on English messages |
| `apply_level` / `SEC_OPT` | wrong value = full upgrade when the operator asked for security only |

**Safe to change:** wording of `say`/`note` texts (not the 7-char prefixes),
`usage` text, mapping tables (`yum_map`, `apt_map`, `helm_proxy_for`), adding
`KNOWN_CODES`, UEK lines, default thresholds, new report-only checks.

## 9. Recipes (common changes)

### 9.1 Add a network zone / a new Nexus
Only config: add a line to `ZONES` (README → Configuration). Nothing else.

### 9.2 Your Nexus uses different repository names
Names live in: `core_yum` (`oraclelinux-aio`, `rocky-aio`, `almalinux-aio`),
`build_core_apt` (`ubuntu-archive`, `ubuntu-security`, `debian-archive`,
`debian-security`), `yum_map`, `yum_generic`, `apt_map`, `ESM_REPO`/`ESM_BRANCHES`,
`app_pip` (`pypi-public`), `app_npm` (`npmjs-public`), `app_helm` (`helm-binary`),
`helm_proxy_for`. Several names can be listed space-separated where the field
says "names"; they are tried in order.

### 9.3 Mirror a new third-party vendor
1. Create the proxy repo on Nexus (e.g. `grafana-yum` → `https://rpm.grafana.com`).
2. Add a line to `yum_map` (or `apt_map`), **above** any broader pattern:
   ```
   rpm.grafana.com|*|grafana-yum|1
   ```
3. `sudo bash server_update.sh -n -v` on a server that has the repo and check
   the plan shows `3p grafana …` instead of `off`.

### 9.4 Support a new OS release
- New Ubuntu/Debian codename → add to `KNOWN_CODES`.
- New Oracle/Rocky/Alma major → add the key (`ol11`, `rocky11` …) to the nexus
  list in main step 1 and check paths in `core_yum`.
- New UEK → add `olN:<version>*) r=UEKRx` in `core_yum`.
- New distro family → `detect_os` `KEY`, then either native mode (nothing else
  needed) or a `core_yum` / `build_core_apt` branch.

### 9.5 Add a command-line option
Default in the defaults block → `case` line in the parser → `usage` → README
options table → use it. If automation needs to see it, append a key to the
`RESULT` line.

### 9.6 Add a step
Increase `TOTAL` (11, and the dry-run `TOTAL=5` if the step runs before Apply),
call `step "Name"` then exactly one `status …`. If the step can fail fatally,
`note "FAIL …"` and `finish <code>`.

### 9.7 Add a severity / update level
`level_menu` (menu text and mapping) → `apply_level` (`SEC_OPT`) → `--level`
help text.

## 10. Testing

**Static checks**

```bash
bash -n server_update.sh
shellcheck -s bash server_update.sh      # many SC2086 warnings are intentional (rule 5)
```

**Unit-style tests without running main** – source the functions:

```bash
NX_SOURCE_ONLY=1 . ./server_update.sh
MAJOR=9 ARCH=x86_64
url_path 'https://download.docker.com/linux/centos/$releasever/$basearch/stable'
suffixes linux/centos/9/x86_64/stable
OLD_CORE_NAMES="OL[0-9]*-baseos"; is_old_core_name OL9-baseos && echo yes
```

Stub network functions to test logic offline, e.g.
`find_repo() { echo "find_repo $*"; }`.

**On real (throw-away) servers** – always in this order:

1. `-n -v` (dry-run, read the plan and full log)
2. `--no-update` (repos only; check `dnf repolist` / `apt-get update`)
3. default run (security)
4. reboot, then `--check`

**Test matrix** (minimum before a release): OL8, OL9 (UEK and RHCK), Rocky 9,
Ubuntu 22.04, Ubuntu 24.04 (deb822 sources), Debian 12, plus one native-mode
OS (RHEL or SLES), each with at least one third-party repo, and once with
`-y --batch` from Ansible.

## 11. Contributing

- One topic per pull request; describe what you tested (OS + mode).
- Bump `VERSION` and add a changelog line in the header for behaviour changes.
- Keep [Coding rules](#3-coding-rules-read-before-editing) and
  [Contracts](#7-contracts-you-must-not-break).
- **Never commit real hostnames, IPs, repo names of your organisation, salts or
  hashes.** Site data belongs in `/etc/server_update.conf`. Before pushing:
  ```bash
  grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}|PW_HASH="[0-9a-f]{64}"' server_update.sh
  ```

## 12. Version history

| Version | Change |
|---|---|
| 3.7.3 | newest kernel = newest of the **running flavour** (UEK/RHCK, -generic/-fips), by install time on rpm systems. Public release: all site data moved to the CONFIGURATION block / `/etc/server_update.conf` |
| 3.7.2 | `security_pending` = security updates **left** after the run; new `security_before` |
| 3.7.1 | `--batch`; `-y` never prompts even with a tty (ssh -tt); SIGHUP ignored; lock with pid and stale-lock recovery; JSON result file |
