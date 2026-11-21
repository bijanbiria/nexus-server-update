#!/bin/bash
# =====================================================================
#  server_update.sh  -  Point package repos to internal Nexus & upgrade
#  Nexus  : Oracle Linux 8-10, Rocky 9, CentOS 7 (partial), Ubuntu, Debian
#  Native : any other Linux with dnf / yum / apt / zypper (OL7, RHEL, Rocky 8,
#           SLES 11-15, old Ubuntu/Debian...): own repos kept, just upgraded
#           (bash 3.2+ compatible)
#
#  Author : Bijan Biria
#  Team   : System Admins
#  Version: 3.7.3  (2026-11-17)
#  3.7.3  : newest kernel = newest of the RUNNING flavor (UEK/RHCK, -generic/-fips)
#           by install time on rpm systems (sort -V got 5.el9uek > 5.2.el9uek wrong)
#  3.7.2  : security_pending in RESULT/JSON = security updates LEFT after the
#           run (was: found before). New field security_before.
#  3.7.1  : --batch (plain output for Ansible), -y never prompts even when
#           a tty exists (ssh -tt), SIGHUP ignored (update survives an SSH
#           drop), lock with pid + stale-lock recovery, result also written
#           as JSON: /var/log/server_update/last_result.json
#
#  Usage  : sudo bash server_update.sh [options]      (see --help)
#  Flow   : preflight -> disk check -> Nexus check -> plan
#           -> confirm (y/N) -> apply -> refresh -> upgrade
#           -> verify (apt list --upgradable / dnf check-update) -> reboot check
#  Ansible: run with -y --batch --zone <zone>; read
#           /var/log/server_update/last_result.json (or the last "RESULT" line)
#  Exit   : 0 = OK            1 = bad option     2 = OS not supported
#           3 = Nexus/repo config failed (rolled back)
#           4 = upgrade failed 5 = not root       6 = already running
#           7 = low disk space 8 = cancelled / no confirmation
#           9 = wrong / missing password
#          10 = zone unknown / ambiguous (use --zone)
#
#  Update level (default: security). Only security patches are installed unless
#  --full is given. Per-severity (critical/important) needs updateinfo data,
#  which Oracle Linux has, Rocky/Alma sometimes, Ubuntu/Debian never (there it
#  means "all security"). The script says so in the report, never pretends.
#
#  Notes  : Upgrade stays inside the same major release
#           (Ubuntu 22 stays 22, OL9 stays OL9).
#           Original repo files are disabled in place (not deleted).
# =====================================================================

set -u
export LC_ALL=C
umask 022
VERSION=3.7.3
# =====================================================================
#  CONFIGURATION  -  edit this block, or (better) put the same variables
#  in /etc/server_update.conf (root-owned, not group/world writable) so
#  the script itself stays unchanged. See README.md -> Configuration.
# =====================================================================
# ---- network zones: name | Nexus OS repos | Nexus third-party repos | Nexus app
#      repos (pip / npm / helm; empty = not available in this zone)
# (add a line here for a new zone or a new Nexus; nothing else to change)
# The values below are EXAMPLES (example.com never resolves) - replace them.
ZONES='dmz|http://nexus-dmz.example.com:8081/repository|http://nexus-dmz.example.com:8081/repository|http://nexus-apps-dmz.example.com:8081/repository
internal|http://nexus.example.com:8081/repository|http://nexus.example.com:8081/repository|http://nexus-apps.example.com:8081/repository'
# OLD / retired Nexus servers (host:port, space separated) that may still
# appear in repo files: recognised and moved to the zone's Nexus, never used
# directly. Leave empty if you never had another Nexus.
NX_EXTRA_HOSTS=""
# Repository names on those OLD Nexus servers that were core OS repos (glob
# patterns, space separated). Sources pointing at them are dropped because
# nexus-os.repo / nexus-os.list replaces them. Example:
#   OLD_CORE_NAMES="OL[0-9]*-baseos OL[0-9]*-appstream Ubuntu-Repository Ubuntu-Security"
OLD_CORE_NAMES=""
# Old Nexus repo name -> repo on the new Nexus | real upstream paths
# (one rule per line: pattern|new-repo|path1 path2 ...   "-" = repo root;
#  $MAJOR and $ARCH are expanded). Used only for repo files that still point
# at an NX_EXTRA_HOSTS server. Example:
#   OLD_MAP='OL*-[Dd]ocker-[Cc]e|docker-yum|linux/centos/$MAJOR/$ARCH/stable
#   Ubuntu-Nginx|nginx-apt|packages/ubuntu'
OLD_MAP=''
# Access gate: see "access gate" below. PW_HASH=REPLACE_ME = no password.
PW_SALT="CHANGE-ME-SALT"
PW_HASH="REPLACE_ME"
# ---- optional external config file (overrides everything above)
SU_CONF="${SU_CONF:-/etc/server_update.conf}"
if [ -f "$SU_CONF" ]; then
  # only trust a file that only root can change (it is sourced as root)
  if [ "$(stat -c '%u' "$SU_CONF" 2>/dev/null)" = 0 ] && \
     [ -z "$(find "$SU_CONF" -perm /022 2>/dev/null)" ]; then
    . "$SU_CONF"
  else
    echo "ignoring $SU_CONF: must be owned by root and not group/world writable" >&2
  fi
fi
# =====================================================================
ZONE="${ZONE:-}"
ZONE_FILE=/etc/server_update.zone
NX_OS_ENV="${NEXUS_OS:-}"; NX_3P_ENV="${NEXUS_3P:-}"; NX_APP_ENV="${NEXUS_APP:-}"
APP_UPDATE="${APP_UPDATE:-0}"; NO_APP="${NO_APP:-0}"; DOCKER_AGE="${DOCKER_AGE:-90}"
DET=""; DET_DONE=""; ESM_LIST=0
KSTATE=ok; KMSG=""; RUN_K=""; NEW_K=""; DEF_K=""; LAST_RUN=""
SEC_OPT=""; SEC_MODE=sec; LVL_TXT=""; SEV_SEC=""; SEC_AFTER=""; SEV_CRIT=0; SEV_IMP=0; SEV_MOD=0; SEV_LOW=0; SEV_OTHER=0; SEV_GRADED=0
NEXUS_OS=""; NEXUS_3P=""
DO_UPDATE="${DO_UPDATE:-1}"
CHECK="${CHECK:-0}"   # report-only post-update status, change nothing
ACTION_SET=0   # 1 if the user picked an action via a flag (skip welcome menu)
# update level: security (default) | critical | important | full | none
LEVEL="${LEVEL:-}"
REBOOT="${REBOOT:-0}"
DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
BATCH="${BATCH:-0}"
VERBOSE="${VERBOSE:-0}"
FORCE="${FORCE:-0}"
AUTO_FIX="${AUTO_FIX:-0}"
# interactive = a real terminal is reachable. Test /dev/tty (where all prompts
# read from), NOT stdin: stdin is the pipe when run as  gpg -d file.gpg | bash,
# but /dev/tty still points at the user's terminal. Truly headless (Ansible,
# cron) has no /dev/tty, so this stays 0 there.
INTERACTIVE=0; { ( : < /dev/tty ) 2>/dev/null && INTERACTIVE=1; } || true
[ "$INTERACTIVE" = 0 ] && [ -t 0 ] && INTERACTIVE=1
TTY=0; [ -t 1 ] && TTY=1
EXCLUDE="${EXCLUDE:-}"
TIMEOUT="${TIMEOUT:-8}"
MIN_ROOT_MB="${MIN_ROOT_MB:-2048}"
MIN_VAR_MB="${MIN_VAR_MB:-2048}"
MIN_BOOT_MB="${MIN_BOOT_MB:-300}"
MIN_TMP_MB="${MIN_TMP_MB:-200}"
KEEP_KERNELS="${KEEP_KERNELS:-2}"

usage() { cat <<EOF
server_update.sh v$VERSION - connect this server to internal Nexus and upgrade

Usage: sudo bash server_update.sh [options]

Options:
  -n, --dry-run       test everything and show the plan, change nothing
  -y, --yes           do not ask anything (needed for Ansible/cron). Never
                      prompts, even if a terminal exists (ansible ssh -tt)
      --batch         plain output for Ansible / logs: no colours, no
                      progress bar. Use together with -y
  -r, --reboot        reboot automatically if a new kernel was installed
      --no-update     only configure repositories, do not upgrade
      --security      install only security updates (this is the default)
      --full          install ALL updates, not just security
      --level L       what to install: security | critical | important | full |
                      none. Default security. critical/important need per-CVE
                      severity data, which only Oracle Linux (and some Rocky)
                      provide; on Ubuntu they fall back to "all security".
  -e, --exclude LIST  packages to skip, quoted and space separated
                      e.g. -e "k3s* docker* containerd*"
  -a, --auto-fix      with -y: allow deep cleanup and LVM extend without asking
  -f, --force         continue even if disk space is low (not recommended)
  -v, --verbose       show full dnf/apt output on screen
      --app-packages  point pip / npm / helm at Nexus and upgrade pip / npm
                      global packages and the helm binary (default: report only)
      --no-app        skip the pip / npm / helm / docker step completely
  -z, --zone NAME     network zone of this server: dmz | internal | auto
                      (default: ask; "auto" probes every Nexus, slower)
      --check         report-only: after an update/reboot, show the current
                      state (kernel, pending security, reboot/grub) and what is
                      still needed. Changes nothing. Good for a post-reboot check.
  -h, --help          this help

Access:
  The script asks for the team password before doing anything (interactive:
  up to 3 tries). For Ansible/cron set it in the SU_PASS environment variable.
  Wrong or missing password exits with code 9.

Environment (same as options, handy for Ansible):
  DRY_RUN=1 ASSUME_YES=1 BATCH=1 AUTO_FIX=1 REBOOT=1 DO_UPDATE=0 EXCLUDE="..." FORCE=1 VERBOSE=1
  CHECK=1
  LEVEL=security|critical|important|full|none   (same as --level)
  SU_PASS="team-password"   (required unless running in an interactive terminal)
  NEXUS_OS=$NEXUS_OS
  ZONE=dmz|internal    (same as --zone)
  MIN_ROOT_MB=$MIN_ROOT_MB MIN_VAR_MB=$MIN_VAR_MB MIN_BOOT_MB=$MIN_BOOT_MB MIN_TMP_MB=$MIN_TMP_MB
  KEEP_KERNELS=$KEEP_KERNELS  (with -y -a: newest kernels kept besides running/default)

Examples:
  sudo bash server_update.sh                 # test, show plan, ask y/N, run
  sudo bash server_update.sh -n              # test only
  sudo bash server_update.sh -y -e "k3s*"    # unattended, skip k3s

Exit codes:
  0 OK   1 bad option   2 OS not supported   3 Nexus/repo failed (rolled back)
  4 upgrade failed   5 not root   6 already running   7 low disk   8 cancelled
  9 wrong/missing password   10 zone unknown/ambiguous

Modes:
  nexus   OL 8-10, Rocky 9, CentOS 7, Ubuntu, Debian: repos -> internal Nexus
  native  any other OS (OL7, RHEL, SLES, ...) or core repos missing on Nexus:
          existing repositories are kept unchanged and just upgraded

Self-healing:
  low disk  -> package cache is cleaned automatically; deeper cleanup
               (old kernels, old logs) and LVM extend are asked first
  bad repos -> third-party sources that break apt/dnf are disabled
               automatically; if a core OS repo fails, all changes roll back

Logs:    /var/log/server_update/<host>_<date>.log  (summary)
         /var/log/server_update/<host>_<date>.json + last_result.json (for Ansible)
         /var/log/server_update/<host>_<date>_full.log  (full dnf/apt output)
Backup:  /var/backups/server_update/<date>/
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    -y|--yes)     ASSUME_YES=1 ;;
    --batch)      BATCH=1 ;;
    -r|--reboot)  REBOOT=1 ;;
    --no-update)  DO_UPDATE=0; ACTION_SET=1 ;;
    --check)      CHECK=1; ACTION_SET=1 ;;
    --security)   LEVEL=security; ACTION_SET=1 ;;
    --full)       LEVEL=full; ACTION_SET=1 ;;
    --level)      shift; LEVEL="${1:-}"; ACTION_SET=1 ;;
    -e|--exclude) shift; EXCLUDE="${1:-}" ;;
    -a|--auto-fix) AUTO_FIX=1 ;;
    -f|--force)   FORCE=1 ;;
    -v|--verbose) VERBOSE=1 ;;
    -z|--zone)    shift; ZONE="${1:-}" ;;
    --app-packages) APP_UPDATE=1 ;;
    --no-app)     NO_APP=1 ;;
    *) echo "unknown option: $1  (see --help)"; exit 1 ;;
  esac
  shift
done

# ---- non-interactive (3.7.1) ------------------------------------------------
# Ansible with become and no pipelining connects with "ssh -tt": a pseudo
# terminal EXISTS although nobody sits there, so the /dev/tty test above says
# "interactive". Do not trust it alone:
#   -y       -> never ask anything (prompts would wait forever)
#   --batch  -> also plain output: no colours, no progress bar, no \r
[ "$ASSUME_YES" = 1 ] && INTERACTIVE=0
[ "$BATCH" = 1 ] && { INTERACTIVE=0; TTY=0; }


# ---------------------------------------------------------------- access gate
# Team password. This script is meant to be compiled to a binary with shc so
# this hash is not visible in normal use:  shc -r -f server_update.sh -o server_update
# PW_SALT / PW_HASH are set in the CONFIGURATION block at the top (or in
# /etc/server_update.conf). Set a password:
#   printf '%s' "YOUR-SALT:NEW-PASSWORD" | sha256sum
# PW_HASH="REPLACE_ME" switches the gate off.

pw_hash() { printf '%s' "$PW_SALT:$1" | sha256sum 2>/dev/null | cut -d" " -f1; }

check_password() {
  [ "$PW_HASH" = "REPLACE_ME" ] && return 0          # gate off until a hash is set
  command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum not found, cannot check password"; exit 9; }
  local pw try=0 src="env"
  # Ansible / non-interactive: read from $SU_PASS
  if [ -n "${SU_PASS:-}" ]; then
    [ "$(pw_hash "$SU_PASS")" = "$PW_HASH" ] && { unset SU_PASS; return 0; }
    unset SU_PASS; echo "wrong password (SU_PASS)"; exit 9
  fi
  # interactive: ask up to 3 times, no echo
  [ "$INTERACTIVE" = 1 ] || { echo "password required: set SU_PASS or run in a terminal"; exit 9; }
  while [ $try -lt 3 ]; do
    try=$((try+1))
    printf 'Password: ' >&2
    stty -echo 2>/dev/null; read -r pw < /dev/tty; stty echo 2>/dev/null; printf '\n' >&2
    [ "$(pw_hash "$pw")" = "$PW_HASH" ] && { unset pw; return 0; }
    echo "wrong password ($try/3)" >&2
  done
  echo "access denied" >&2; exit 9
}
check_password

TS=$(date +%Y%m%d-%H%M%S)
HOST=$(hostname -s 2>/dev/null || hostname)
# primary IP of this server (route to internal Nexus, else default route, else hostname)
IP=$(ip -4 route get "$(echo "$ZONES" | head -1 | cut -d'|' -f2 | sed 's#.*://##; s#[:/].*##')" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
[ -n "$IP" ] || IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
[ -n "$IP" ] || IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -n "$IP" ] || IP="?"
LOG_DIR=/var/log/server_update
SUM=$LOG_DIR/${HOST}_$TS.log
FULL=$LOG_DIR/${HOST}_${TS}_full.log
BAK_DIR=/var/backups/server_update/$TS
LOCK=/var/run/server_update.lock
N_CORE=0; N_3P=0; N_OFF=0; N_REPL=0; N_DUP=0; UPD=skipped; RBR=no; KEY=unknown; PKG=""
OS_TXT=unknown; DISK_TXT=""; NX_TXT=""; STEP=0; TOTAL=11; CUR=""; FAM=""; MODE=""; PKGMGR=""; N_NAT=0; UTD=unknown; PEND=0; UPG_SKIPPED=""

if [ "$TTY" = 1 ]; then
  C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_C=$'\e[36m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else
  C_G=""; C_Y=""; C_R=""; C_C=""; C_B=""; C_0=""
fi

# ---------------------------------------------------------------- output
# say: screen (colored) + summary log (plain)
say()  { printf '%s\n' "$1"; printf '%s\n' "$1" | sed 's/\x1b\[[0-9;]*m//g' >> "$SUM"; }
# log: full log only (screen too with -v)
log()  { local m; m=$(printf '%s' "$*" | sed -E 's#(://)[^/@ ]+@#\1***@#g')
         echo "[$(date +%H:%M:%S)] $m" >> "$FULL"; [ "$VERBOSE" = 1 ] && echo "  · $m" >&2; return 0; }
note() { echo "$*" >> "$REPORT"; log "$*"; }
plan() { echo "$1|$2|$3" >> "$TMP/plan"; log "plan $1 $2 -> $3"; }
off()  { plan off "$1" "$2"; echo "OFF    $1: $2" >> "$REPORT"; N_OFF=$((N_OFF+1)); }

step() {
  STEP=$((STEP+1)); CUR=$1
  printf '  %s[%d/%d]%s %-26s ' "$C_C" "$STEP" "$TOTAL" "$C_0" "$1"
  log "===== step $STEP/$TOTAL: $1"
}
status() { # OK|WARN|FAIL|SKIP  text
  local c=$C_G
  case "$1" in WARN|SKIP) c=$C_Y ;; FAIL) c=$C_R ;; esac
  printf '%s%-4s%s  %s\n' "$c" "$1" "$C_0" "${2:-}"
  printf '  [%d/%d] %-26s %-4s  %s\n' "$STEP" "$TOTAL" "$CUR" "$1" "${2:-}" >> "$SUM"
  log "result: $1 ${2:-}"
}

# run a command: output to full log (and screen with -v)
run() {
  log "\$ $*"
  if [ "$VERBOSE" = 1 ]; then "$@" 2>&1 | tee -a "$FULL"; return ${PIPESTATUS[0]}
  else "$@" >> "$FULL" 2>&1; fi
}

finish() {
  local rc=$1 res l x
  case "$rc" in
    0) res="${C_G}SUCCESS${C_0}" ;; 8) res="${C_Y}CANCELLED${C_0}" ;; *) res="${C_R}FAILED${C_0}" ;;
  esac
  local upc updl ktxt rbtxt
  say ""
  say "  ${C_B}===================== Summary =====================${C_0}"
  say "   Host / IP    : $HOST / ${C_G}$IP${C_0}"
  say "   Zone         : ${C_C}${ZONE:-?}${C_0} (${ZONE_SRC:-?})"
  say "   OS           : $OS_TXT${MODE:+  ($MODE mode)}"
  say "   Disk free    : ${DISK_TXT:--}"
  say "   Nexus        : ${NX_TXT:--}"
  say "   Repos        : core=${C_G}$N_CORE${C_0}  third-party=${C_C}$N_3P${C_0}  disabled=$( [ "$N_OFF" -gt 0 ] && echo "${C_Y}$N_OFF${C_0}" || echo "0")"

  # --- Update line (colored by outcome) ---
  case "$UPD" in
    ok)        upc="${C_G}ok${C_0}" ;;
    failed)    upc="${C_R}failed${C_0}" ;;
    skipped|cancelled|dry-run) upc="${C_Y}$UPD${C_0}" ;;
    *)         upc="$UPD" ;;
  esac
  updl="   Update       : $upc"
  [ -n "${LVL_TXT:-}" ] && updl="$updl  [${C_C}${LVL_TXT}${C_0}]"
  [ -n "${PKG:-}" ] && updl="$updl  (${C_G}$PKG${C_0} packages)"
  say "$updl"

  # --- Severity: one line each, colored (only when graded data exists) ---
  if [ -n "${SEV_SEC:-}" ] && [ "${SEV_GRADED:-0}" = 1 ]; then
    say "   Severity (found before update):"
    say "     Critical : $( [ "${SEV_CRIT:-0}" -gt 0 ] && echo "${C_R}$SEV_CRIT${C_0}" || echo "0")"
    say "     Important: $( [ "${SEV_IMP:-0}" -gt 0 ] && echo "${C_Y}$SEV_IMP${C_0}" || echo "0")"
    say "     Moderate : $( [ "${SEV_MOD:-0}" -gt 0 ] && echo "${C_C}$SEV_MOD${C_0}" || echo "0")"
    say "     Low      : ${SEV_LOW:-0}"
  elif [ -n "${SEV_SEC:-}" ]; then
    say "   Security     : $( [ "${SEV_SEC:-0}" -gt 0 ] && echo "${C_Y}$SEV_SEC found before update${C_0} (no per-severity data)" || echo "${C_G}0 found before update${C_0}")"
  fi
  [ -n "${SEC_AFTER:-}" ] && say "   Security left: $( [ "$SEC_AFTER" -gt 0 ] && echo "${C_R}$SEC_AFTER still pending after the update${C_0}" || echo "${C_G}0 - all security updates installed${C_0}")"

  # --- Up to date ---
  case "$UTD" in
    yes)     say "   Up to date   : ${C_G}yes${C_0} (nothing left to upgrade)" ;;
    no)      say "   Up to date   : ${C_Y}no${C_0} ($PEND package(s) still upgradable)" ;;
    partial) say "   Up to date   : ${C_Y}partial${C_0} (unreachable repos: $NAT_FAIL)" ;;
    *)       [ "$UPD" != skipped ] && say "   Up to date   : ${UTD:-unknown}" ;;
  esac

  # --- App packages (pip/npm/helm) ---
  [ -n "$APP_TXT" ] && say "   App packages : $APP_TXT$( [ "${APP_OUT:-0}" -gt 0 ] && echo "  (${C_Y}outdated: $APP_OUT${C_0})")"

  # --- Kernel / reboot (the thing the security scanner cares about) ---
  case "${KSTATE:-ok}" in
    ok)     [ "$RBR" = yes ] && ktxt="${C_Y}reboot required${C_0}" || ktxt="${C_G}ok (running newest)${C_0}" ;;
    reboot) ktxt="${C_Y}reboot required to activate new kernel${C_0}" ;;
    grub)   ktxt="${C_R}grub default is an OLD kernel - fix + reboot${C_0}" ;;
    *)      ktxt="${KSTATE:-?}" ;;
  esac
  say "   Kernel/boot  : $ktxt"
  [ "${KSTATE:-}" = grub ] && say "                  ${C_R}grubby --set-default /boot/vmlinuz-$NEW_K${C_0}"

  # --- Result ---
  say "   Result       : $res  (exit $rc)"

  if [ -s "$REPORT" ]; then
    say "  ------------------- Notes -------------------"
    dedupe < "$REPORT" | while IFS='|' read -r x l; do
      [ "$x" -gt 1 ] && l="$l  (x$x)"
      case "$l" in
        FAIL*) say "   ${C_R}$l${C_0}" ;;
        WARN*) say "   ${C_Y}$l${C_0}" ;;
        OFF*)  say "   ${C_Y}$l${C_0}" ;;
        INFO*) say "   ${C_C}$l${C_0}" ;;
        *)     say "   $l" ;;
      esac
    done
  fi
  say "  ---------------------------------------------"
  say "   Log          : $SUM"
  say "   Full log     : $FULL"
  [ -d "$BAK_DIR" ] && say "   Backup       : $BAK_DIR"
  say "  ${C_B}==================================================${C_0}"
  say "  ${C_B}(the line below is for Ansible / scripts, not for reading)${C_0}"
  l="host=$HOST ip=$IP zone=${ZONE:-?} os=$KEY core=$N_CORE thirdparty=$N_3P disabled=$N_OFF mode=${MODE:-?} update=$UPD level=${LEVEL:-?} packages=${PKG:-0} security_pending=${SEC_AFTER:-?} security_before=${SEV_SEC:-0} crit=${SEV_CRIT:-0} kernel=${KSTATE:-?} uptodate=$UTD pending=$PEND app_outdated=${APP_OUT:-0} reboot_required=$RBR exit=$rc"
  say "RESULT $l"
  write_result "$l"
  rm -rf "$TMP"; rm -rf "$LOCK" 2>/dev/null
  exit "$rc"
}

# ---------------------------------------------------------------- result JSON
# (3.7.1) one JSON per run next to its log + $LOG_DIR/last_result.json.
# last_result.json is deleted at start: missing file = run ended before finish().
json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/ /g; s/\r//g'; }
write_result() { # "k=v k=v ..."
  local kv k v j="" n=""
  set -f
  for kv in $1; do
    k=${kv%%=*}; v=${kv#*=}
    case "$v" in ''|*[!0-9]*) j="$j\"$k\":\"$(json_esc "$v")\"," ;; *) j="$j\"$k\":$v," ;; esac
  done
  set +f
  [ -s "${REPORT:-/nonexistent}" ] && n=$(awk '!s[$0]++' "$REPORT" | while IFS= read -r v; do printf '"%s",' "$(json_esc "$v")"; done)
  n=${n%,}
  j="{${j}\"version\":\"$VERSION\",\"ts\":\"$TS\",\"summary_log\":\"$SUM\",\"full_log\":\"$FULL\",\"backup\":\"$( [ -d "$BAK_DIR" ] && echo "$BAK_DIR")\",\"notes\":[${n}]}"
  printf '%s\n' "$j" > "${SUM%.log}.json" 2>/dev/null
  printf '%s\n' "$j" > "$LOG_DIR/last_result.json" 2>/dev/null
  chmod 640 "${SUM%.log}.json" "$LOG_DIR/last_result.json" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------- lock
# (3.7.1) lock dir holds the owner pid. A lock whose owner is dead (killed run,
# SSH drop on 3.7.0, Ansible async timeout) is removed - unless a package
# manager is still running, then we stop and let a human look.
take_lock() {
  local op pm
  if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"; return 0; fi
  op=$(cat "$LOCK/pid" 2>/dev/null | tr -dc '0-9')
  if [ -n "$op" ] && kill -0 "$op" 2>/dev/null; then
    echo "already running (pid $op, $LOCK)"; exit 6
  fi
  pm=$(ps -eo pid=,comm= 2>/dev/null | awk '$2 ~ /^(dnf|yum|dnf-3|apt|apt-get|dpkg|zypper|rpm|unattended-upgr)$/ {print $2 "(" $1 ")"}' | tr '\n' ' ')
  if [ -n "$pm" ]; then
    echo "stale lock $LOCK (owner ${op:-unknown} gone) but a package manager is running: $pm- not touching it"; exit 6
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || { echo "cannot take lock $LOCK"; exit 6; }
  echo $$ > "$LOCK/pid"
  echo "stale lock removed (owner ${op:-unknown} no longer running)" >&2
}

# ---------------------------------------------------------------- helpers
http_code() {
  if command -v curl >/dev/null 2>&1; then
    curl -s --noproxy '*' -o /dev/null -m "$TIMEOUT" -w '%{http_code}' "$1"
  elif command -v wget >/dev/null 2>&1; then
    if wget -q --no-proxy -T "$TIMEOUT" -t 1 --spider "$1"; then echo 200; else echo 000; fi
  else echo 000; fi
}

# probe <url> <yum|apt> [suite]
probe() {
  if [ "$2" = yum ]; then
    [ "$(http_code "$1/repodata/repomd.xml")" = 200 ]
  else
    [ "$(http_code "$1/dists/$3/InRelease")" = 200 ] || \
    [ "$(http_code "$1/dists/$3/Release")" = 200 ]
  fi
}

# path suffixes, longest first:  a/b/c -> a/b/c, b/c, c
suffixes() {
  local p="${1#/}"; p="${p%/}"
  while [ -n "$p" ]; do
    echo "$p"
    case "$p" in */*) p="${p#*/}" ;; *) p="" ;; esac
  done
}

# path part of a URL with yum variables expanded
url_path() {
  local p="${1#*://}"
  case "$p" in */*) p="${p#*/}" ;; *) p="" ;; esac
  p="${p%%\?*}"
  echo "$p" | sed -e "s/[\$]releasever_major/$MAJOR/g" -e "s/[\$]releasever/$MAJOR/g" \
                  -e "s/[\$]basearch/$ARCH/g" -e "s/[\$]arch/$ARCH/g" \
                  -e 's/[$][A-Za-z_]*//g' -e 's#/*$##'
}

# find_repo <yum|apt> "<nexus names>" "<upstream path>" "<bases>" <strict> [suite]
# strict=1: never accept the repo root (versioned products)
find_repo() {
  local kind=$1 names=$2 path=$3 bases=$4 strict=$5 suite=${6:-} n b s
  for n in $names; do
    for b in $bases; do
      while read -r s; do
        [ -z "$s" ] && continue
        probe "$b/$n/$s" "$kind" "$suite" && { echo "$b/$n/$s"; return 0; }
      done <<EOF
$(suffixes "$path")
EOF
      [ "$strict" = 1 ] && continue
      probe "$b/$n" "$kind" "$suite" && { echo "$b/$n"; return 0; }
    done
  done
  return 1
}

is_nexus() { local h; for h in $NX_HOSTS; do case "$1" in *"$h"*) return 0 ;; esac; done; return 1; }

# lookup <table-function> <url>  -> sets L_CANDS L_STRICT (first match wins)
lookup() {
  local pat oss cands st lp
  while IFS='|' read -r pat oss cands st lp; do
    [ -z "$pat" ] && continue
    case " $oss " in *" $KEY "*|" * ") ;; *) continue ;; esac
    if [[ "$2" == *$pat* ]]; then
      L_CANDS=$cands; L_STRICT=$st
      L_PATH=$(echo "$lp" | sed "s/[\$]MAJOR/$MAJOR/g; s/[\$]ARCH/$ARCH/g"); return 0
    fi
  done <<EOF
$($1)
EOF
  return 1
}

# ---------------------------------------------------------------- OS
# KEY=value from /etc/os-release, quotes removed, only safe characters kept
os_val() { sed -n "s/^$1=//p" /etc/os-release | head -1 | tr -d "\"'" | tr -dc 'A-Za-z0-9._-'; }
detect_os() {
  OS_ID=""; OS_VER=""; OS_CODE=""
  if [ -r /etc/os-release ]; then
    # read values as plain text (no eval / no sourcing of the file)
    OS_ID=$(os_val ID); OS_VER=$(os_val VERSION_ID)
    OS_CODE=$(os_val VERSION_CODENAME); [ -n "$OS_CODE" ] || OS_CODE=$(os_val UBUNTU_CODENAME)
  elif [ -r /etc/SuSE-release ]; then
    OS_ID=sles; OS_VER=$(awk '/^VERSION/{print $3}' /etc/SuSE-release)
  elif [ -r /etc/centos-release ]; then
    OS_ID=centos; OS_VER=$(sed 's/[^0-9.]//g' /etc/centos-release)
  elif [ -r /etc/oracle-release ]; then
    OS_ID=ol; OS_VER=$(sed 's/[^0-9.]//g' /etc/oracle-release)
  elif [ -r /etc/redhat-release ]; then
    OS_ID=rhel; OS_VER=$(sed 's/[^0-9.]//g' /etc/redhat-release)
  fi
  MAJOR=${OS_VER%%.*}; ARCH=$(uname -m)
  case "$OS_ID" in
    ol)     KEY=ol$MAJOR ;;     rocky)  KEY=rocky$MAJOR ;;
    almalinux) KEY=alma$MAJOR ;;
    centos) KEY=centos$MAJOR ;; rhel)   KEY=rhel$MAJOR ;;
    ubuntu) KEY=ubuntu ;;       debian) KEY=debian ;;
    sles|sled|suse*) KEY=sles$MAJOR ;;
    *) KEY=unknown ;;
  esac
}

# ---------------------------------------------------------------- tables
# pattern | os keys ("*" = all) | nexus repo candidates | strict
# pattern | os keys ("*" = all) | nexus repo candidates | strict | [path for
# mirrorlist/metalink URLs]   - new Nexus proxies the vendor site root, the
# real repo path is found by testing the URL path (see find_repo)
yum_map() { cat <<'EOF'
openh264|*|-|0
epel*next|*|-|0
fedoraproject.org*epel|*|epel-aio|1|pub/epel/$MAJOR/Everything/$ARCH
dl.fedoraproject.org/pub/epel|*|epel-aio|1
download.docker.com|*|docker-yum|1
repo.zabbix.com|*|zabbix-aio-yum|1
nginx.org|*|nginx-yum|1
openresty.org|*|openresty-yum|1
download.postgresql.org|*|pgdg-yum|1
mariadb|*|mariadb-yum|1
artifacts.elastic.co|*|elastic-aio-yum|1
packages.gitlab.com|*|gitlab-yum|1
rpm.releases.hashicorp.com|*|hashicorp-yum|1
packages.redis.io|*|redis-yum|1
rpm.nodesource.com|*|nodejs-yum|1
haproxy|*|haproxy-yum|1
timescale|*|timescaledb-yum|1
EOF
}

# checked after the core-repo test: everything else of the OS vendor
yum_generic() { cat <<'EOF'
OracleLinux/|*|oraclelinux-aio|1
EOF
}

apt_map() { cat <<'EOF'
esm.ubuntu.com/infra|ubuntu|ubuntu-esm-infra-aio ubuntu-snapshot-esm-infra-security ubuntu-snapshot-esm-infra-updates|0
esm.ubuntu.com/apps|ubuntu|ubuntu-esm-apps-aio ubuntu-snapshot-esm-apps-security ubuntu-snapshot-esm-apps-updates|0
download.docker.com|*|docker-apt|0
repo.zabbix.com|*|zabbix-aio-apt|0
nginx.org|*|nginx-apt|0
apt.postgresql.org|*|pgdg-apt|0
apt.releases.hashicorp.com|*|hashicorp-apt|0
timescale|*|timescaledb-apt|0
packages.redis.io|*|redis-apt|0
openresty.org|*|openresty-apt|0
gitlab|*|gitlab-apt|0
haproxy|*|haproxy-apt|0
linbit|*|drbd9-apt|0
mariadb|*|mariadb-apt|1
deb.nodesource.com|*|nodejs-apt|1
artifacts.elastic.co|*|elastic-aio-apt|1
EOF
}

# repos of the OLD Nexus servers (NX_EXTRA_HOSTS): old name -> new repo | real
# paths ("-" = repo root). Used when a repo file still points at an old Nexus.
# The rules come from OLD_MAP in the CONFIGURATION block (leading blanks removed).
old_map() { printf '%s\n' "$OLD_MAP" | sed 's/^[[:space:]]*//'; }

# old-Nexus repo names that were core OS repos (replaced by nexus-os.*)
# patterns come from OLD_CORE_NAMES in the CONFIGURATION block
is_old_core_name() {
  local pat
  set -f
  for pat in $OLD_CORE_NAMES; do
    case "$1" in $pat) set +f; return 0 ;; esac
  done
  set +f
  return 1
}

# old Nexus URL -> same repo on the zone's Nexus (echo URL). kind: yum|apt [suite]
old_remap() {
  local n=${1#*/repository/} pat new paths p
  n=${n%%/*}
  while IFS='|' read -r pat new paths; do
    [ -n "$pat" ] || continue
    case "$n" in $pat) break ;; *) pat="" ;; esac
  done <<EOF
$(old_map)
EOF
  [ -n "$pat" ] || return 1
  if [ "$paths" = "-" ]; then find_repo "$2" "$new" "" "$BASES_3P" 0 "${3:-}"; return; fi
  paths=$(echo "$paths" | sed "s/[\$]MAJOR/$MAJOR/g; s/[\$]ARCH/$ARCH/g")
  for p in $paths; do find_repo "$2" "$new" "$p" "$BASES_3P" 1 "${3:-}" && return 0; done
  return 1
}

# ---------------------------------------------------------------- YUM / DNF
# id | nexus names | upstream path | gpg key | required | enabled
core_yum() {
  local o="repo/OracleLinux/OL$MAJOR" k=/etc/pki/rpm-gpg/RPM-GPG-KEY-oracle r n uek x
  case "$KEY" in
    ol7)  echo "ol7_latest|oraclelinux-aio|$o/latest/$ARCH|$k|1|1"
          echo "ol7_optional_latest|oraclelinux-aio|$o/optional/latest/$ARCH|$k|0|1"
          echo "ol7_addons|oraclelinux-aio|$o/addons/$ARCH|$k|0|1" ;;
    ol8|ol9|ol10)
          echo "ol${MAJOR}_baseos_latest|oraclelinux-aio|$o/baseos/latest/$ARCH|$k|1|1"
          echo "ol${MAJOR}_appstream|oraclelinux-aio|$o/appstream/$ARCH|$k|1|1"
          echo "ol${MAJOR}_addons|oraclelinux-aio|$o/addons/$ARCH|$k|0|1" ;;
    rocky*|alma*)
          case "$KEY" in
            rocky*) n=rocky-aio;     r=pub/rocky/$MAJOR
                    k=/etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-$MAJOR
                    [ -r "$k" ] || k=/etc/pki/rpm-gpg/RPM-GPG-KEY-rockyofficial ;;
            *)      n=almalinux-aio; r=almalinux/$MAJOR
                    k=/etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux-$MAJOR
                    [ -r "$k" ] || k=/etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux ;;
          esac
          x=CRB; [ "$MAJOR" = 8 ] && x=PowerTools
          echo "baseos|$n|$r/BaseOS/$ARCH/os|$k|1|1"
          echo "appstream|$n|$r/AppStream/$ARCH/os|$k|1|1"
          echo "extras|$n|$r/extras/$ARCH/os|$k|0|1"
          echo "$(echo $x | tr 'A-Z' 'a-z')|$n|$r/$x/$ARCH/os|$k|0|$CRB_ON" ;;
  esac
  case "$KEY" in ol*)
    uek=$(rpm -q --qf '%{VERSION}\n' kernel-uek 2>/dev/null | grep -v 'not installed' | sort -V | tail -1)
    case "$KEY:$uek" in
      ol7:4.14*)  r=UEKR5 ;;  ol7:5.4*|ol8:5.4*) r=UEKR6 ;;
      ol8:5.15*|ol9:5.15*)    r=UEKR7 ;;
      ol9:6.12*|ol10:6.12*)   r=UEKR8 ;;
      *:) r="" ;;
      *) r=""; echo "WARN UEK $uek: no known UEK repo" >> "$REPORT" ;;
    esac
    [ -n "$r" ] && echo "ol${MAJOR}_$r|oraclelinux-aio|$o/$r/$ARCH|$k|1|1" ;;
  esac
}

is_core_yum() {
  case "$1" in
    */OracleLinux/OL[0-9]/baseos/*|*/OracleLinux/OL[0-9][0-9]/baseos/*) return 0 ;;
    */OracleLinux/OL[0-9]/appstream/*|*/OracleLinux/OL[0-9][0-9]/appstream/*) return 0 ;;
    */OracleLinux/OL[0-9]/addons/*|*/OracleLinux/OL[0-9][0-9]/addons/*) return 0 ;;
    */OracleLinux/OL7/latest/*|*/OracleLinux/OL7/optional/latest/*) return 0 ;;
    */OracleLinux/OL*/UEKR[0-9]/[!R]*) return 0 ;;
    *rockylinux*|*/rocky/*|*almalinux*|*mirror.centos.org*|*mirrorlist.centos.org*|*vault.centos.org*) return 0 ;;
  esac
  return 1
}

# file|id|enabled|url|gpgkey|module_hotfixes
parse_repo() {
  awk -v F="$1" '
    { sub(/\r$/, "") }
    function val(s) { sub(/^[^=]*=[ \t]*/, "", s); return s }
    function flush() { if (id != "") print F "|" id "|" en "|" (bu != "" ? bu : ml) "|" gk "|" mh }
    /^\[/ { flush(); id=$0; gsub(/[\[\]]/, "", id); en=1; bu=""; ml=""; gk=""; mh=""; next }
    /^[ \t]*enabled[ \t]*=/          { en = val($0) + 0 }
    /^[ \t]*baseurl[ \t]*=/          { if (bu == "") { split(val($0), a, /[ \t,]+/); bu = a[1] } }
    /^[ \t]*(mirrorlist|metalink)[ \t]*=/ { if (ml == "") ml = val($0) }
    /^[ \t]*gpgkey[ \t]*=/           { gk = val($0) }
    /^[ \t]*module_hotfixes[ \t]*=/  { mh = val($0) }
    END { flush() }' "$1"
}

scan_yum() {
  local f
  for f in /etc/yum.repos.d/*.repo; do
    [ -e "$f" ] || continue
    case "$f" in */nexus-os.repo) continue ;; esac
    parse_repo "$f"
  done > "$TMP/sections"
  CRB_ON=0
  grep -qiE '^[^|]*\|(crb|powertools)\|1\|' "$TMP/sections" && CRB_ON=1
}

# ---------------------------------------------------------------- disk
# measure -> $TMP/disk : mount|avail_MB|need_MB|use%|device
disk_measure() {
  local spec p need seen=""
  if [ "$DO_UPDATE" != 1 ]; then MIN_ROOT_MB=300; MIN_VAR_MB=500; MIN_BOOT_MB=0; fi
  : > "$TMP/disk"
  for spec in "/:$MIN_ROOT_MB" "/var:$MIN_VAR_MB" "/boot:$MIN_BOOT_MB" "/tmp:$MIN_TMP_MB"; do
    p=${spec%%:*}; need=${spec#*:}
    [ -d "$p" ] || continue
    set -- $(df -Pm "$p" 2>/dev/null | awk 'NR==2{print $1, $4, $5, $6}')
    [ $# -eq 4 ] || continue
    case " $seen " in *" $4 "*) continue ;; esac
    seen="$seen $4"
    echo "$4|$2|$need|${3%\%}|$1" >> "$TMP/disk"
  done
  DISK_TXT=$(awk -F'|' '{ printf "%s=%s ", $1, ($2 >= 1024 ? int($2/1024) "G" : $2 "M") }' "$TMP/disk")
  DISK_TXT=${DISK_TXT% }
  log "disk: $(tr '\n' ' ' < "$TMP/disk")"
}
disk_low()  { awk -F'|' '$2 < $3' "$TMP/disk"; }
disk_full() { awk -F'|' '$4 >= 90' "$TMP/disk"; }
fmt_mb() { if [ "$1" -ge 1024 ] 2>/dev/null; then echo "$(( $1 / 1024 ))G"; else echo "${1}M"; fi; }

# ask "question" -> 0 = yes. -y needs --auto-fix; dry-run never changes
ask() {
  local a
  if [ "$DRY_RUN" = 1 ]; then say "         (dry-run) would ask: $1"; return 1; fi
  if [ "$ASSUME_YES" = 1 ]; then
    if [ "$AUTO_FIX" = 1 ]; then say "         $1 -> yes (--auto-fix)"; return 0; fi
    say "         $1 -> no (add --auto-fix to allow)"; return 1
  fi
  [ "$INTERACTIVE" = 1 ] || return 1
  printf '         %s%s [y/N]: %s' "$C_B" "$1" "$C_0"
  read -r a < /dev/tty
  echo "         $1 [y/N]: ${a:-<empty>}" >> "$SUM"
  case "$a" in y|Y|yes|YES) return 0 ;; esac
  return 1
}

# safe: package cache only
clean_cache() {
  say "         -> cleaning package cache (safe)"
  case "$FAM" in
    yum)    run "$(yum_pm)" clean all; rm -rf /var/cache/dnf/* /var/cache/yum/* 2>/dev/null ;;
    zypper) run zypper --non-interactive clean --all ;;
    *)      run apt-get clean ;;
  esac
}

# deeper: old kernels / unused packages, rotated logs > 7 days, journal > 200M
clean_deep() {
  local prot p keep=""
  say "         -> old kernels"
  kernel_menu
  if [ "$FAM" = apt ]; then
    # autoremove may also drop old kernels: protect the ones still installed
    say "         -> removing unused packages (remaining kernels are protected)"
    prot=$(apt-mark showauto 2>/dev/null | grep -E '^linux-(image|modules|modules-extra|headers)-[0-9]')
    [ -n "$prot" ] && run apt-mark manual $prot
    run apt-get -y autoremove --purge
    for p in $prot; do dpkg -s "$p" >/dev/null 2>&1 && keep="$keep $p"; done
    [ -n "$keep" ] && run apt-mark auto $keep
  fi
  say "         -> removing rotated logs older than 7 days (audit/auth/secure kept), journal > 200M"
  run find /var/log -xdev -type f -not -path '/var/log/audit/*' -not -name 'secure*' -not -name 'auth.log*' -not -path '/var/log/server_update/*' -not -path '/var/log/nexus_setup/*'  \( -name '*.gz' -o -name '*.xz' -o -name '*.[0-9]' -o -name '*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' \) -mtime +7 -delete
  command -v journalctl >/dev/null 2>&1 && run journalctl --vacuum-size=200M
  return 0
}

# ---------------------------------------------------------------- kernels
# installed kernel versions (same format as `uname -r`), oldest first
# installed kernels, OLDEST first (rpm: by install time - sort -V gets
# 6.12.0-208.112.5.el9uek vs ...5.2.el9uek wrong)
list_kernels() {
  case "$FAM" in
    yum) rpm -q --last kernel kernel-core kernel-uek kernel-uek-core 2>/dev/null | grep -v 'not installed' \
           | awk '{print $1}' | sed -E 's/^kernel(-uek)?(-core)?-//' | awk '!s[$0]++' | tac ;;
    apt) dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' 'linux-image-[0-9]*' 2>/dev/null \
           | awk '$2 ~ /^ii/ { sub(/^linux-image-/, "", $1); print $1 }' | sort -u | sort -V ;;
  esac
}

default_kernel() {
  local k=""
  if command -v grubby >/dev/null 2>&1; then k=$(grubby --default-kernel 2>/dev/null)
  elif [ -L /boot/vmlinuz ]; then k=$(readlink -f /boot/vmlinuz); fi
  k=${k##*/}; echo "${k#vmlinuz-}"
}

# newest installed kernel on disk (version string, like uname -r), or empty
# (3.7.3) newest kernel of the SAME flavor as the running one: never suggest a
# switch UEK <-> RHCK or -fips -> -generic
newest_installed_kernel() {
  local run; run=$(uname -r)
  case "$FAM" in
    yum) rpm -q --last kernel kernel-core kernel-uek kernel-uek-core 2>/dev/null | grep -v 'not installed' \
           | awk '{print $1}' | sed -E 's/^kernel(-uek)?(-core)?-//' \
           | { case "$run" in (*uek*) grep uek ;; (*) grep -v uek ;; esac; } | head -1 ;;
    apt) ls /boot/vmlinuz-* 2>/dev/null | grep -v rescue | sed 's#.*/vmlinuz-##' \
           | grep -- "-${run##*-}\$" | sort -V | tail -1 ;;
  esac
}

# Sets KSTATE and KMSG:
#   KSTATE=ok       running kernel is the newest installed and the default
#   KSTATE=reboot   newer kernel installed, default points at it -> just reboot
#   KSTATE=grub     newer kernel installed but NOT the default boot -> grub fix
# RUN_K / NEW_K / DEF_K hold the three versions.
kernel_state() {
  RUN_K=$(uname -r); NEW_K=$(newest_installed_kernel); DEF_K=$(default_kernel)
  KSTATE=ok; KMSG=""
  [ -n "$NEW_K" ] || { return 0; }
  if [ "$RUN_K" = "$NEW_K" ]; then KSTATE=ok; return 0; fi
  # a newer kernel is installed but not running
  case "$DEF_K" in
    "$NEW_K"|*"$NEW_K"*) KSTATE=reboot
        KMSG="newer kernel installed ($NEW_K), default boot is set to it -> reboot to activate" ;;
    *)  KSTATE=grub
        KMSG="newer kernel installed ($NEW_K) but default boot is still $DEF_K -> fix grub default, then reboot" ;;
  esac
  return 0
}

# apply the grub fix (make the newest installed kernel the default)
fix_grub_default() {
  command -v grubby >/dev/null 2>&1 || { note "WARN   grubby not found - set the default kernel by hand"; return 1; }
  local path
  path=$(ls -t /boot/vmlinuz-*"$NEW_K"* 2>/dev/null | head -1)
  [ -n "$path" ] || path=$(ls /boot/vmlinuz-"$NEW_K" 2>/dev/null | head -1)
  [ -n "$path" ] || { note "WARN   grub: /boot image for $NEW_K not found"; return 1; }
  run grubby --set-default "$path" || { note "WARN   grub: grubby --set-default failed"; return 1; }
  DEF_K=$(default_kernel); note "INFO   grub default set to $NEW_K (was pointing elsewhere)"
  return 0
}

# all packages that belong to one kernel version
kernel_pkgs() {
  case "$FAM" in
    yum) rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH}\n' 'kernel*' 2>/dev/null \
           | awk -v K="$1" '$2 == K && $1 ~ /^kernel(-uek)?(-core|-modules(-core|-extra|-internal)?|-devel)?$/ { print $1 "-" $2 }' ;;
    apt) dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' "linux-*-$1" 2>/dev/null | awk '$2 ~ /^ii/ { print $1 }' ;;
  esac
}

# show installed kernels, let the user choose which to remove
# (-y -a: keep running + default + newest KEEP_KERNELS, remove the rest)
kernel_menu() {
  local run def newest k n=0 sz fl sel i rm="" cnt left
  if [ "$FAM" = zypper ]; then say "         kernel cleanup is not done on SUSE (zypper purge-kernels handles it)"; return 0; fi
  list_kernels > "$TMP/kv"; : > "$TMP/kmap"
  cnt=$(grep -c . "$TMP/kv")
  [ "$cnt" -gt 1 ] || { say "         only one kernel installed - nothing to remove"; return 0; }
  run=$(uname -r); def=$(default_kernel)
  newest=$(tail -n "$KEEP_KERNELS" "$TMP/kv" | tr '\n' ' ')
  say "         Installed kernels:"
  while read -r k; do
    n=$((n+1)); echo "$n|$k" >> "$TMP/kmap"
    sz=$(du -cm /boot/*"$k"* 2>/dev/null | tail -1 | cut -f1)
    fl=""
    [ "$k" = "$run" ] && fl="$fl ${C_G}[running]${C_0}"
    [ "$k" = "$def" ] && fl="$fl ${C_C}[default boot]${C_0}"
    [ "$n" = "$cnt" ] && fl="$fl [newest]"
    say "           $n) $(printf '%-44s %4sM' "$k" "${sz:-?}")$fl"
  done < "$TMP/kv"

  if [ "$ASSUME_YES" = 1 ]; then
    while read -r k; do
      case " $run $def $newest " in *" $k "*) ;; *) rm="$rm $k" ;; esac
    done < "$TMP/kv"
    say "         auto (--auto-fix): keeping running, default and newest $KEEP_KERNELS"
  else
    [ "$INTERACTIVE" = 1 ] || return 0
    printf '         %sKernels to remove (numbers, e.g. "3 4"; Enter = none): %s' "$C_B" "$C_0"
    read -r sel < /dev/tty
    echo "         kernels to remove: ${sel:-<none>}" >> "$SUM"
    for i in $sel; do
      k=$(awk -F'|' -v N="$i" '$1 == N { print $2 }' "$TMP/kmap")
      if [ -z "$k" ]; then say "         ${C_Y}'$i' is not in the list - ignored${C_0}"; continue; fi
      if [ "$k" = "$run" ]; then say "         ${C_Y}$i) is the running kernel - cannot remove${C_0}"; continue; fi
      if [ "$k" = "$def" ]; then
        say "         ${C_Y}$i) is the default boot kernel - change the default first (grubby --set-default) - skipped${C_0}"; continue
      fi
      case " $rm " in *" $k "*) ;; *) rm="$rm $k" ;; esac
    done
    [ -n "$rm" ] || { say "         no kernel selected"; return 0; }
    left=$(( cnt - $(echo $rm | wc -w) ))
    if [ "$left" -lt 2 ]; then
      ask "Only $left kernel will remain (no fallback kernel). Continue?" || { say "         no kernel removed"; return 0; }
    fi
    ask "Remove kernel(s):$rm ?" || { say "         no kernel removed"; return 0; }
  fi
  [ -n "$rm" ] || { say "         nothing to remove"; return 0; }
  for k in $rm; do
    say "         -> removing kernel $k"
    if [ "$FAM" = yum ]; then run "$(yum_pm)" -y remove --disablerepo='*' $(kernel_pkgs "$k")
    else run apt-get -y purge $(kernel_pkgs "$k"); fi
  done
  note "INFO   kernels removed:$rm"
}

# grow an LVM mount with free space in its VG
lvm_extend() { # mount need avail device
  local mp=$1 need=$2 av=$3 dev=$4 vg="" lv="" p v l free add target
  command -v lvs >/dev/null 2>&1 || { say "         $mp: LVM tools not found, cannot extend"; return 1; }
  target=$(readlink -f "$dev")
  while read -r v l p; do
    [ -n "$p" ] && [ "$(readlink -f "$p")" = "$target" ] && { vg=$v; lv=$l; break; }
  done <<EOF
$(lvs --noheadings -o vg_name,lv_name,lv_path 2>/dev/null)
EOF
  [ -n "$vg" ] || { say "         $mp: plain partition (not LVM), cannot extend automatically"; return 1; }
  free=$(vgs --noheadings --units m --nosuffix -o vg_free "$vg" 2>/dev/null | awk '{printf "%d", $1}')
  if [ "${free:-0}" -lt 100 ]; then say "         $mp: VG $vg has no free space - add a disk to the VG first"; return 1; fi
  add=$(( need - av + 2048 )); [ "$add" -gt "$free" ] && add=$free
  ask "Extend $mp ($vg/$lv) by $(fmt_mb "$add")? (VG free: $(fmt_mb "$free"))" || return 1
  say "         -> lvextend -r -L +${add}M /dev/$vg/$lv"
  run lvextend -r -L "+${add}M" "/dev/$vg/$lv"
}

check_disk() {
  local mp av need use dev hint it ia low
  disk_measure
  # inodes cannot be fixed automatically
  while IFS='|' read -r mp av need use dev; do
    set -- $(df -Pi "$mp" 2>/dev/null | awk 'NR==2{print $2, $4}')
    it=${1:-0}; ia=${2:-0}
    case "$it$ia" in *[!0-9]*) continue ;; esac
    if [ "$it" -gt 0 ] && [ "$ia" -lt 5000 ]; then
      note "FAIL   disk $mp: only $ia free inodes"; status FAIL "inodes exhausted on $mp"; return 1
    fi
  done < "$TMP/disk"

  if [ -z "$(disk_low)" ]; then
    if [ -n "$(disk_full)" ] && [ "$DRY_RUN" != 1 ]; then
      clean_cache >/dev/null; disk_measure; note "INFO   disk >90% full, package cache cleaned"
    fi
    if [ -n "$(disk_full)" ]; then status WARN "$DISK_TXT (>90% used)"; else status OK "$DISK_TXT"; fi
    return 0
  fi

  low=$(disk_low | cut -d'|' -f1 | tr '\n' ' ')
  status WARN "low space on: $low($DISK_TXT)"
  if [ "$DRY_RUN" = 1 ]; then
    say "         (dry-run) would clean package cache, then ask for deeper cleanup / LVM extend"
    note "WARN   low disk space on: $low"; return 0
  fi

  clean_cache; disk_measure
  if [ -n "$(disk_low)" ] && ask "Deeper cleanup? (you choose old kernels, unused packages, logs >7 days, journal >200M)"; then
    clean_deep; disk_measure
  fi
  if [ -n "$(disk_low)" ]; then
    while IFS='|' read -r mp av need use dev; do
      lvm_extend "$mp" "$need" "$av" "$dev"
    done <<EOF
$(disk_low)
EOF
    disk_measure
  fi

  if [ -z "$(disk_low)" ]; then
    say "         ${C_G}disk OK now:${C_0} $DISK_TXT"; note "INFO   disk space fixed: $DISK_TXT"; return 0
  fi
  while IFS='|' read -r mp av need use dev; do
    case "$mp:$FAM" in
      /boot:yum) hint="remove old kernels: dnf remove --oldinstallonly" ;;
      /boot:apt) hint="remove old kernels: apt-get autoremove --purge" ;;
      *)         hint="free space or extend the partition" ;;
    esac
    note "FAIL   disk $mp: $(fmt_mb "$av") free, need $(fmt_mb "$need") -> $hint"
  done <<EOF
$(disk_low)
EOF
  if [ "$FORCE" = 1 ]; then say "         ${C_Y}still low, continuing (--force)${C_0}"; return 0; fi
  say "         ${C_R}still low: $DISK_TXT - stopping${C_0}"; return 1
}

build_core_yum() {
  local id names path key req en hit
  : > "$TMP/nexus-os.repo"
  core_yum > "$TMP/core"
  while IFS='|' read -r id names path key req en; do
    [ -z "$id" ] && continue
    hit=$(find_repo yum "$names" "$path" "$BASES_OS" 0)
    if [ -z "$hit" ]; then
      [ "$req" = 1 ] && { note "FAIL   $id: '$names' not found on Nexus"; return 1; }
      note "WARN   $id: '$names' not found on Nexus (skipped)"; continue
    fi
    echo "$hit" >> "$USED"
    { echo "[nx-$id]"; echo "name=$id (Nexus)"; echo "baseurl=$hit/"
      echo "enabled=$en"; echo "gpgcheck=1"; echo "proxy=_none_"
      [ -r "$key" ] && echo "gpgkey=file://$key"
      echo; } >> "$TMP/nexus-os.repo"
    N_CORE=$((N_CORE+1)); plan core "$id" "$hit"
  done < "$TMP/core"
}

build_3p_yum() {
  local f id en url gk mh hit n
  : > "$TMP/nexus-3p.repo"
  while IFS='|' read -r f id en url gk mh; do
    [ "$en" = 1 ] || continue
    id=${id#nx-}
    if [ -z "$url" ]; then off "$id" "no url in $f"; continue; fi
    if is_nexus "$url"; then
      hit=${url%/}
      if ! is_zone_url "$hit"; then
        n=${hit#*/repository/}; n=${n%%/*}
        is_old_core_name "$n" && { log "old core repo $id ($url) replaced by nexus-os.repo"; continue; }
        hit=$(zone_remap "${url%/}" yum) || hit=$(old_remap "${url%/}" yum) \
          || { off "$id" "old Nexus repo '$n' - no match on $ZONE Nexus, check by hand"; continue; }
        log "moved $id: $url -> $hit"
      fi
      probe "$hit" yum || { off "$id" "not found on Nexus ($hit)"; continue; }
    elif lookup yum_map "$url" && [ "$L_CANDS" = "-" ]; then
      off "$id" "internet-only repo, not mirrored on Nexus"; continue
    elif lookup yum_map "$url"; then
      hit=$(find_repo yum "$L_CANDS" "${L_PATH:-$(url_path "$url")}" "$BASES_3P" "$L_STRICT")
      [ -z "$hit" ] && { off "$id" "no matching Nexus repo, check by hand ($url)"; continue; }
    elif is_core_yum "$url"; then
      continue
    elif lookup yum_generic "$url"; then
      hit=$(find_repo yum "$L_CANDS" "$(url_path "$url")" "$BASES_3P" "$L_STRICT")
      [ -z "$hit" ] && { off "$id" "not found on Nexus ($url)"; continue; }
    else
      off "$id" "not on Nexus ($url)"; continue
    fi
    if grep -qxF "$hit" "$USED"; then log "dup $id -> $hit (skipped)"; continue; fi
    echo "$hit" >> "$USED"
    { echo "[nx-$id]"; echo "name=$id (Nexus)"; echo "baseurl=$hit/"
      echo "enabled=1"; echo "gpgcheck=1"; echo "proxy=_none_"
      [ -n "$gk" ] && gpg_keys "$id" "$gk" "$hit"
      [ -n "$mh" ] && echo "module_hotfixes=$mh"
      echo; } >> "$TMP/nexus-3p.repo"
    N_3P=$((N_3P+1)); plan 3p "$id" "$hit"
  done < "$TMP/sections"
}

# gpgkey line for a section: keep file:// keys, try to fetch remote keys
# through the same Nexus repo (saved to $TMP/keys, installed by apply_yum)
gpg_keys() { # id "keys" hit
  local id=$1 hit=$3 k s root r out="" n=0 f
  r=${hit#*/repository/}; r=${r%%/*}; root="${hit%%/repository/*}/repository/$r"
  for k in $(echo "$2" | tr ',' ' '); do
    case "$k" in
      file://*) out="$out $k"; continue ;;
    esac
    n=$((n+1)); f="RPM-GPG-KEY-nx-$id${n#1}"
    mkdir -p "$TMP/keys"
    for s in $(suffixes "$(url_path "$k")"); do
      curl -s --noproxy '*' -m "$TIMEOUT" -o "$TMP/keys/$f" "$root/$s" 2>/dev/null
      if grep -q 'BEGIN PGP PUBLIC KEY' "$TMP/keys/$f" 2>/dev/null; then
        out="$out file:///etc/pki/rpm-gpg/$f"; log "gpg key for $id fetched from $root/$s"
        command -v gpg >/dev/null 2>&1 && note "INFO   $id: new GPG key $(gpg --batch --show-keys --with-colons "$TMP/keys/$f" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}') - verify with vendor fingerprint"
        break
      fi
      rm -f "$TMP/keys/$f"
    done
    [ -e "$TMP/keys/$f" ] || note "WARN   $id: GPG key $k not reachable via Nexus - must already be imported (rpm -qa gpg-pubkey)"
  done
  [ -n "$out" ] && echo "gpgkey=${out# }"
  return 0
}

disable_yum_file() {
  awk '/^\[/ { print; print "enabled=0"; next }
       /^[ \t]*enabled[ \t]*=/ { next }
       { print }' "$1" > "$1.nx" && cat "$1.nx" > "$1" && rm -f "$1.nx"
}

apply_yum() {
  local f
  mkdir -p "$BAK_DIR" && cp -a /etc/yum.repos.d "$BAK_DIR/" || return 1
  for f in /etc/yum.repos.d/*.repo; do
    case "$f" in */nexus-os.repo|*/nexus-3p.repo) continue ;; esac
    [ -e "$f" ] && disable_yum_file "$f"
  done
  cp "$TMP/nexus-os.repo" /etc/yum.repos.d/nexus-os.repo
  [ -d "$TMP/keys" ] && cp "$TMP/keys"/* /etc/pki/rpm-gpg/ 2>/dev/null
  if [ -s "$TMP/nexus-3p.repo" ]; then cp "$TMP/nexus-3p.repo" /etc/yum.repos.d/nexus-3p.repo
  else rm -f /etc/yum.repos.d/nexus-3p.repo; fi
  chmod 644 /etc/yum.repos.d/nexus-*.repo
}

restore_yum() {
  log "rolling back /etc/yum.repos.d"
  rm -f /etc/yum.repos.d/*.repo
  cp -a "$BAK_DIR/yum.repos.d/." /etc/yum.repos.d/
}

# ---------------------------------------------------------------- update level
# Fill these from the package manager's own data (no internet needed):
#   SEV_CRIT SEV_IMP SEV_MOD SEV_LOW  : security updates per severity (OL/Rocky)
#   SEV_SEC                           : security updates total
#   SEV_OTHER                         : non-security updates
#   SEV_GRADED                        : 1 if this OS/repo exposes severity
LEVEL_OK=""
classify_updates() {
  [ -n "$LEVEL_OK" ] && return 0
  SEV_CRIT=0; SEV_IMP=0; SEV_MOD=0; SEV_LOW=0; SEV_SEC=0; SEV_OTHER=0; SEV_GRADED=0
  LEVEL_OK=1
  if [ "$FAM" = yum ]; then
    local PM; PM=$(yum_pm)
    # updateinfo summary: lines like "    4 Security notice(s)" / "Critical: 3"
    $PM -q $YUM_OPTS updateinfo summary 2>/dev/null > "$TMP/ui" || true
    SEV_CRIT=$(awk -F: '/[Cc]ritical/ {gsub(/[^0-9]/,"",$1); s+=$1} END{print s+0}' "$TMP/ui")
    SEV_IMP=$(awk -F: '/[Ii]mportant/ {gsub(/[^0-9]/,"",$1); s+=$1} END{print s+0}' "$TMP/ui")
    SEV_MOD=$(awk -F: '/[Mm]oderate/ {gsub(/[^0-9]/,"",$1); s+=$1} END{print s+0}' "$TMP/ui")
    SEV_LOW=$(awk -F: '/[Ll]ow/ {gsub(/[^0-9]/,"",$1); s+=$1} END{print s+0}' "$TMP/ui")
    # list of security-relevant package updates vs all
    $PM -q $YUM_OPTS --security check-update 2>/dev/null | awk 'NF>=3 && $1 ~ /\./{n++} END{print n+0}' > "$TMP/sc" || echo 0 > "$TMP/sc"
    SEV_SEC=$(cat "$TMP/sc")
    local allc; allc=$($PM -q $YUM_OPTS check-update 2>/dev/null | awk 'NF>=3 && $1 ~ /\./{n++} END{print n+0}')
    SEV_OTHER=$(( allc - SEV_SEC )); [ "$SEV_OTHER" -lt 0 ] && SEV_OTHER=0
    [ $((SEV_CRIT+SEV_IMP+SEV_MOD+SEV_LOW)) -gt 0 ] && SEV_GRADED=1
    # security count but no severity graded -> repo has security flag but no severity
    [ "$SEV_GRADED" = 0 ] && [ "$SEV_SEC" -gt 0 ] && note "WARN   level: security updates found but no per-severity data on this OS/repo - critical/important fall back to all-security"
  elif [ "$FAM" = apt ]; then
    apt-get -s $APT_OPTS upgrade 2>/dev/null | awk '/^Inst /{print}' > "$TMP/inst" || true
    SEV_SEC=$(grep -ciE 'security|-security|esm' "$TMP/inst")
    SEV_OTHER=$(( $(grep -c '^Inst' "$TMP/inst") - SEV_SEC )); [ "$SEV_OTHER" -lt 0 ] && SEV_OTHER=0
    SEV_GRADED=0   # apt has no per-CVE severity
  fi
}

# resolve LEVEL + the OS-specific option to pass to the upgrade command -> SEC_OPT
# echoes a human label; sets SEC_OPT and SEC_MODE (sec|full|none)
apply_level() {
  SEC_OPT=""; SEC_MODE=sec
  case "$LEVEL" in
    full)  SEC_MODE=full; LVL_TXT="all updates" ; return ;;
    none)  SEC_MODE=none; LVL_TXT="nothing (report only)"; return ;;
  esac
  if [ "$FAM" = yum ]; then
    case "$LEVEL" in
      critical)  [ "$SEV_GRADED" = 1 ] && { SEC_OPT="--security --sec-severity=Critical"; LVL_TXT="critical only"; }                                        || { SEC_OPT="--security"; LVL_TXT="all security (no severity data)"; } ;;
      important) [ "$SEV_GRADED" = 1 ] && { SEC_OPT="--security --sec-severity=Critical --sec-severity=Important"; LVL_TXT="critical+important"; }                                        || { SEC_OPT="--security"; LVL_TXT="all security (no severity data)"; } ;;
      *)         SEC_OPT="--security"; LVL_TXT="all security" ;;
    esac
  else
    # apt: only security vs full; critical/important collapse to security
    case "$LEVEL" in
      critical|important) LVL_TXT="all security (Ubuntu has no per-severity data)" ;;
      *) LVL_TXT="all security" ;;
    esac
    SEC_OPT="__APT_SECURITY__"   # handled in upgrade_apt (origins filter)
  fi
}

# extra guard for the "everything" choice; 0 = go ahead, 1 = go back to menu
confirm_full() {
  [ "$LEVEL" = full ] || return 0
  [ "$INTERACTIVE" = 1 ] && [ "$ASSUME_YES" != 1 ] || return 0
  local a
  say ""
  say "  ${C_Y}WARNING: a full upgrade updates ALL packages, not just security.${C_0}"
  say "  ${C_Y}On a database or app server this can cause conflicts or change${C_0}"
  say "  ${C_Y}service behaviour. 'security' is the safer choice.${C_0}"
  printf '  Really do a full upgrade? [y/N]: ' >&2; read -r a < /dev/tty
  echo "  full-upgrade confirm: ${a:-<empty>}" >> "$SUM"
  case "$a" in y|Y|yes|YES) return 0 ;; *) say "  -> back to menu"; return 1 ;; esac
}

level_menu() {
  local ans graded
  classify_updates
  graded=$SEV_GRADED
  say ""
  if [ "$FAM" = yum ] && [ "$graded" = 1 ]; then
    say "  Updates:  ${C_R}Critical: $SEV_CRIT${C_0}  ${C_Y}Important: $SEV_IMP${C_0}  Moderate: $SEV_MOD  Low: $SEV_LOW  |  other (non-security): $SEV_OTHER"
  else
    say "  Updates:  ${C_Y}security: $SEV_SEC${C_0}  (no per-severity data)  |  other (non-security): $SEV_OTHER"
  fi
  if [ "$ASSUME_YES" = 1 ] || [ "$INTERACTIVE" != 1 ]; then
    [ -n "$LEVEL" ] || LEVEL=security
    return 0
  fi
  if [ "$FAM" = yum ] && [ "$graded" = 1 ]; then
    say "  What to install?"
    say "    1) Critical only       2) Critical + Important"
    say "    3) all security (recommended)   4) everything   5) nothing"
    printf '  Choose [1-5] (Enter = 3): ' >&2; read -r ans < /dev/tty
    case "$ans" in 1) LEVEL=critical ;; 2) LEVEL=important ;; 4) LEVEL=full ;; 5) LEVEL=none ;; *) LEVEL=security ;; esac
    confirm_full || { LEVEL=""; LEVEL_OK=1; level_menu; return 0; }
  else
    say "  What to install?"
    say "    1) security only (recommended)   2) everything   3) nothing"
    printf '  Choose [1-3] (Enter = 1): ' >&2; read -r ans < /dev/tty
    case "$ans" in 2) LEVEL=full ;; 3) LEVEL=none ;; *) LEVEL=security ;; esac
    confirm_full || { LEVEL=""; LEVEL_OK=1; level_menu; return 0; }
  fi
  echo "  update level chosen: $LEVEL" >> "$SUM"
}

YUM_OPTS="--setopt=timeout=300 --setopt=minrate=1"
yum_pm() { if command -v dnf >/dev/null 2>&1; then echo dnf; else echo yum; fi; }

refresh_yum() {
  local PM try=0 rc=1 ids id core=0 n=0
  PM=$(yum_pm)
  run $PM -q clean all
  while [ $try -lt 6 ]; do
    try=$((try+1))
    run_progress spin $PM -y --setopt=timeout=60 --setopt=minrate=1 makecache; rc=$?; cp "$TMP/prog.out" "$TMP/yumout"
    [ $rc -eq 0 ] && break
    ids=$(grep -oE "for repo '[^']+'|from [A-Za-z0-9_.:-]+: \[Errno" "$TMP/yumout" \
          | sed -E "s/^for repo '//; s/'$//; s/^from //; s/: \[Errno$//" | sort -u)
    [ -n "$ids" ] || break
    for id in $ids; do
      if grep -qxF "[$id]" /etc/yum.repos.d/nexus-os.repo 2>/dev/null; then core=1; break
      elif grep -qxF "[$id]" /etc/yum.repos.d/nexus-3p.repo 2>/dev/null; then
        awk -v S="[$id]" 'index($0,"[")==1 { ins = ($0 == S) } ins && /^enabled=/ { print "enabled=0"; next } { print }' \
          /etc/yum.repos.d/nexus-3p.repo > "$TMP/3p.new" && cat "$TMP/3p.new" > /etc/yum.repos.d/nexus-3p.repo
        off "${id#nx-}" "metadata error on Nexus, auto-disabled"; [ "$N_3P" -gt 0 ] && N_3P=$((N_3P-1)); n=$((n+1))
      else core=1; break
      fi
    done
    [ $core = 1 ] && break
  done
  if [ $rc -eq 0 ]; then
    if [ $n -gt 0 ]; then status WARN "OK, $n broken repo(s) auto-disabled"; else status OK "metadata downloaded"; fi
    return 0
  fi
  restore_yum; run $PM -q clean all
  note "FAIL   metadata download failed (core repo) - original repo files restored"
  status FAIL "rolled back"; return 1
}

# section ids in nexus-*.repo whose baseurl lives in Nexus repo "$1"
repo_ids_for_name() {
  awk -v N="/repository/$1" '/^\[/ { id = substr($0, 2, length($0) - 2) }
    /^baseurl=/ { u = $0; sub(/\/+$/, "", u); if (index(u "/", N "/")) print id }' \
    /etc/yum.repos.d/nexus-os.repo /etc/yum.repos.d/nexus-3p.repo 2>/dev/null
}

# a dependency conflict was hit; show context and ask whether to use --nobest
nobest_prompt() {
  local pkgs exf a
  pkgs=$(grep -oE 'cannot install the best update candidate for package [^ ]+' "$TMP/upg.out" \
         | sed 's/.*package //' | sort -u | tr '\n' ' ')
  [ -n "$pkgs" ] || pkgs=$(grep -oE 'package [^ ]+ from' "$TMP/upg.out" | awk '{print $2}' | sort -u | head -3 | tr '\n' ' ')
  say ""
  say "  ${C_Y}Package conflict - some packages cannot reach their best version:${C_0}"
  say "    ${pkgs:-see full log}"
  # a kernel 'exclude' is the usual cause: find it and show file + mtime
  if grep -q 'filtered out by exclude' "$TMP/upg.out"; then
    exf=$(grep -rlE '^[[:space:]]*exclude=' /etc/dnf/dnf.conf /etc/yum.conf /etc/yum.repos.d/ 2>/dev/null | head -1)
    if [ -n "$exf" ]; then
      say "  Cause: kernel/packages are pinned by 'exclude=' in:"
      say "    $exf   (last modified: $(stat -c '%y' "$exf" 2>/dev/null | cut -d. -f1))"
      grep -nE '^[[:space:]]*exclude=' "$exf" 2>/dev/null | head -1 | sed 's/^/    /' | while read -r l; do say "    $l"; done
    fi
    command -v history >/dev/null 2>&1 && history 2>/dev/null | grep -E 'exclude|dnf.conf' | tail -2 | while read -r l; do say "    (history) $l"; done
  fi
  if [ "$ASSUME_YES" = 1 ] || [ "$INTERACTIVE" != 1 ]; then
    say "  -> non-interactive: NOT retrying with --nobest (run by hand, or add --nobest)"; return 1
  fi
  printf '  Retry with --nobest (install what can be installed, skip the conflict)? [y/N]: ' >&2
  read -r a < /dev/tty; echo "  nobest confirm: ${a:-<empty>}" >> "$SUM"
  case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

upgrade_yum() {
  local PM EX="" p rc try=0 ids id n dis="" pk gk f ng
  PM=$(yum_pm)
  set -f; for p in $EXCLUDE; do EX="$EX --exclude=$p"; done; set +f
  while :; do
    try=$((try+1))
    run_progress yum $PM -y $YUM_OPTS $SEC_OPT upgrade $EX $dis; rc=$?
    cp "$TMP/prog.out" "$TMP/upg.out"
    [ $rc -eq 0 ] && break
    # dependency conflict (not a download/key problem) -> offer --nobest
    if grep -qE 'but none of the providers can be installed|cannot install the best update|is filtered out by exclude|requires .* but|Problem:' "$TMP/upg.out" \
       && ! grep -qE 'Status code: [0-9]|Public key for|\[FAILED\]' "$TMP/upg.out"; then
      case " $dis " in
        *" --nobest "*) note "FAIL   upgrade still fails after --nobest - see full log"; break ;;
        *) if nobest_prompt; then dis="$dis --nobest --skip-broken"; log "retrying with --nobest"; continue
           else note "WARN   package conflict - left for manual handling (--nobest declined)"; break; fi ;;
      esac
    fi
    [ $try -ge 4 ] && break
    # packages that could not be downloaded -> which Nexus repo
    ids=""
    for n in $(grep -oE "Status code: [0-9]+ for https?://[^ ]+" "$TMP/upg.out" \
               | grep -oE '/repository/[^/]+' | sed 's#/repository/##' | sort -u); do
      ids="$ids $(repo_ids_for_name "$n" | tr '\n' ' ')"
    done
    ids="$ids $(grep -oE 'from [A-Za-z0-9_.:-]+: \[Errno' "$TMP/upg.out" | sed -E 's/^from //; s/: \[Errno$//' | sort -u | tr '\n' ' ')"
    pk=$(grep -oE '\[FAILED\] [^:]+' "$TMP/upg.out" | sed 's/\[FAILED\] //' | sort -u | tr '\n' ' ')
    # "Public key for X.rpm is not installed" -> repo of X from the transaction table
    gk=""; ng=0
    for f in $(grep -oE 'Public key for [^ ]+ is not installed' "$TMP/upg.out" | awk '{print $4}'); do
      gk="$gk $(awk -v F="$f" 'NF >= 5 && $4 ~ /^nx-/ { v = $3; sub(/^[0-9]+:/, "", v); if (index(F, $1 "-" v ".") == 1) { print $4; exit } }' "$TMP/upg.out")"
    done
    gk=$(echo $gk | tr ' ' '\n' | sort -u | tr '\n' ' ')
    for id in $gk; do
      case " $dis " in *" --disablerepo=$id "*) continue ;; esac
      grep -qxF "[$id]" /etc/yum.repos.d/nexus-os.repo 2>/dev/null && { note "FAIL   core repo ${id#nx-}: GPG key not installed"; return $rc; }
      dis="$dis --disablerepo=$id"; ng=1
      UPG_SKIPPED="$UPG_SKIPPED ${id#nx-}"
      note "WARN   ${id#nx-}: GPG key not installed on server, repo skipped in this upgrade - import the vendor key (rpm --import <key>) and run again"
    done
    n=0
    [ "$ng" = 1 ] && n=1
    for id in $ids; do
      case " $dis " in *" --disablerepo=$id "*) continue ;; esac
      grep -qxF "[$id]" /etc/yum.repos.d/nexus-os.repo 2>/dev/null && { note "FAIL   core repo ${id#nx-}: packages missing on Nexus: $pk"; return $rc; }
      dis="$dis --disablerepo=$id"; n=1
      UPG_SKIPPED="$UPG_SKIPPED ${id#nx-}"
      note "WARN   ${id#nx-}: packages missing on Nexus (404), repo skipped in this upgrade: ${pk:-?}"
    done
    [ $n = 1 ] || break
    case " $dis " in *" --skip-broken "*) ;; *) dis="$dis --skip-broken" ;; esac
    log "retrying upgrade with:$dis"
  done
  return $rc
}

reboot_need_yum() {
  local p
  if command -v needs-restarting >/dev/null 2>&1; then
    needs-restarting -r >/dev/null 2>&1; [ $? -eq 1 ] && RBR=yes; return 0
  fi
  p=$(ls -t /boot/vmlinuz-* 2>/dev/null | grep -v rescue | head -1)
  [ -n "$p" ] && [ "$p" != "/boot/vmlinuz-$(uname -r)" ] && RBR=yes
  return 0
}

# ---------------------------------------------------------------- APT
is_core_apt() { # uri suite
  case "$1" in
    *archive.ubuntu.com*|*security.ubuntu.com*|*ports.ubuntu.com*) return 0 ;;
    *deb.debian.org*|*security.debian.org*|*ftp*.debian.org*) return 0 ;;
  esac
  # local mirrors: http://mirror/ubuntu  jammy...  (one path segment only, not PPAs)
  case "$(url_path "$1"):$2" in
    ubuntu:"$OS_CODE"*|debian:"$OS_CODE"*|debian-security:"$OS_CODE"*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------- Ubuntu ESM
# Pro / ESM security patches come from a token-authenticated repo that the new
# Nexus proxies as "ubuntu-esm-aio". When that repo actually serves data
# (Nexus token OK), build an apt source so the patches get installed. Until
# then, just report - no broken source is written.
#
# Suites to try, newest naming first. If the Nexus admin uses a different
# suite name, add it here (space separated, one word each).
# the ESM repo holds two branches, each a full ESM tree:
#   <repo>/infra/ubuntu/dists/<codename>-infra-security
#   <repo>/apps/ubuntu/dists/<codename>-apps-security
# ESM_BRANCHES: "<branch-path>|<suite-suffixes>|<keyring>|<keyfile-in-pro-client>"
# The two branches are signed by different ESM keys (not the ubuntu-archive key).
ESM_REPO="ubuntu-esm-infra-aio"
ESM_BRANCHES='ubuntu-esm-infra-aio/infra/ubuntu|infra-security infra-updates|ubuntu-pro-esm-infra.gpg|ubuntu-pro-esm-infra.gpg
ubuntu-esm-apps-aio/apps/ubuntu|apps-security apps-updates|ubuntu-pro-esm-apps.gpg|ubuntu-pro-esm-apps.gpg'

esm_base() {
  local b
  for b in $BASES_3P; do
    [ "$(http_code "$b/$ESM_REPO/")" = 200 ] && { echo "$b/$ESM_REPO"; return 0; }
  done
  return 1
}

# make sure an ESM keyring is on the server; try (1) Nexus repo root, then
# (2) extract it from the ubuntu-pro-client .deb on Nexus. echo its path or fail.
KEYDIR=/usr/share/keyrings
ESM_PKG_DIR=""
esm_get_key() {
  local kf=$1 b url deb dst stg
  dst="$KEYDIR/$kf"; stg="$TMP/esmkeys/$kf"; mkdir -p "$TMP/esmkeys"
  [ -s "$dst" ] && { echo "$dst"; return 0; }
  [ "$DRY_RUN" = 1 ] && { echo "$dst"; return 0; }   # dry-run: assume it will be there
  # Only source: the ubuntu-pro-client package. apt-get download checks its
  # hash against the signed Ubuntu index, so the key inside is trusted.
  # (a key file fetched as-is over HTTP would not be verified - not used)
  if [ -z "$ESM_PKG_DIR" ]; then
    ESM_PKG_DIR=$TMP/pro
    mkdir -p "$ESM_PKG_DIR"
    if ( cd "$ESM_PKG_DIR" && run apt-get download ubuntu-pro-client ) && ls "$ESM_PKG_DIR"/ubuntu-pro-client*.deb >/dev/null 2>&1; then
      run dpkg-deb -x "$ESM_PKG_DIR"/ubuntu-pro-client*.deb "$ESM_PKG_DIR/x"
    else
      log "ESM: could not download ubuntu-pro-client"
    fi
  fi
  if [ -s "$ESM_PKG_DIR/x/usr/share/keyrings/$kf" ]; then
    cp "$ESM_PKG_DIR/x/usr/share/keyrings/$kf" "$stg"
    log "ESM key $kf from ubuntu-pro-client package"; echo "$dst"; return 0
  fi
  return 1
}

handle_esm() {
  local base bpath sufs kf keyf kr url s n=0 have_src f miss=0
  [ "$KEY" = ubuntu ] || return 0

  have_src=0
  grep -rilE 'esm\.ubuntu\.com|ubuntu-esm' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep -q . && have_src=1

  base=$(esm_base) || { note "WARN   ESM: no '$ESM_REPO' repo on $ZONE Nexus - ESM security patches unavailable (ask Nexus admin)"; return 0; }

  : > "$TMP/nexus-esm.list"
  # each branch: own base path, own suites, own signing key (fetched if missing)
  while IFS='|' read -r bpath sufs kr kf; do
    [ -n "$bpath" ] || continue
    url="${base%/*}/$bpath"
    probe "$url" apt "$OS_CODE-${sufs%% *}" || url="${url%/*/*}"
    # resolve the signing key for this branch
    if keyf=$(esm_get_key "$kf"); then :; else
      note "WARN   ESM: signing key $kf not found (Nexus or ubuntu-pro-client) - $bpath skipped, patches from it NOT installed"
      miss=1; continue
    fi
    for s in $sufs; do
      probe "$url" apt "$OS_CODE-$s" || continue
      echo "deb [signed-by=$keyf] $url $OS_CODE-$s main" >> "$TMP/nexus-esm.list"
	  echo "$url" >> "$USED"
      n=$((n+1)); plan core "ESM $OS_CODE-$s" "$url"
    done
  done <<EOF
$ESM_BRANCHES
EOF

  if [ "$n" -eq 0 ]; then
    note "WARN   ESM: '$ESM_REPO' on $ZONE Nexus serves no suite for $OS_CODE (Nexus token/config problem?) - ESM patches NOT installed, contact Nexus admin"
    [ "$have_src" = 1 ] && note "INFO   ESM: server has its own esm source, but the $ZONE Nexus repo returns no data"
    return 0
  fi
  ESM_LIST=1
  note "INFO   ESM: $n suite(s) available on $ZONE Nexus -> esm source created, security patches will be installed"
  [ "$miss" = 1 ] && note "WARN   ESM: some branches were skipped for a missing key - see above"

  if [ "$have_src" = 1 ]; then
    for f in $(grep -rilE 'esm\.ubuntu\.com' /etc/apt/sources.list.d/ 2>/dev/null); do
      case "$f" in */nexus-esm.list) continue ;; esac
      echo "$f" >> "$TMP/esm_off"   # disabled in apply_apt, after the backup
      note "INFO   ESM: replaced token-based source $(basename "$f") with the Nexus source"
    done
  fi
}

build_core_apt() {
  local main mpath sec spath comp kr opt hit s
  [ -n "$OS_CODE" ] || { note "FAIL   codename unknown"; return 1; }
  if [ "$KEY" = ubuntu ]; then
    main=ubuntu-archive; mpath=""; sec=ubuntu-security; spath=""
    comp="main restricted universe multiverse"; kr=/usr/share/keyrings/ubuntu-archive-keyring.gpg
  else
    main=debian-archive; mpath=""; sec=debian-security; spath=""
    comp="main contrib non-free"; [ "${MAJOR:-0}" -ge 12 ] 2>/dev/null && comp="$comp non-free-firmware"
    kr=/usr/share/keyrings/debian-archive-keyring.gpg
  fi
  opt=""; [ -r "$kr" ] && opt="[signed-by=$kr] "; CORE_NAMES="$main $sec"   # + OLD_CORE_NAMES patterns (see is_core_nexus)
  : > "$TMP/nexus-os.list"
  hit=$(find_repo apt "$main" "$mpath" "$BASES_OS" 0 "$OS_CODE")
  [ -z "$hit" ] && { note "FAIL   $main/$OS_CODE not found on Nexus"; return 1; }
  echo "deb $opt$hit $OS_CODE $comp" >> "$TMP/nexus-os.list"; echo "$hit" >> "$USED"
  N_CORE=$((N_CORE+1)); plan core "$OS_CODE" "$hit"
  for s in updates backports; do
    if probe "$hit" apt "$OS_CODE-$s"; then
      echo "deb $opt$hit $OS_CODE-$s $comp" >> "$TMP/nexus-os.list"
      N_CORE=$((N_CORE+1)); plan core "$OS_CODE-$s" "$hit"
    else note "WARN   $OS_CODE-$s not on Nexus (skipped)"; fi
  done
  hit=$(find_repo apt "$sec" "$spath" "$BASES_OS" 0 "$OS_CODE-security")
  if [ -n "$hit" ]; then
    echo "deb $opt$hit $OS_CODE-security $comp" >> "$TMP/nexus-os.list"; echo "$hit" >> "$USED"
    N_CORE=$((N_CORE+1)); plan core "$OS_CODE-security" "$hit"
  else note "WARN   $OS_CODE-security not on Nexus - NO SECURITY UPDATES"; fi
}

CORE_NAMES=""
# nexus URL whose repo name is one of the core OS repos (any path / suite)
is_core_nexus() { local n=${1#*/repository/}; n=${n%%/*}; case " $CORE_NAMES " in *" $n "*) return 0 ;; esac; is_old_core_name "$n"; }

# one-line .list file -> new content on stdout
process_list() {
  local f=$1 line typ opts uri suite comps hit fs
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in deb\ *|deb-src\ *) ;; *) echo "$line"; continue ;; esac
    set -f; set -- $line; set +f
    typ=$1; shift; opts=""
    case "$1" in \[*)
      while [ $# -gt 0 ]; do opts="$opts $1"; case "$1" in *\]) shift; break ;; esac; shift; done ;;
    esac
    uri=${1:-}; suite=${2:-}; shift 2 2>/dev/null; comps="$*"
    case "$opts" in *trusted=yes*) note "WARN   $(basename "$f"): '$uri $suite' has [trusted=yes] - apt does NOT check its signature" ;; esac
    if is_nexus "$uri" && { grep -qxF "${uri%/}" "$USED" || is_core_nexus "$uri"; }; then
      echo "# replaced by nexus-os.list $TS: $line"; N_REPL=$((N_REPL+1)); continue
    fi
    if is_nexus "$uri" && ! is_zone_url "$uri"; then
      if hit=$(zone_remap "$uri" apt "$suite") || hit=$(old_remap "$uri" apt "$suite"); then
        echo "# moved to $ZONE Nexus by server_update $TS: $line"
        uri=$hit; line="$typ$opts $uri $suite $comps"
      else
        off "$uri $suite" "Nexus of another zone, repo not on $ZONE Nexus"
        echo "# disabled by server_update $TS: $line"; continue
      fi
    fi
    if ! is_core_apt "$uri" "$suite" && suite_bad "$suite"; then
      fs="$OS_CODE${suite#${suite%%-*}}"
      if is_nexus "$uri" && grep -qxF "${uri%/} $fs" "$TMP/kept"; then
        echo "# duplicate, disabled by server_update $TS: $line"; N_DUP=$((N_DUP+1)); continue
      fi
      if is_nexus "$uri" && probe "${uri%/}" apt "$fs"; then
        echo "${uri%/} $fs" >> "$TMP/kept"
        echo "# old release, replaced by server_update $TS: $line"
        echo "$typ$opts $uri $fs $comps"; N_3P=$((N_3P+1)); plan fix "$suite -> $fs" "${uri%/}"; continue
      fi
      off "$uri $suite" "wrong release, server is $OS_CODE"; echo "# disabled by server_update $TS: $line"; continue
    fi
    if is_nexus "$uri"; then
      if grep -qxF "${uri%/} $suite" "$TMP/kept"; then
        echo "# duplicate, disabled by server_update $TS: $line"; N_DUP=$((N_DUP+1))
      elif probe "${uri%/}" apt "$suite"; then
        echo "${uri%/} $suite" >> "$TMP/kept"
        echo "$line"; N_3P=$((N_3P+1)); plan keep "$suite" "${uri%/}"
      else
        off "$uri $suite" "not found on Nexus"; echo "# disabled by server_update $TS: $line"
      fi
      continue
    fi
    if lookup apt_map "$uri"; then
      hit=$(find_repo apt "$L_CANDS" "$(url_path "$uri")" "$BASES_3P" "$L_STRICT" "$suite")
      if [ -n "$hit" ]; then
        echo "$typ$opts $hit $suite $comps"; N_3P=$((N_3P+1)); plan 3p "$suite" "$hit"; continue
      fi
      off "$uri $suite" "no matching Nexus repo, check by hand"
    elif ! is_core_apt "$uri" "$suite"; then
      off "$uri $suite" "not on Nexus"
    fi
    echo "# disabled by server_update $TS: $line"
  done < "$f"
}

# deb822 .sources file -> new content on stdout
process_sources() {
  local f=$TMP/src.lf uri suite hit
  tr -d '\r' < "$1" > "$f"
  uri=$(awk 'tolower($1)=="uris:"{print $2; exit}' "$f")
  suite=$(awk 'tolower($1)=="suites:"{print $2; exit}' "$f")
  if is_nexus "$uri" && { grep -qxF "${uri%/}" "$USED" || is_core_nexus "$uri"; }; then
    N_REPL=$((N_REPL+1)); sed -e '/^Enabled:/Id' -e 's/^Types:/Enabled: no\nTypes:/' "$f"; return
  fi
  if is_nexus "$uri" && ! is_zone_url "$uri"; then
    if hit=$(zone_remap "$uri" apt "$suite") || hit=$(old_remap "$uri" apt "$suite"); then
      sed -i "s#^URIs:.*#URIs: $hit#I" "$f"; uri=$hit
    else
      off "$uri $suite" "Nexus of another zone, repo not on $ZONE Nexus"
      sed -e '/^Enabled:/Id' -e 's/^Types:/Enabled: no\nTypes:/' "$f"; return
    fi
  fi
  if ! is_core_apt "$uri" "$suite" && suite_bad "$suite"; then
    off "$uri $suite" "wrong release, server is $OS_CODE"
    sed -e '/^Enabled:/Id' -e 's/^Types:/Enabled: no\nTypes:/' "$f"; return
  fi
  if is_nexus "$uri"; then
    if probe "${uri%/}" apt "$suite"; then cat "$f"; N_3P=$((N_3P+1)); plan keep "$suite" "${uri%/}"
    else off "$uri $suite" "not found on Nexus"; sed -e '/^Enabled:/Id' -e 's/^Types:/Enabled: no\nTypes:/' "$f"; fi
    return
  fi
  if ! is_core_apt "$uri" "$suite" && lookup apt_map "$uri"; then
    hit=$(find_repo apt "$L_CANDS" "$(url_path "$uri")" "$BASES_3P" "$L_STRICT" "$suite")
    if [ -n "$hit" ]; then
      sed "s#^URIs:.*#URIs: $hit#I" "$f"; N_3P=$((N_3P+1)); plan 3p "$suite" "$hit"; return
    fi
    off "$uri $suite" "no matching Nexus repo, check by hand"
  elif ! is_core_apt "$uri" "$suite"; then
    off "$uri $suite" "not on Nexus"
  fi
  sed -e '/^Enabled:/Id' -e 's/^Types:/Enabled: no\nTypes:/' "$f"
}

build_3p_apt() {
  local f i=0
  mkdir -p "$TMP/apt"; : > "$TMP/apt.map"
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -e "$f" ] || continue
    case "$f" in */nexus-os.list) continue ;; esac
    i=$((i+1))
    case "$f" in
      *.sources) process_sources "$f" > "$TMP/apt/$i" ;;
      *)         process_list    "$f" > "$TMP/apt/$i" ;;
    esac
    echo "$f|$TMP/apt/$i" >> "$TMP/apt.map"
  done
}

apply_apt() {
  local f t h
  mkdir -p "$BAK_DIR" || return 1
  cp -a /etc/apt/sources.list.d "$BAK_DIR/" || return 1
  [ -e /etc/apt/sources.list ] && cp -a /etc/apt/sources.list "$BAK_DIR/"
  [ -e /etc/apt/apt.conf.d/99server-update-nexus ] && cp -a /etc/apt/apt.conf.d/99server-update-nexus "$BAK_DIR/"
  while IFS='|' read -r f t; do cat "$t" > "$f"; done < "$TMP/apt.map"
  # ESM: signing keys fetched during the plan, old token-based esm sources
  if [ -d "$TMP/esmkeys" ]; then
    for t in "$TMP/esmkeys"/*; do [ -s "$t" ] && install -m 644 "$t" "$KEYDIR/"; done
  fi
  if [ -s "$TMP/esm_off" ]; then
    while IFS= read -r f; do sed -i 's/^deb /# disabled by server_update '"$TS"': deb /' "$f"; done < "$TMP/esm_off"
  fi
  cp "$TMP/nexus-os.list" /etc/apt/sources.list.d/nexus-os.list
  if [ "${ESM_LIST:-0}" = 1 ] && [ -s "$TMP/nexus-esm.list" ]; then
    cp "$TMP/nexus-esm.list" /etc/apt/sources.list.d/nexus-esm.list; chmod 644 /etc/apt/sources.list.d/nexus-esm.list
  fi
  # Nexus is internal: never through a proxy
  for h in $NX_HOSTS; do echo "Acquire::http::Proxy::${h%%:*} \"DIRECT\";"; done > /etc/apt/apt.conf.d/99server-update-nexus
  chmod 644 /etc/apt/sources.list.d/nexus-os.list
}

restore_apt() {
  log "rolling back /etc/apt sources"
  rm -f /etc/apt/sources.list.d/* /etc/apt/apt.conf.d/99server-update-nexus
  cp -a "$BAK_DIR/sources.list.d/." /etc/apt/sources.list.d/
  [ -e "$BAK_DIR/sources.list" ] && cp -a "$BAK_DIR/sources.list" /etc/apt/sources.list
  [ -e "$BAK_DIR/99server-update-nexus" ] && cp -a "$BAK_DIR/99server-update-nexus" /etc/apt/apt.conf.d/
}

APT_OPTS="-o APT::Get::Always-Include-Phased-Updates=true -o Acquire::http::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
export DEBIAN_FRONTEND=noninteractive

KNOWN_CODES="xenial bionic focal jammy kinetic lunar mantic noble oracular plucky questing resolute buster bullseye bookworm trixie forky"
suite_bad() { local b=${1%%-*}; case " $KNOWN_CODES " in *" $b "*) [ "$b" != "$OS_CODE" ] ;; *) return 1 ;; esac; }
is_core_url() { local c; while read -r c; do [ -n "$c" ] && case "$1" in "$c"*) return 0 ;; esac; done < "$USED"; return 1; }

# short human reason for a failing source URL
apt_reason() {
  local k
  k=$(grep -F "$1" "$TMP/aptupd" | grep -oE 'NO_PUBKEY [0-9A-F]+' | head -1)
  if [ -n "$k" ]; then echo "GPG key missing on server ($k) - import key, then re-enable"; return; fi
  awk -v U="$1" 'index($0, U) && /^Err:/ { getline nx; sub(/^[ \t]+/, "", nx); print nx; exit }' "$TMP/aptupd" | cut -c1-90 | grep . && return
  grep -F "$1" "$TMP/apterr" | head -1 | sed 's/^E: //' | cut -c1-100
}

# disable every source line whose URI is a prefix of $1
disable_apt_url() {
  local u=$1 f p hit=0
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [ -e "$f" ] || continue
    case "$f" in */nexus-os.list) continue ;; esac
    if awk -v U="$u" -v T="# disabled by server_update (apt error): " '
      { sub(/\r$/, ""); s = $0; sub(/^[ \t]+/, "", s) }
      s ~ /^deb(-src)?[ \t]/ {
        n = split(s, a, /[ \t]+/); i = 2
        if (a[i] ~ /^\[/) { while (i <= n && a[i] !~ /\]$/) i++; i++ }
        uri = a[i]; sub(/\/+$/, "", uri)
        if (uri != "" && index(U, uri) == 1) { print T $0; hit = 1; next }
      }
      { print } END { exit !hit }' "$f" > "$TMP/fix.new"; then
      cat "$TMP/fix.new" > "$f"; hit=1
    fi
  done
  for f in /etc/apt/sources.list.d/*.sources; do
    [ -e "$f" ] || continue
    p=$(tr -d '\r' < "$f" | awk 'tolower($1)=="uris:"{print $2; exit}' | sed 's#/*$##')
    [ -n "$p" ] || continue
    case "$u" in
      "$p"*) sed -i -e '/^Enabled:/Id' -e 's/^Types:/Enabled: no\nTypes:/' "$f"; hit=1 ;;
    esac
  done
  return $((1-hit))
}

refresh_apt() {
  local try=0 urls u core=0 n=0 err=1 fixed
  while [ $try -lt 6 ]; do
    try=$((try+1))
    run_progress spin apt-get $APT_OPTS update; cp "$TMP/prog.out" "$TMP/aptupd"
    grep -E '^(E:|Err:)' "$TMP/aptupd" > "$TMP/apterr"
    if [ ! -s "$TMP/apterr" ]; then err=0; break; fi
    urls=$(grep -oE "https?://[^ ']+" "$TMP/apterr" | sed 's#/*$##' | sort -u)
    fixed=0
    for u in $urls; do
      if is_core_url "$u"; then
        grep -F "$u" "$TMP/apterr" | grep -q '^E:' && { core=1; break; }
        continue
      fi
      if disable_apt_url "$u"; then
        off "$u" "$(apt_reason "$u")"
        [ "$N_3P" -gt 0 ] && N_3P=$((N_3P-1)); n=$((n+1)); fixed=1
      else
        log "could not find a source line for $u"
      fi
    done
    [ $core = 1 ] && break
    # nothing more we can fix: OK if only non-fatal Err lines remain
    if [ $fixed = 0 ]; then grep -q '^E:' "$TMP/apterr" || err=0; break; fi
  done
  if [ $err = 0 ]; then
    if [ $n -gt 0 ]; then status WARN "OK, $n broken source(s) auto-disabled"
    elif grep -q '^W:' "$TMP/aptupd"; then
      note "WARN   apt: $(grep '^W:' "$TMP/aptupd" | head -1 | sed 's/^W: //' | cut -c1-110)"
      status WARN "OK, $(grep -c '^W:' "$TMP/aptupd") warning(s) - see notes"
    else status OK "metadata downloaded"; fi
    return 0
  fi
  restore_apt
  note "FAIL   apt-get update failed (core repo or unknown error) - original sources restored"
  grep '^E:' "$TMP/aptupd" | head -3 | while IFS= read -r u; do note "       $u"; done
  status FAIL "rolled back"; return 1
}

# packages whose upgrade candidate comes from a -security or esm origin
apt_security_pkgs() {
	apt-get -s $APT_OPTS dist-upgrade 2>/dev/null \
	 | awk '/^Inst / && /-security|ESM/ {print $2}' | sort -u
#  apt-get -s $APT_OPTS upgrade 2>/dev/null | awk '/^Inst /{print $2}' | while read -r pkg; do
#    apt-cache policy "$pkg" 2>/dev/null | awk -v P="$pkg" '
#      /\*\*\*/{cand=1}
#     cand && /https?:|file:/{ if ($0 ~ /-security|esm|ESM/) {print P; exit} }'
#  done | sort -u
}

upgrade_apt() {
  local p held="" rc try=0 urls u fixed APT_CMD
  set -f
  for p in $EXCLUDE; do
    held="$held $(dpkg-query -W -f='${Package}\n' "$p" 2>/dev/null | grep -vxF -f <(apt-mark showhold) | tr '\n' ' ')"
  done
  set +f
  [ -n "${held// /}" ] && run apt-mark hold $held
  local APT_CMD="dist-upgrade"
  if [ "$SEC_OPT" = "__APT_SECURITY__" ]; then
    # security-only: upgrade just packages whose candidate is from a -security/esm origin
    apt_security_pkgs > "$TMP/secpk"
    if [ ! -s "$TMP/secpk" ]; then UPG_SKIPPED="$UPG_SKIPPED"; : ; fi
    APT_CMD="install --only-upgrade $(tr '\n' ' ' < "$TMP/secpk")"
    [ -s "$TMP/secpk" ] || APT_CMD="dist-upgrade -s"   # nothing to do -> no-op sim
  fi
  while :; do
    try=$((try+1))
    run_progress apt apt-get -y $APT_OPTS -o APT::Status-Fd=3 $APT_CMD; rc=$?
    cp "$TMP/prog.out" "$TMP/upg.out"
    { [ $rc -eq 0 ] || [ $try -ge 3 ] || [ "$MODE" = native ]; } && break
    # packages that could not be downloaded -> disable that third-party source
    urls=$(grep -oE "Failed to fetch https?://[^ ]+" "$TMP/upg.out" | sed -E 's#^Failed to fetch ##; s#/(pool|dists)/.*##' | sort -u)
    fixed=0
    for u in $urls; do
      if is_core_url "$u"; then note "FAIL   core repo: packages missing on Nexus ($u)"; fixed=0; break; fi
      if disable_apt_url "$u"; then
        fixed=1; UPG_SKIPPED="$UPG_SKIPPED ${u##*/repository/}"
        note "WARN   $u: packages missing on Nexus (404), source disabled"
      fi
    done
    [ $fixed = 1 ] || break
    log "retrying upgrade without broken sources"
    run apt-get $APT_OPTS update
  done
  [ -n "${held// /}" ] && run apt-mark unhold $held
  return $rc
}

reboot_need_apt() { [ -f /var/run/reboot-required ] && RBR=yes; return 0; }

pkg_list() {
  if [ "$FAM" != apt ]; then rpm -qa 2>/dev/null | sort
  else dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null | sort; fi
}

# ---------------------------------------------------------------- progress
# run_progress <apt|yum|spin> cmd... : run in background with a live bar
# (apt: APT::Status-Fd=3, yum/dnf: "n/N" counters); output -> $TMP/prog.out
run_progress() {
  local kind=$1; shift
  local out=$TMP/prog.out st=$TMP/prog.st pid rc t0 n=0 pct=0 txt="working" l k p m el bar b sp='|/-\'
  : > "$out"; : > "$st"; t0=$(date +%s)
  log "\$ $*"
  "$@" > "$out" 2>&1 3> "$st" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$kind" = apt ]; then
      l=$(tail -n 1 "$st" 2>/dev/null)
      case "$l" in
        dlstatus:*|pmstatus:*)
          k=${l%%:*}; l=${l#*:}; l=${l#*:}; p=${l%%:*}; pct=${p%%.*}
          case "$k" in dlstatus) txt="downloading" ;; *) txt="installing" ;; esac ;;
      esac
    elif [ "$kind" = yum ]; then
      l=$(tail -n 40 "$out" 2>/dev/null | tr '\r' '\n' | grep -E '[0-9]+/[0-9]+' | tail -n 1)
      m=$(echo "$l" | grep -oE '[0-9]+/[0-9]+' | tail -n 1)
      if [ -n "$m" ] && [ "${m#*/}" -gt 0 ] 2>/dev/null; then
        pct=$(( ${m%/*} * 100 / ${m#*/} ))
        case "$l" in
          *Retrieving*) txt="download $m" ;; *Installing*) txt="installing $m" ;;
          \(*) txt="download $m" ;; *) txt="$(echo "$l" | awk '{print tolower($1)}') $m" ;;
        esac
      fi
    fi
    if [ "$TTY" = 1 ]; then
      el=$(( $(date +%s) - t0 )); el=$(printf '%d:%02d' $((el / 60)) $((el % 60)))
      if [ "$kind" = spin ]; then
        printf '\r\033[K  %s[%d/%d]%s %-18s %s  working...  %s' "$C_C" "$STEP" "$TOTAL" "$C_0" "$CUR" "${sp:$((n % 4)):1}" "$el"
      else
        case "$pct" in ''|*[!0-9]*) pct=0 ;; esac; [ "$pct" -gt 100 ] && pct=100
        bar=$(( pct * 16 / 100 ))
        b="$(printf '%*s' "$bar" '' | tr ' ' '#')$(printf '%*s' $((16 - bar)) '' | tr ' ' '.')"
        printf '\r\033[K  %s[%d/%d]%s %-18s %s %s[%s]%s %3d%%  %-18s %s' \
          "$C_C" "$STEP" "$TOTAL" "$C_0" "$CUR" "${sp:$((n % 4)):1}" "$C_G" "$b" "$C_0" "$pct" "$txt" "$el"
      fi
    fi
    sleep 1; n=$((n + 1))
  done
  wait "$pid"; rc=$?
  cat "$out" >> "$FULL"; [ "$VERBOSE" = 1 ] && cat "$out"
  [ "$TTY" = 1 ] && printf '\r\033[K  %s[%d/%d]%s %-26s ' "$C_C" "$STEP" "$TOTAL" "$C_0" "$CUR"
  return $rc
}

# ---------------------------------------------------------------- verify
# re-read metadata and list what is still upgradable
verify_uptodate() {
  local PM rc l
  : > "$TMP/pending"
  if [ "$FAM" = zypper ]; then
    say ""
    say "         \$ zypper list-updates"
    zypper --non-interactive list-updates > "$TMP/chk" 2>&1
    cat "$TMP/chk" >> "$FULL"
    awk -F'|' '$1 ~ /^v/ { n = $3; gsub(/^ +| +$/, "", n); a = $5; gsub(/^ +| +$/, "", a); print n "  " a }' "$TMP/chk" > "$TMP/pending"
  elif [ "$FAM" = apt ]; then
    say ""
    say "         \$ apt-get update"
    say "         \$ apt list --upgradable"
    run apt-get $APT_OPTS update
    apt list --upgradable 2>/dev/null | grep -v '^Listing' | grep . > "$TMP/pending"
  else
    PM=$(yum_pm)
    say ""
    say "         \$ $PM check-update"
    $PM -q $YUM_OPTS check-update > "$TMP/chk" 2>&1; rc=$?
    cat "$TMP/chk" >> "$FULL"
    if [ $rc -eq 1 ]; then
      say "         ${C_Y}check-update failed (see full log)${C_0}"
      printf '  %s[%d/%d]%s %-26s ' "$C_C" "$STEP" "$TOTAL" "$C_0" "$CUR"
      status WARN "could not verify"; return 0
    fi
    [ $rc -eq 100 ] && awk '/^(Obsoleting|Security:)/ { exit } NF >= 3 && $1 ~ /\./ && $2 ~ /[0-9]/ { print $1 "  " $2 "  " $3 }' "$TMP/chk" > "$TMP/pending"
  fi
  { echo "----- still upgradable:"; cat "$TMP/pending"; } >> "$FULL"
  PEND=$(grep -c . "$TMP/pending")
  # security updates LEFT after the upgrade (3.7.2)
  case "$FAM" in
    apt) SEC_AFTER=$(grep -ciE '[-]security|esm' "$TMP/pending") ;;
    yum) SEC_AFTER=$($(yum_pm) -q $YUM_OPTS --security check-update 2>/dev/null | awk 'NF>=3 && $1 ~ /\./{n++} END{print n+0}') ;;
    *)   SEC_AFTER="" ;;
  esac
  { echo "----- security updates left: ${SEC_AFTER:-unknown}"; } >> "$FULL"
  if [ "$PEND" -eq 0 ] && [ -n "$NAT_FAIL" ]; then
    say "         (empty, but some repositories were unreachable)"
    UTD=partial
    note "WARN   up-to-date only for reachable repositories; unreachable: $NAT_FAIL"
  elif [ "$PEND" -eq 0 ]; then
    say "         (empty - nothing left to upgrade)"
    UTD=yes
  else
    UTD=no
    head -n 15 "$TMP/pending" | while IFS= read -r l; do say "         ${C_Y}$l${C_0}"; done
    [ "$PEND" -gt 15 ] && say "         ... and $((PEND - 15)) more (see full log)"
    note "WARN   $PEND package(s) still upgradable${EXCLUDE:+ (excluded on purpose: $EXCLUDE)} - see full log"
  fi
  printf '  %s[%d/%d]%s %-26s ' "$C_C" "$STEP" "$TOTAL" "$C_0" "$CUR"
  if [ "$UTD" = yes ]; then status OK "all packages up to date"
  elif [ "$UTD" = partial ]; then status WARN "up to date for reachable repos only"
  else status WARN "$PEND package(s) still upgradable"; fi
}

# ---------------------------------------------------------------- NATIVE mode
# OS without repos on Nexus: keep the server's own repositories untouched,
# just refresh + upgrade with the default package manager (dnf/yum/apt/zypper)
NAT_FAIL=""

native_plan() {
  local f id en url gk mh n=0 l
  : > "$TMP/natrepos"
  case "$FAM" in
    yum)
      for f in /etc/yum.repos.d/*.repo; do [ -e "$f" ] && parse_repo "$f"; done \
        | awk -F'|' '$3 == 1 { print $2 "|" $4 }' > "$TMP/natrepos" ;;
    apt)
      cat /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null | tr -d '\r' \
        | awk '$1 == "deb" { i = 2; if ($2 ~ /^\[/) { while (i <= NF && $i !~ /\]$/) i++; i++ } print $(i+1) "|" $i }' > "$TMP/natrepos"
      for f in /etc/apt/sources.list.d/*.sources; do
        [ -e "$f" ] || continue
        tr -d '\r' < "$f" | grep -qi '^Enabled: *no' && continue
        echo "$(tr -d '\r' < "$f" | awk 'tolower($1)=="suites:"{print $2; exit}')|$(tr -d '\r' < "$f" | awk 'tolower($1)=="uris:"{print $2; exit}')" >> "$TMP/natrepos"
      done ;;
    zypper)
      zypper --non-interactive lr -u 2>/dev/null | awk -F'|' 'NR > 2 && NF >= 4 {
          a = $2; gsub(/^ +| +$/, "", a); e = $4; gsub(/ /, "", e); u = $NF; gsub(/^ +| +$/, "", u)
          if (e == "Yes") print a "|" u }' > "$TMP/natrepos" ;;
  esac
  while IFS='|' read -r id url; do
    [ -n "$id" ] || continue
    n=$((n+1)); [ $n -le 12 ] && plan use "$id" "$url"
  done < "$TMP/natrepos"
  [ $n -gt 12 ] && plan use "..." "$((n - 12)) more repositories"
  N_NAT=$n
}

refresh_native() {
  local rc names n
  case "$FAM" in
    yum)    run_progress spin $PKGMGR -y $YUM_OPTS makecache; rc=$?
            names=$(grep -oE "repository '[^']+'|repo '[^']+'|for repository: [A-Za-z0-9_.:-]+|from [A-Za-z0-9_.:-]+: \[Errno|Ignoring repositories: .*" "$TMP/prog.out" \
                    | sed -E "s/^(repository|repo) '//; s/'$//; s/^for repository: //; s/^from //; s/: \[Errno$//; s/^Ignoring repositories: //" \
                    | tr ',' '\n' | sed 's/^ *//; s/ *$//; s/[.]$//' | grep . | sort -u | tr '\n' ' ') ;;
    apt)    run_progress spin apt-get $APT_OPTS update; rc=$?
            names=$(grep -E '^(Err:|W: Failed to fetch|E: Failed to fetch)' "$TMP/prog.out" | grep -oE 'https?://[^ ]+' \
                    | sed -E 's#/(dists|pool)/.*##' | sort -u | tr '\n' ' ') ;;
    zypper) run_progress spin zypper --non-interactive refresh; rc=$?
            names=$(grep -oE "Skipping repository '[^']+'|Repository '[^']+' is invalid|Problem retrieving files from '[^']+'" "$TMP/prog.out" \
                    | grep -oE "'[^']+'" | tr -d "'" | sort -u | tr '\n' ' ') ;;
  esac
  NAT_FAIL=${names% }
  if [ -n "$NAT_FAIL" ]; then
    for n in $NAT_FAIL; do note "WARN   repository unreachable, not checked: $n"; done
    status WARN "$(echo $NAT_FAIL | wc -w | tr -d ' ') repo(s) unreachable (see notes)"
  else
    status OK "metadata downloaded (existing repositories)"
  fi
  return 0
}

upgrade_native() {
  local rc p EX="" locks=""
  case "$FAM" in
    yum)
      set -f; for p in $EXCLUDE; do EX="$EX --exclude=$p"; done; set +f
      run_progress yum $PKGMGR -y $YUM_OPTS $SEC_OPT --skip-broken update $EX; return $? ;;
    apt)
      upgrade_apt; return $? ;;
    zypper)
      set -f; for p in $EXCLUDE; do zypper --non-interactive addlock "$p" >> "$FULL" 2>&1 && locks="$locks $p"; done; set +f
      run_progress yum zypper --non-interactive update --auto-agree-with-licenses; rc=$?
      # 103 = zypper updated itself, run once more
      [ $rc -eq 103 ] && { run_progress yum zypper --non-interactive update --auto-agree-with-licenses; rc=$?; }
      set -f; for p in $locks; do zypper --non-interactive removelock "$p" >> "$FULL" 2>&1; done; set +f
      [ $rc -eq 102 ] && RBR=yes
      # 100-106 are informational exit codes in zypper
      [ $rc -ge 100 ] && [ $rc -le 106 ] && rc=0
      return $rc ;;
  esac
}

reboot_need_zypper() {
  local rc p
  zypper needs-rebooting >/dev/null 2>&1; rc=$?
  if [ $rc -eq 102 ]; then RBR=yes; return 0; fi
  [ $rc -eq 0 ] && return 0
  p=$(ls -t /boot/vmlinuz-* 2>/dev/null | grep -v rescue | head -1)
  [ -n "$p" ] && [ "$p" != "/boot/vmlinuz-$(uname -r)" ] && RBR=yes
  return 0
}

# ---------------------------------------------------------------- plan view
# identical lines -> "count|line", first-seen order
dedupe() { awk '{ if (!($0 in c)) o[++k] = $0; c[$0]++ } END { for (i = 1; i <= k; i++) print c[o[i]] "|" o[i] }'; }

show_plan() {
  local t a b c
  local x
  [ -s "$TMP/plan" ] || return 0
  dedupe < "$TMP/plan" | while IFS='|' read -r x t a b; do
    case "$t" in core) c=$C_G ;; 3p|keep|fix) c=$C_C ;; repl|dup) c="" ;; *) c=$C_Y ;; esac
    [ "$x" -gt 1 ] && b="$b  (x$x)"
    say "         $c$(printf '%-5s' "$t")$C_0 $(printf '%-22s' "$a") $b"
  done
  [ "$DO_UPDATE" = 1 ] && say "         then: upgrade all packages${EXCLUDE:+ (except: $EXCLUDE)}, reboot: $( [ "$REBOOT" = 1 ] && echo auto || echo manual )"
  [ "$DO_UPDATE" = 1 ] || say "         then: repositories only, no upgrade"
}

# ---------------------------------------------------------------- main
# ---------------------------------------------------------------- APP packages
# pip / npm / helm / docker against the zone's "app" Nexus (4th zone field).
# default: point the tools at Nexus + report what is outdated
# --app-packages: also upgrade pip/npm packages and the helm binary.
# Docker is report-only: changing it needs a daemon restart (= all containers).
APP_OUT=0; APP_TXT=""

# pip packages installed by pip itself (not by rpm/deb), normalised names
pip_owned() {
  "$1" - <<'PY' 2>/dev/null
import glob, os, re, site
dirs = set()
try: dirs.update(site.getsitepackages())
except Exception: pass
try: dirs.add(site.getusersitepackages())
except Exception: pass
names = set()
for d in dirs:
    for f in glob.glob(os.path.join(d, '*.dist-info', 'INSTALLER')):
        try:
            if open(f).read().strip() in ('pip', 'uv'):
                n = os.path.basename(os.path.dirname(f)).rsplit('-', 1)[0]
                names.add(re.sub(r'[-_.]+', '-', n).lower())
        except Exception:
            pass
print(' '.join(sorted(names)))
PY
}

app_pip() {
  local py idx host own n=0 l name cur lat bsp=""
  py=$(command -v python3 2>/dev/null) || return 0
  "$py" -m pip --version >/dev/null 2>&1 || return 0
  idx="$APP_NX/pypi-public/simple"; host=$(url_host "$APP_NX"); host=${host%%:*}
  # 1. configure (system wide) - only with --app-packages; default is report-only
  if [ "$DRY_RUN" != 1 ] && [ "$APP_UPDATE" = 1 ]; then
    mkdir -p "$BAK_DIR"; [ -e /etc/pip.conf ] && cp -a /etc/pip.conf "$BAK_DIR/pip.conf" 2>/dev/null
    printf '[global]\nindex-url = %s\ntrusted-host = %s\n' "$idx" "$host" > /etc/pip.conf
  fi
  # 2. report: outdated packages that pip installed
  own=" $(pip_owned "$py") "
  PIP_INDEX_URL=$idx PIP_TRUSTED_HOST=$host timeout 300 "$py" -m pip list --outdated --format=json \
      --disable-pip-version-check 2>>"$FULL" > "$TMP/pip.json"
  "$py" -c '
import json, re, sys
for p in json.load(open(sys.argv[1])):
    print(re.sub(r"[-_.]+", "-", p["name"]).lower(), p["version"], p["latest_version"])' \
      "$TMP/pip.json" 2>/dev/null > "$TMP/pip.out"
  : > "$TMP/pip.upg"
  while read -r name cur lat; do
    case "$own" in *" $name "*) ;; *) continue ;; esac
    n=$((n+1)); echo "$name" >> "$TMP/pip.upg"
    [ $n -le 15 ] && say "         pip   $(printf '%-28s %-12s -> %s' "$name" "$cur" "$lat")"
  done < "$TMP/pip.out"
  [ $n -gt 15 ] && say "         pip   ... and $((n - 15)) more"
  APP_TXT="$APP_TXT pip:$n"
  [ $n -eq 0 ] && return 0
  # 3. upgrade (only with --app-packages)
  if [ "$APP_UPDATE" = 1 ] && [ "$DRY_RUN" != 1 ]; then
    "$py" -c 'import sysconfig,os,sys; sys.exit(0 if os.path.exists(os.path.join(sysconfig.get_paths()["stdlib"],"EXTERNALLY-MANAGED")) else 1)' \
      && bsp="--break-system-packages"
    if PIP_INDEX_URL=$idx PIP_TRUSTED_HOST=$host run "$py" -m pip install --upgrade $bsp $(cat "$TMP/pip.upg"); then
      note "INFO   pip: $n package(s) upgraded"
    else
      note "WARN   pip: upgrade failed - see full log"; APP_OUT=$((APP_OUT+n))
    fi
  else
    APP_OUT=$((APP_OUT+n)); note "WARN   pip: $n package(s) outdated (upgrade: --app-packages)"
  fi
}

app_npm() {
  local reg n=0 name
  command -v npm >/dev/null 2>&1 || return 0
  reg="$APP_NX/npmjs-public/"
  if [ "$DRY_RUN" != 1 ] && [ "$APP_UPDATE" = 1 ]; then
    [ -e /etc/npmrc ] && cp -a /etc/npmrc "$BAK_DIR/npmrc" 2>/dev/null
    run npm config set registry "$reg" -g
  fi
  timeout 300 npm outdated -g --json --registry "$reg" 2>>"$FULL" > "$TMP/npm.json"
  python3 -c '
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: d = {}
for k, v in d.items(): print(k, v.get("current", "?"), v.get("latest", "?"))' \
      "$TMP/npm.json" 2>/dev/null > "$TMP/npm.out"
  while read -r name cur lat; do
    n=$((n+1)); [ $n -le 15 ] && say "         npm   $(printf '%-28s %-12s -> %s' "$name" "$cur" "$lat")"
  done < "$TMP/npm.out"
  APP_TXT="$APP_TXT npm:$n"
  [ $n -eq 0 ] && return 0
  if [ "$APP_UPDATE" = 1 ] && [ "$DRY_RUN" != 1 ]; then
    if run npm install -g --registry "$reg" $(awk '{print $1 "@latest"}' "$TMP/npm.out"); then
      note "INFO   npm: $n global package(s) upgraded"
    else
      note "WARN   npm: upgrade failed - see full log"; APP_OUT=$((APP_OUT+n))
    fi
  else
    APP_OUT=$((APP_OUT+n)); note "WARN   npm: $n global package(s) outdated (upgrade: --app-packages)"
  fi
}

# chart repo URL -> Nexus helm proxy
helm_proxy_for() {
  case "$1" in
    *argoproj*)  echo argo-helm ;;      *istio*)    echo istio-helm ;;
    *longhorn*)  echo longhorn-helm ;;  *metallb*)  echo metallb-helm ;;
    *rancher*)   echo rancher-helm ;;   *thanos*)   echo thanos-community-helm ;;
    *hashicorp*) echo vso-helm ;;
  esac
}

app_helm() {
  local hb cur lat name url px tgz
  hb=$(command -v helm 2>/dev/null) || return 0
  cur=$(helm version --short 2>/dev/null | sed 's/+.*//')
  # 1. chart repos -> Nexus
  helm repo list 2>/dev/null | awk 'NR > 1 { print $1, $2 }' | while read -r name url; do
    px=$(helm_proxy_for "$url")
    case "$url" in *"$(url_host "$APP_NX")"*) continue ;; esac
    if [ -n "$px" ]; then
      [ "$DRY_RUN" = 1 ] || [ "$APP_UPDATE" != 1 ] || run helm repo add "$name" "$APP_NX/$px" --force-update
      say "         helm  repo $name -> $px"
    else
      say "         helm  repo $name ($url): no Nexus proxy"
      echo "WARN   helm repo $name ($url) not mirrored on Nexus" >> "$REPORT"
    fi
  done
  # 2. helm binary
  lat=$(curl -s --noproxy '*' -m "$TIMEOUT" "$APP_NX/helm-binary/helm-latest-version" | tr -d '[:space:]')
  echo "$lat" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' || lat=""
  case "$lat" in v[0-9]*) ;; *) say "         helm  $cur (latest version unknown on Nexus)"; APP_TXT="$APP_TXT helm:?"; return 0 ;; esac
  if [ "$cur" = "$lat" ]; then say "         helm  $cur (up to date)"; APP_TXT="$APP_TXT helm:ok"; return 0; fi
  say "         helm  $(printf '%-28s %-12s -> %s' binary "$cur" "$lat")"
  APP_TXT="$APP_TXT helm:old"
  if [ "$APP_UPDATE" = 1 ] && [ "$DRY_RUN" != 1 ]; then
    tgz="helm-$lat-linux-amd64.tar.gz"
    curl -s --noproxy '*' -m 300 -o "$TMP/$tgz" "$APP_NX/helm-binary/$tgz"
    curl -s --noproxy '*' -m 60  -o "$TMP/$tgz.sha256sum" "$APP_NX/helm-binary/$tgz.sha256sum"
    if (cd "$TMP" && sha256sum -c "$tgz.sha256sum" >/dev/null 2>&1) \
       && tar -xzf "$TMP/$tgz" -C "$TMP" linux-amd64/helm 2>/dev/null; then
      cp -a "$hb" "$BAK_DIR/helm.$cur" 2>/dev/null
      install -m 755 "$TMP/linux-amd64/helm" "$hb" && note "INFO   helm upgraded $cur -> $lat (old binary in $BAK_DIR)"
    else
      note "WARN   helm: download or checksum failed - not upgraded"; APP_OUT=$((APP_OUT+1))
    fi
  else
    APP_OUT=$((APP_OUT+1)); note "WARN   helm binary $cur outdated ($lat) (upgrade: --app-packages)"
  fi
  command -v kubectl >/dev/null 2>&1 && say "         info  kubectl $(kubectl version --client 2>/dev/null | head -1 | sed 's/.*: *//')"
  command -v trivy   >/dev/null 2>&1 && say "         info  trivy $(trivy --version 2>/dev/null | awk 'NR==1{print $2}')"
}

# docker: report only - images of running containers older than DOCKER_AGE days
app_docker() {
  local n=0 img created age now
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || { say "         docker  daemon not running"; return 0; }
  now=$(date +%s)
  docker ps --format '{{.Image}}' 2>/dev/null | sort -u | while read -r img; do
    created=$(docker image inspect -f '{{.Created}}' "$img" 2>/dev/null | cut -c1-19)
    age=$(( (now - $(date -d "${created/T/ }" +%s 2>/dev/null || echo "$now")) / 86400 ))
    [ "$age" -ge "$DOCKER_AGE" ] && say "         docker $(printf '%-40s %s days old' "$img" "$age")" && echo x
  done > "$TMP/dock.n"
  n=$(grep -c x "$TMP/dock.n")
  APP_TXT="$APP_TXT docker:$n"
  [ "$n" -gt 0 ] && note "WARN   docker: $n running image(s) older than $DOCKER_AGE days - rebuild/redeploy by the service owner (not changed by this script)"
  return 0
}

app_packages() {
  APP_NX=${NX_APP_ENV:-$(zone_field "$ZONE" 4)}
  if [ "$NO_APP" = 1 ]; then status SKIP "--no-app"; return 0; fi
  if [ -z "$APP_NX" ]; then status SKIP "no app Nexus in zone $ZONE"; return 0; fi
  if [ "$(http_code "${APP_NX%/repository}/service/rest/v1/status")" != 200 ]; then
    status WARN "app Nexus $(url_host "$APP_NX") not reachable"; note "WARN   app Nexus $(url_host "$APP_NX") not reachable - pip/npm/helm not checked"; return 0
  fi
  if ! command -v pip3 >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1 && ! command -v npm >/dev/null 2>&1 \
     && ! command -v helm >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
    status SKIP "no pip / npm / helm / docker on this server"; return 0
  fi
  say ""
  app_pip; app_npm; app_helm; app_docker
  printf '  %s[%d/%d]%s %-26s ' "$C_C" "$STEP" "$TOTAL" "$C_0" "$CUR"
  APP_TXT=${APP_TXT# }
  if [ "$APP_OUT" -gt 0 ]; then status WARN "${APP_TXT:-checked} ($APP_OUT outdated)"
  else status OK "${APP_TXT:-checked}"; fi
}

# ---------------------------------------------------------------- zones
# telnet-style check: can we open a TCP connection to host:port ?
tcp_ok() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT" bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
  else
    (exec 3<>/dev/tcp/$1/$2) 2>/dev/null
  fi
}
zone_names() { echo "$ZONES" | cut -d'|' -f1; }
zone_field() { echo "$ZONES" | awk -F'|' -v Z="$1" -v N="$2" '$1 == Z { print $N }'; }
url_host()   { local h=${1#*://}; echo "${h%%/*}"; }

# 0 if any Nexus of the zone answers on its TCP port
zone_reachable() {
  local u hp h p
  for u in $(zone_field "$1" 2) $(zone_field "$1" 3); do
    hp=$(url_host "$u"); h=${hp%%:*}; p=${hp##*:}; [ "$p" = "$hp" ] && p=80
    tcp_ok "$h" "$p" || continue
    # firewalls may accept the TCP connection and drop the traffic: ask the API
    [ "$(http_code "${u%/repository}/service/rest/v1/status")" = 200 ] && return 0
  done
  return 1
}

# detect which zones answer (slow: opens TCP + API to every zone's Nexus)
detect_zones() {
  local z
  [ -n "$DET_DONE" ] && return 0
  DET=""
  for z in $(zone_names); do zone_reachable "$z" && DET="$DET $z"; done
  DET=${DET# }; DET_DONE=1
}

# pick the one reachable zone, or stop asking for --zone
auto_zone() {
  detect_zones
  case "$(echo $DET | wc -w)" in
    1) ZONE=$DET; ZONE_SRC=auto ;;
    0) ZONE=${1:-none}; ZONE_SRC=auto ;;
    *) echo "more than one zone reachable ($DET) - choose one with --zone"; rm -rf "$TMP"; rm -rf "$LOCK" 2>/dev/null; exit 10 ;;
  esac
}

select_zone() {
  local saved="" z n=0 ans names
  names=$(zone_names | tr '\n' ' ')
  [ -r "$ZONE_FILE" ] && saved=$(tr -dc 'a-z0-9_-' < "$ZONE_FILE")

  if [ -n "$ZONE" ]; then
    # --zone / ZONE=... ; "auto" means detect now
    case "$ZONE" in auto|AUTO|Auto) auto_zone ;; *) ZONE_SRC=flag ;; esac
  elif [ "$INTERACTIVE" = 1 ] && [ "$ASSUME_YES" != 1 ]; then
    # menu: no detection here, so it is instant
    find_last_run
    if [ -n "$LAST_RUN" ]; then
      local mins; mins=$(ago_text "$LAST_RUN")
      case "$mins" in *min*|*hours*) echo "" >&2
        echo "  Note: last successful run was $mins. If you only want to re-check" >&2
        echo "        the result (kernel/reboot/pending), run with --check instead." >&2 ;;
      esac
    fi
    echo "" >&2; echo "  Server zone:" >&2
    for z in $names; do
      n=$((n+1))
      printf '    %d) %-10s %s%s\n' "$n" "$z" "$(url_host "$(zone_field "$z" 2)")" \
        "$( [ "$z" = "$saved" ] && echo "   (saved)")" >&2
    done
    printf '    %d) %-10s %s\n' "$((n+1))" "auto" "detect automatically (slower)" >&2
    printf '  Choose [1-%d]%s: ' "$((n+1))" "${saved:+ (Enter = $saved)}" >&2
    read -r ans < /dev/tty
    case "$ans" in
      "")        ZONE=${saved:-}; ZONE_SRC=saved
                 [ -n "$ZONE" ] || { echo "  no saved zone - pick a number" >&2; ZONE=""; auto_zone; } ;;
      $((n+1)))  auto_zone ;;
      *[!0-9]*)  ZONE=$ans; ZONE_SRC=user ;;
      *)         ZONE=$(echo "$names" | tr ' ' '\n' | grep . | sed -n "${ans}p"); ZONE_SRC=user ;;
    esac
  elif [ -n "$saved" ]; then
    # Ansible / no tty: trust the saved zone without probing
    ZONE=$saved; ZONE_SRC=saved
  else
    auto_zone
  fi

  if [ "$ZONE" != none ]; then
    case " $names " in *" $ZONE "*) ;; *) echo "unknown zone '$ZONE' (known: $names)"; rm -rf "$TMP"; rm -rf "$LOCK" 2>/dev/null; exit 10 ;; esac
    NEXUS_OS=${NX_OS_ENV:-$(zone_field "$ZONE" 2)}
    NEXUS_3P=${NX_3P_ENV:-$(zone_field "$ZONE" 3)}
    [ "$DRY_RUN" = 1 ] || echo "$ZONE" > "$ZONE_FILE" 2>/dev/null
  else
    NEXUS_OS=${NX_OS_ENV:-http://none.invalid/repository}; NEXUS_3P=${NX_3P_ENV:-$NEXUS_OS}
  fi
  # every Nexus we know (any zone) -> recognised in old repo files
  NX_ALL_HOSTS="$NX_EXTRA_HOSTS"
  for z in $names; do NX_ALL_HOSTS="$NX_ALL_HOSTS $(url_host "$(zone_field "$z" 2)") $(url_host "$(zone_field "$z" 3)") $(url_host "$(zone_field "$z" 4)")"; done
  ZONE_HOSTS="$(url_host "$NEXUS_OS") $(url_host "$NEXUS_3P")"
}

# URL on a Nexus of another zone ?
is_zone_url() { local h; for h in $ZONE_HOSTS; do case "$1" in *"$h"*) return 0 ;; esac; done; return 1; }
# same repo path on this zone's Nexus (echo new URL) - kind: yum|apt, [suite]
zone_remap() {
  local rest=${1%/} b
  rest=${rest#*/repository/}
  for b in $BASES_3P; do
    probe "$b/$rest" "$2" "${3:-}" && { echo "$b/$rest"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------- welcome menu
# Shown only in an interactive terminal when the user gave no action flag and
# no -y. Lets non-CLI admins pick what to do by number. Maps to the same flags.
welcome_menu() {
  [ "$ACTION_SET" = 1 ] && return 0          # an action flag was given
  [ "$ASSUME_YES" = 1 ] && return 0          # unattended
  [ "$INTERACTIVE" = 1 ] || return 0         # no terminal (Ansible/cron)
  [ "$DRY_RUN" = 1 ] && return 0             # -n already means report-only
  local a
  say ""
  say "  ${C_B}What do you want to do?${C_0}"
  say "    1) Check only          - show status, change nothing (safe)"
  say "    2) Security updates     - install security patches only ${C_G}(recommended)${C_0}"
  say "    3) Full update          - install ALL updates ${C_Y}(use with care)${C_0}"
  say "    4) Configure repos only - point repos to Nexus, do not upgrade"
  printf '  Choose [1-4] (Enter = 2): ' >&2
  read -r a < /dev/tty
  echo "  welcome choice: ${a:-<empty>}" >> "$SUM"
  case "$a" in
    1) CHECK=1 ;;
    3) LEVEL=full ;;
    4) DO_UPDATE=0 ;;
    *) LEVEL=security ;;
  esac
  return 0
}

# ---------------------------------------------------------------- check mode
find_last_run() {
  local f last="" when
  for f in $(ls -t "$LOG_DIR/${HOST}_"*.log 2>/dev/null | grep -v '_full.log'); do
    [ "$f" = "$SUM" ] && continue
    grep -q 'exit=0' "$f" 2>/dev/null || continue
    grep -q 'update=dry-run' "$f" 2>/dev/null && continue
    when=$(basename "$f" | sed -E "s/.*_([0-9]{8})-([0-9]{6})\.log/\1 \2/")
    last="$when"; break
  done
  LAST_RUN="$last"
}

ago_text() {
  local y=${1:0:4} mo=${1:4:2} d=${1:6:2} hh=${1:9:2} mi=${1:11:2} t now diff
  t=$(date -d "$y-$mo-$d $hh:$mi" +%s 2>/dev/null) || { echo "$1"; return; }
  now=$(date +%s); diff=$(( (now - t) / 60 ))
  if [ "$diff" -lt 60 ]; then echo "${diff} min ago"
  elif [ "$diff" -lt 1440 ]; then echo "$(( diff / 60 )) hours ago"
  else echo "$(( diff / 1440 )) days ago"; fi
}

run_check() {
  local sec=0 oth=0 PM
  CHK_NEED=0
  say ""
  say "  ${C_B}================== Check (read-only) ==================${C_0}"
  say "   Host / IP   : $HOST / ${C_G}$IP${C_0}   zone: $ZONE"
  say "   OS          : $OS_TXT"
  [ -n "$LAST_RUN" ] && say "   Last run    : $(ago_text "$LAST_RUN")"
  kernel_state
  case "$KSTATE" in
    ok)     say "   Kernel      : ${C_G}$RUN_K (running = newest installed)${C_0}" ;;
    reboot) say "   Kernel      : ${C_Y}running $RUN_K, installed $NEW_K${C_0}"
            say "                 ${C_Y}-> REBOOT needed to activate the new kernel${C_0}"; CHK_NEED=1 ;;
    grub)   say "   Kernel      : ${C_R}running $RUN_K, installed $NEW_K, default boot $DEF_K${C_0}"
            say "                 ${C_R}-> GRUB default is wrong: fix it, then reboot${C_0}"
            say "                    grubby --set-default /boot/vmlinuz-$NEW_K"; CHK_NEED=1 ;;
  esac
  if [ "$FAM" = yum ]; then
    PM=$(yum_pm)
    sec=$($PM -q $YUM_OPTS --security check-update 2>/dev/null | awk 'NF>=3 && $1 ~ /\./{n++} END{print n+0}')
    oth=$(( $($PM -q $YUM_OPTS check-update 2>/dev/null | awk 'NF>=3 && $1 ~ /\./{n++} END{print n+0}') - sec ))
  elif [ "$FAM" = apt ]; then
    apt-get $APT_OPTS update >/dev/null 2>&1
    apt-get -s $APT_OPTS upgrade 2>/dev/null | awk '/^Inst /{print}' > "$TMP/inst"
    sec=$(grep -ciE 'security|-security|esm' "$TMP/inst")
    oth=$(( $(grep -c '^Inst' "$TMP/inst") - sec ))
  fi
  [ "$oth" -lt 0 ] && oth=0
  if [ "$sec" -gt 0 ]; then
    say "   Security    : ${C_Y}$sec pending${C_0} -> run again and choose security"; CHK_NEED=1
  else
    say "   Security    : ${C_G}0 pending (all security patches applied)${C_0}"
  fi
  [ "$oth" -gt 0 ] && say "   Other       : $oth non-security update(s) available"
  say "  ------------------------------------------------------"
  if [ "$CHK_NEED" = 0 ]; then
    say "   ${C_G}All good. Nothing to do. No re-run needed.${C_0}"
  else
    say "   ${C_Y}Action needed (see above). To apply: run without --check.${C_0}"
  fi
  say "  ${C_B}======================================================${C_0}"
  local l="host=$HOST ip=$IP zone=${ZONE:-?} os=$KEY check=1 kernel=$KSTATE running_kernel=${RUN_K:-?} newest_kernel=${NEW_K:-?} security_pending=$sec other=$oth need_action=$CHK_NEED exit=0"
  say "RESULT $l"
  write_result "$l"
  rm -rf "$TMP"; rm -rf "$LOCK" 2>/dev/null
  exit 0
}

main() {
  local b h ans rc t0 PX
  [ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 5; }
  take_lock
  TMP=$(mktemp -d /tmp/server_update.XXXXXX) || { rm -rf "$LOCK"; exit 3; }
  trap 'echo; echo "interrupted"; rm -rf "$TMP"; rm -rf "$LOCK" 2>/dev/null; exit 130' INT TERM
  # (3.7.1) SSH drop / closed terminal must NOT kill a running dnf/apt:
  # ignore HUP (inherited by dnf/apt too) and finish the job; see the logs.
  trap '' HUP
  REPORT=$TMP/report; USED=$TMP/used; : > "$REPORT"; : > "$USED"; : > "$TMP/plan"
  mkdir -p "$LOG_DIR" && chmod 750 "$LOG_DIR"; : > "$SUM"; : > "$FULL"
  case "$ZONES" in *example.com*) note "WARN   ZONES still holds the example Nexus URLs - edit the CONFIGURATION block or /etc/server_update.conf" ;; esac
  rm -f "$LOG_DIR/last_result.json"
  mkdir -p /var/backups/server_update && chmod 700 /var/backups/server_update
  select_zone
  [ "$DRY_RUN" = 1 ] && TOTAL=5

  say ""
  say "  ${C_B}=============================================${C_0}"
  say "  ${C_B} server_update v$VERSION${C_0}  |  $HOST  |  ${C_G}$IP${C_0}  |  zone: ${C_C}$ZONE${C_0} ($ZONE_SRC)  |  $(date '+%Y-%m-%d %H:%M')"
  [ "$DRY_RUN" = 1 ] && say "  ${C_Y} DRY-RUN: nothing will be changed${C_0}"
  say "  ${C_B}=============================================${C_0}"

  welcome_menu

  # 1 ---------------------------------------------------------------
  step "Preflight (OS)"
  detect_os
  OS_TXT="$OS_ID $OS_VER"
  PKGMGR=""
  if command -v dnf >/dev/null 2>&1; then PKGMGR=dnf
  elif command -v yum >/dev/null 2>&1; then PKGMGR=yum
  elif command -v apt-get >/dev/null 2>&1; then PKGMGR=apt
  elif command -v zypper >/dev/null 2>&1; then PKGMGR=zypper; fi
  case "$PKGMGR" in
    dnf|yum) FAM=yum ;; apt) FAM=apt ;; zypper) FAM=zypper ;;
    *) note "FAIL   no supported package manager (dnf/yum/apt/zypper) on '$OS_ID $OS_VER'"
       status FAIL "$OS_TXT: no package manager"; finish 2 ;;
  esac
  case "$KEY" in
    ol7|ol8|ol9|ol10|rocky8|rocky9|rocky10|alma8|alma9|alma10|ubuntu|debian) MODE=nexus ;;
    *) MODE=native
       note "INFO   $OS_TXT has no repos on Nexus - native mode: existing repositories are used unchanged" ;;
  esac
  [ "$KEY" = centos7 ] && note "WARN   centos7: Nexus has no 'base' repo, only updates/extras"
  status OK "$OS_TXT ($ARCH, $PKGMGR, $MODE mode)"

  # --- check mode: read-only status, then exit (no changes) ---
  if [ "$CHECK" = 1 ]; then
    [ "$MODE" = nexus ] && { BASES_OS="$NEXUS_OS"; BASES_3P="$NEXUS_3P"; }
    find_last_run
    run_check
  fi

  # 2 ---------------------------------------------------------------
  step "Disk space"
  check_disk || finish 7

  # 3 ---------------------------------------------------------------
  step "Nexus connectivity"
  if [ "$ZONE" = none ] && [ "$MODE" = nexus ]; then
    MODE=native; note "WARN   no Nexus of any zone reachable - native mode (existing repositories)"
  fi
  if [ "$MODE" = native ]; then
    NX_TXT="not used"; status SKIP "not used for $OS_TXT (native mode)"
  else
    BASES_OS=""; BASES_3P=""; NX_HOSTS="$NX_ALL_HOSTS"
    for b in "$NEXUS_OS" "$NEXUS_3P"; do
      h=${b#*://}; h=${h%%/*}
      if [ "$(http_code "${b%/repository}/")" != 000 ]; then
        BASES_OS="$BASES_OS $b"; NX_TXT="$NX_TXT ${h%%:*} OK,"
      else
        NX_TXT="$NX_TXT ${h%%:*} DOWN,"; note "WARN   nexus $h not reachable"
      fi
    done
    NX_TXT=${NX_TXT# }; NX_TXT=${NX_TXT%,}
    for b in "$NEXUS_3P" "$NEXUS_OS"; do
      case " $BASES_OS " in *" $b "*) BASES_3P="$BASES_3P $b" ;; esac
    done
    PX=$(grep -hiE '^[[:space:]]*proxy[[:space:]]*=' /etc/dnf/dnf.conf /etc/yum.conf 2>/dev/null | head -1 | sed 's/^[^=]*=[[:space:]]*//')
    [ -z "$PX" ] && command -v apt-config >/dev/null 2>&1 && PX=$(apt-config dump 2>/dev/null | grep -i '^Acquire::https\?::Proxy "' | head -1 | cut -d'"' -f2)
    [ -n "$PX" ] && note "INFO   server has a global proxy ($PX) - bypassed for Nexus repos"
    if [ -z "$BASES_OS" ]; then
      MODE=native; note "WARN   no Nexus reachable - falling back to native mode (existing repositories)"
      status WARN "$NX_TXT -> native mode"
    else
      case "$NX_TXT" in *DOWN*) status WARN "$NX_TXT" ;; *) status OK "$NX_TXT" ;; esac
    fi
  fi

  # 4 ---------------------------------------------------------------
  step "Repository plan"
  if [ "$MODE" = nexus ]; then
    rc=0
    if [ "$FAM" = yum ]; then
      scan_yum
      if build_core_yum; then
        build_3p_yum
        { echo "----- nexus-os.repo"; cat "$TMP/nexus-os.repo"
          echo "----- nexus-3p.repo"; cat "$TMP/nexus-3p.repo"; } >> "$FULL"
      else rc=1; fi
    else
      if build_core_apt; then
        : > "$TMP/kept"; build_3p_apt
        handle_esm
        [ "$N_REPL" -gt 0 ] && plan repl "old core lines" "$N_REPL line(s) replaced by nexus-os.list"
        [ "$N_DUP" -gt 0 ]  && plan dup  "duplicate lines" "$N_DUP line(s) disabled"
        { echo "----- nexus-os.list"; cat "$TMP/nexus-os.list"
          [ -s "$TMP/nexus-esm.list" ] && { echo "----- nexus-esm.list"; cat "$TMP/nexus-esm.list"; } ; } >> "$FULL"
      else rc=1; fi
    fi
    if [ $rc -ne 0 ]; then
      # core repos for this release are not on Nexus -> use the server's own repos
      MODE=native; N_CORE=0; N_3P=0; N_OFF=0; N_REPL=0; N_DUP=0; : > "$TMP/plan"
      sed -i 's/^FAIL   /WARN   /' "$REPORT"
      note "WARN   core repos for $OS_TXT not found on Nexus - native mode (existing repositories)"
    fi
  fi
  if [ "$MODE" = native ]; then
    native_plan
    status OK "native mode: ${N_NAT:-0} existing repositories, unchanged"
  elif [ "$N_OFF" -gt 0 ]; then status WARN "core=$N_CORE  3rd-party=$N_3P  disabled=$N_OFF"
  else status OK "core=$N_CORE  3rd-party=$N_3P"; fi
  show_plan

  # native mode: short timeouts, skip unreachable repos
  if [ "$MODE" = native ]; then
    YUM_OPTS="--setopt=timeout=30 --setopt=skip_if_unavailable=1"
    APT_OPTS="$APT_OPTS -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30"
  fi

  # 5 ---------------------------------------------------------------
  if [ "$DRY_RUN" = 1 ]; then
    step "Apply"; status SKIP "dry-run, nothing changed"; UPD=dry-run; finish 0
  fi
  if [ "$ASSUME_YES" != 1 ]; then
    if [ "$INTERACTIVE" = 1 ]; then
      say ""
      printf '  %sApply these changes on %s? [y/N]: %s' "$C_B" "$HOST" "$C_0"
      read -r ans < /dev/tty
      echo "  confirm answer: ${ans:-<empty>}" >> "$SUM"
      say ""
      case "$ans" in
        y|Y|yes|YES) ;;
        *) step "Confirmation"; status SKIP "cancelled by user, nothing changed"; UPD=cancelled; finish 8 ;;
      esac
      step "Confirmation"; status OK "confirmed by user"
    else
      step "Confirmation"; status FAIL "no terminal - use -y or ASSUME_YES=1"; UPD=cancelled; finish 8
    fi
  else
    step "Confirmation"; status OK "auto (-y)"
  fi

  # 6 ---------------------------------------------------------------
  step "Apply repo config"
  if [ "$MODE" = native ]; then
    status SKIP "native mode, repositories unchanged"
  else
    if [ "$FAM" = yum ]; then apply_yum; else apply_apt; fi \
      || { note "FAIL   backup/apply failed"; status FAIL "backup/apply failed"; finish 3; }
    status OK "backup -> $BAK_DIR"
  fi

  # 7 ---------------------------------------------------------------
  step "Refresh metadata"
  if [ "$MODE" = native ]; then refresh_native
  elif [ "$FAM" = yum ]; then refresh_yum || finish 3
  else refresh_apt || finish 3; fi

  # 8 ---------------------------------------------------------------
  step "Upgrade packages"
  if [ "$DO_UPDATE" != 1 ]; then
    status SKIP "--no-update"
  else
    level_menu                    # count by severity, ask (or take --level)
    apply_level                   # resolve LEVEL -> SEC_OPT, LVL_TXT, SEC_MODE
    if [ "$SEC_MODE" = none ]; then
      UPD=skipped; status SKIP "level: nothing ($LVL_TXT)"
    else
    pkg_list > "$TMP/pk0"; t0=$(date +%s)
    log "update level: $LEVEL ($LVL_TXT), opt: $SEC_OPT"
    if [ "$MODE" = native ]; then upgrade_native
    elif [ "$FAM" = yum ]; then upgrade_yum
    else upgrade_apt; fi; rc=$?
    pkg_list > "$TMP/pk1"
    PKG=$(comm -13 "$TMP/pk0" "$TMP/pk1" | wc -l | tr -d ' ')
    if [ "$rc" -eq 0 ]; then
      t0=$(( $(date +%s) - t0 ))
      UPD=ok
      if [ -n "$UPG_SKIPPED" ]; then
        status WARN "$PKG packages in $(printf '%d:%02d' $((t0 / 60)) $((t0 % 60))), skipped:$UPG_SKIPPED"
      else
        status OK "$PKG packages new/updated in $(printf '%d:%02d' $((t0 / 60)) $((t0 % 60)))"
      fi
    else
      UPD=failed; note "FAIL   upgrade failed (exit $rc) - see full log"
      status FAIL "see full log"; finish 4
    fi
    fi
  fi

  # 9 ---------------------------------------------------------------
  step "Verify up-to-date"
  verify_uptodate

  # 10 --------------------------------------------------------------
  step "App packages"
  app_packages

  # 11 --------------------------------------------------------------
  step "Reboot check"
  case "$FAM" in
    yum) reboot_need_yum ;; apt) reboot_need_apt ;; zypper) reboot_need_zypper ;;
  esac
  kernel_state
  # grub points at an older kernel than the newest installed -> offer to fix
  if [ "$KSTATE" = grub ]; then
    note "WARN   $KMSG"
    status WARN "grub default is an older kernel"
    if [ "$INTERACTIVE" = 1 ] && [ "$ASSUME_YES" != 1 ]; then
      printf '  Fix grub default to %s now? [y/N]: ' "$NEW_K" >&2; read -r ans < /dev/tty
      echo "  grub fix confirm: ${ans:-<empty>}" >> "$SUM"
      case "$ans" in y|Y|yes|YES) fix_grub_default && kernel_state ;; esac
    else
      note "INFO   fix by hand: grubby --set-default /boot/vmlinuz-$NEW_K"
    fi
    RBR=yes
  fi
  if [ "$RBR" != yes ] && [ "$KSTATE" = ok ]; then
    status OK "not required"
  elif [ "$RBR" = yes ] || [ "$KSTATE" != ok ]; then
    if [ "$REBOOT" = 1 ]; then
      shutdown -r +1 "server_update: new kernel" >/dev/null 2>&1
      note "INFO   reboot scheduled in 1 minute (cancel: shutdown -c)"
      status WARN "rebooting in 1 minute"
    else
      note "INFO   new kernel installed - reboot manually (or run with --reboot)"
      [ "$KSTATE" = grub ] || status WARN "required - reboot manually"
    fi
  else
    status OK "not required"
  fi
  finish 0
}

[ "${NX_SOURCE_ONLY:-0}" = 1 ] || main "$@"
