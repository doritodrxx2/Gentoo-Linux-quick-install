#!/usr/bin/env bash
# =============================================================================
# gentoo-quick-install.sh
# Gentoo installer that uses PRE-BUILT BINARY packages from the official binhost.
#
# Target : amd64, UEFI (Secure Boot disabled), OpenRC, KDE Plasma, GRUB, prebuilt kernel
# Run    : as root from Gentoo LiveGUI/Live ISO, or a supported Arch/Artix host
#
#   sudo bash gentoo-quick-install.sh                          interactive
#   sudo bash gentoo-quick-install.sh --dry-run                show the plan, change nothing
#   sudo bash gentoo-quick-install.sh --unattended --config install.conf
#
# Unattended mode reads KEY=VALUE answers from the config file. Passwords are
# NEVER read from the config file: use environment variables (see --help).
#
# WARNING: wipes the ENTIRE disk you pick. Test in a VM first.
# Log    : /tmp/gentoo-install.log (passwords are never written to it)
# =============================================================================
set -Eeuo pipefail
umask 077
GQI_TMPDIR_CREATED=0
if [[ -z ${GQI_TMPDIR:-} ]]; then
  GQI_TMPDIR=$(mktemp -d -t gqi.XXXXXX) || { echo "mktemp failed" >&2; exit 1; }
  chmod 700 "$GQI_TMPDIR"
  GQI_TMPDIR_CREATED=1
fi

# ----------------------------------------------------------------------------
# State
# ----------------------------------------------------------------------------
LOG=${GQI_LOG:-/tmp/gentoo-install.log}
MNT=${GQI_MNT:-/mnt/gentoo}
GQI_TMPDIR=${GQI_TMPDIR:-}
DIST=https://distfiles.gentoo.org/releases/amd64/autobuilds
DRY_RUN=0
UNATTENDED=0
CONFIG_FILE=""
CLEANED=0
CLEANUP_OK=1
TARGET_MOUNTED=0     # 1 once our root filesystem is mounted on $MNT
LUKS_OPENED=0        # 1 once we opened the LUKS mapping
MOUNTS=()            # mounts created by this script (unmounted in reverse order)
SECRET_FILES=()      # files on the target holding secrets (removed on exit)
declare -A CFG=()    # raw KEY=VALUE pairs from the config file
ROOTPFX=""           # empty on a real system; tests point it at a fake tree

DM_MODE=sddm        # sddm | tty (tty = no display manager: official binhost has no SDDM binary)
DISK=""; BOOT_MODE=""; INIT=openrc; FS=ext4; LUKS=0; LUKS_PASS=""; LUKS_UUID=""
MAPPER=""; ROOT_FS_UUID=""; DESKTOP=kde; KERNEL=bin; JOBS=18; JOBS_AUTO=18
BINHOST_LEVEL=x86-64; BINPKG_MODE=bin-only; TZONE=UTC; LOCALE=en_US.UTF-8; KEYMAP=us
XKB_LAYOUT=us; XKB_VARIANT=""; TARGET_HOST=gentoo; NETMGR="nm"
SWAP=none; SWAP_SIZE_MB=0; ROOT_PASS=""; CONFIRM_ERASE=""
USER_NAMES=(); USER_PASSES=(); USER_SUDO=()
EXTRAS=""; EXTRA_NAMES=""
THREADS=1; MEM_GB=1; RAM_MB=1024
STAGE3_REL=""
WORLD_UPDATE=best-effort
CHECKED_IDX=(); MENU_IDX=0; MENU_VAL=""; ANS=""; PICK=""

# Optional extra packages: key | label | Gentoo atom
X_KEYS=(git vim htop bash-completion fastfetch firefox)
X_LABELS=("git" "vim" "htop" "bash-completion" "fastfetch" "Firefox (firefox-bin)")
X_ATOMS=(dev-vcs/git app-editors/vim sys-process/htop app-shells/bash-completion app-misc/fastfetch www-client/firefox-bin)

# Command -> Gentoo package that provides it (used to suggest what to install).
declare -A PKG_FOR=(
  [sgdisk]=sys-apps/gptfdisk     [partprobe]=sys-block/parted
  [lsblk]=sys-apps/util-linux    [blkid]=sys-apps/util-linux
  [wipefs]=sys-apps/util-linux   [mount]=sys-apps/util-linux
  [umount]=sys-apps/util-linux   [mountpoint]=sys-apps/util-linux
  [swapon]=sys-apps/util-linux   [swapoff]=sys-apps/util-linux
  [mkswap]=sys-apps/util-linux   [fallocate]=sys-apps/util-linux
  [udevadm]=sys-fs/udev          [mkfs.ext4]=sys-fs/e2fsprogs
  [chattr]=sys-fs/e2fsprogs      [mkfs.vfat]=sys-fs/dosfstools
  [mkfs.xfs]=sys-fs/xfsprogs     [mkfs.btrfs]=sys-fs/btrfs-progs
  [cryptsetup]=sys-fs/cryptsetup [gpg]=app-crypt/gnupg
  [sha512sum]=sys-apps/coreutils [gzip]=app-arch/gzip
  [python3]=dev-lang/python      [tar]=app-arch/tar
  [chroot]=sys-apps/coreutils
  [curl]=net-misc/curl           [wget]=net-misc/wget
)

# ----------------------------------------------------------------------------
# UI helpers and traps
# ----------------------------------------------------------------------------
C_B=$'\e[1m'; C_G=$'\e[32m'; C_R=$'\e[31m'; C_Y=$'\e[33m'; C_C=$'\e[36m'; C_0=$'\e[0m'
msg()  { printf '\n%s==>%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s!!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
plan() { printf '    [plan] %s\n' "$*"; }
# run CMD... : executes CMD, or only prints it in dry-run mode
run() {
  if (( DRY_RUN )); then printf '    [dry-run] %s\n' "$*"; return 0; fi
  "$@"
}

on_err() {
  local rc=$1 line=$2
  printf '%sERROR:%s a command failed (exit %s, line %s). Log: %s\n' \
    "$C_R" "$C_0" "$rc" "$line" "$LOG" >&2
  exit "$rc"
}

# Unmount/close/erase in every exit path: normal end, error, Ctrl-C, kill.
on_exit() {
  local rc=$?
  trap - ERR INT TERM HUP
  trap '' INT TERM HUP
  set +e
  if (( ! CLEANED )); then
    CLEANED=1
    [[ -t 1 ]] && tput cnorm 2>/dev/null || true
    cleanup_target
  fi
  if (( ! CLEANUP_OK )); then
    printf '%sCleanup incomplete: some mounts, swap or LUKS devices could not be removed.%s\n' "$C_R" "$C_0" >&2
  elif (( rc != 0 )); then
    printf '%sCleanup finished (secrets removed, target unmounted).%s\n' "$C_Y" "$C_0" >&2
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'on_err $? $LINENO' ERR

# Order matters: secrets first, then pseudo filesystems, /efi, /boot, /, then LUKS.
# Only undoes work this script actually did (TARGET_MOUNTED / LUKS_OPENED / SECRET_FILES).
# In --dry-run those flags stay 0, so nothing is unmounted, deleted or closed.
cleanup_target() {
  local f mp i rc
  # install_stage3 may have failed while cwd was inside $MNT; a mounted cwd
  # can keep the target busy and prevent recursive unmount/LUKS close.
  cd / 2>/dev/null || true
  # Never perform disk/mount side-effects during a dry-run simulation.
  if (( DRY_RUN )); then
    ROOT_PASS=""; LUKS_PASS=""; USER_PASSES=()
    SECRET_FILES=()
    if (( GQI_TMPDIR_CREATED )) && [[ -n ${GQI_TMPDIR:-} ]]; then rm -rf -- "$GQI_TMPDIR"; fi
    return 0
  fi
  for f in ${SECRET_FILES[@]+"${SECRET_FILES[@]}"}; do
    rm -f -- "$f" 2>/dev/null || { warn "could not remove secret file $f"; CLEANUP_OK=0; }
  done
  SECRET_FILES=()
  # Remove installer-owned temporary directory.
  if (( GQI_TMPDIR_CREATED )) && [[ -n ${GQI_TMPDIR:-} ]]; then
    rm -rf -- "$GQI_TMPDIR" 2>/dev/null || { warn "could not remove $GQI_TMPDIR"; CLEANUP_OK=0; }
  fi
  if (( TARGET_MOUNTED )); then
    # Only remove installer-owned secret helpers under the target we mounted.
    for f in "$MNT/root/install.env" "$MNT/root/secrets.env" "$MNT/root/stage2.sh"; do
      if [[ -e $f ]]; then rm -f -- "$f" 2>/dev/null || { warn "could not remove $f"; CLEANUP_OK=0; }; fi
    done
    sync 2>/dev/null || true
    if [[ -f $MNT/swapfile ]]; then
      if ! swapoff "$MNT/swapfile" 2>/dev/null; then
        warn "could not swapoff $MNT/swapfile"
        CLEANUP_OK=0
      fi
    fi
    # Unmount only mounts this script recorded, in reverse order.
    # Keep failed mounts registered; never clear the list before removal is proven.
    local -a remaining=()
    for (( i = ${#MOUNTS[@]} - 1; i >= 0; i-- )); do
      mp=${MOUNTS[i]}
      if mountpoint -q "$mp" 2>/dev/null; then
        # /sys and /dev were mounted with --rbind, so remove their nested
        # mounts (pts, shm, efivars, etc.) as part of the same cleanup.
        if ! umount -R "$mp" 2>/dev/null; then
          # Fallback for systems whose umount does not support recursive mode.
          if ! umount "$mp" 2>/dev/null; then
            warn "could not unmount $mp (including nested mounts)"
            remaining+=("$mp")
          fi
        fi
      fi
    done
    # A later recursive unmount of a parent can remove a child that failed
    # earlier. Re-check the actual mount table before deciding LUKS can close.
    local -a still_mounted=()
    for mp in "${remaining[@]}"; do
      if mountpoint -q "$mp" 2>/dev/null; then still_mounted+=("$mp"); fi
    done
    if (( ${#still_mounted[@]} > 0 )); then
      CLEANUP_OK=0
      MOUNTS=()
      for (( i = ${#still_mounted[@]} - 1; i >= 0; i-- )); do
        MOUNTS+=("${still_mounted[i]}")
      done
    else
      MOUNTS=()
      TARGET_MOUNTED=0
    fi
  fi
  # Close LUKS only when all recorded mounts are gone; keep state on failure.
  if (( LUKS_OPENED )) && [[ -n $MAPPER ]]; then
    if (( ${#MOUNTS[@]} == 0 )); then
      if ! cryptsetup close "$MAPPER" 2>/dev/null; then
        warn "could not close LUKS mapping $MAPPER"
        CLEANUP_OK=0
      else
        LUKS_OPENED=0
      fi
    else
      warn "LUKS mapping $MAPPER left open because mounts remain"
      CLEANUP_OK=0
    fi
  fi
  ROOT_PASS=""; LUKS_PASS=""; USER_PASSES=()
}

# ----------------------------------------------------------------------------
# Interactive widgets (menu, checklist, ask) - unchanged behaviour
# ----------------------------------------------------------------------------
menu() {
  local title=$1; shift
  local -a opts=("$@")
  local n=${#opts[@]} sel=0 i key="" rest="" first=1
  printf '\n%s%s%s\n' "$C_B" "$title" "$C_0"
  printf '%s(arrow keys or number keys, Enter to confirm)%s\n' "$C_C" "$C_0"
  [[ -t 1 ]] && tput civis 2>/dev/null || true
  while true; do
    (( first )) || printf '\e[%dA' "$n"
    first=0
    for ((i = 0; i < n; i++)); do
      if (( i == sel )); then
        printf '\e[2K  %s> %d) %s%s\n' "$C_G$C_B" $((i + 1)) "${opts[i]}" "$C_0"
      else
        printf '\e[2K    %d) %s\n' $((i + 1)) "${opts[i]}"
      fi
    done
    key=""; rest=""
    if ! IFS= read -rsn1 key; then
      [[ -t 1 ]] && tput cnorm 2>/dev/null || true
      die "Input closed; cancelling menu to avoid choosing an unintended option."
    fi
    case $key in
      $'\e') read -rsn2 -t 0.05 rest || true
             case $rest in
               '[A') sel=$(( (sel + n - 1) % n )) ;;
               '[B') sel=$(( (sel + 1) % n )) ;;
             esac ;;
      k) sel=$(( (sel + n - 1) % n )) ;;
      j) sel=$(( (sel + 1) % n )) ;;
      '') break ;;
      [1-9]) if (( key <= n )); then sel=$(( key - 1 )); break; fi ;;
    esac
  done
  [[ -t 1 ]] && tput cnorm 2>/dev/null || true
  MENU_IDX=$sel
  MENU_VAL=${opts[sel]}
}

checklist() {
  local title=$1; shift
  local -a opts=("$@") on=()
  local n=${#opts[@]} sel=0 i key="" rest="" first=1 mark
  for ((i = 0; i < n; i++)); do on[i]=0; done
  printf '\n%s%s%s\n' "$C_B" "$title" "$C_0"
  printf '%s(arrows move, Space or number toggles, Enter confirms)%s\n' "$C_C" "$C_0"
  [[ -t 1 ]] && tput civis 2>/dev/null || true
  while true; do
    (( first )) || printf '\e[%dA' "$n"
    first=0
    for ((i = 0; i < n; i++)); do
      mark="[ ]"; (( on[i] )) && mark="[x]"
      if (( i == sel )); then
        printf '\e[2K  %s> %d) %s %s%s\n' "$C_G$C_B" $((i + 1)) "$mark" "${opts[i]}" "$C_0"
      else
        printf '\e[2K    %d) %s %s\n' $((i + 1)) "$mark" "${opts[i]}"
      fi
    done
    key=""; rest=""
    if ! IFS= read -rsn1 key; then
      [[ -t 1 ]] && tput cnorm 2>/dev/null || true
      die "Input closed; cancelling checklist."
    fi
    case $key in
      $'\e') read -rsn2 -t 0.05 rest || true
             case $rest in
               '[A') sel=$(( (sel + n - 1) % n )) ;;
               '[B') sel=$(( (sel + 1) % n )) ;;
             esac ;;
      k) sel=$(( (sel + n - 1) % n )) ;;
      j) sel=$(( (sel + 1) % n )) ;;
      ' ') on[sel]=$(( 1 - on[sel] )) ;;
      '') break ;;
      [1-9]) if (( key <= n )); then on[key-1]=$(( 1 - on[key-1] )); sel=$(( key - 1 )); fi ;;
    esac
  done
  [[ -t 1 ]] && tput cnorm 2>/dev/null || true
  CHECKED_IDX=()
  for ((i = 0; i < n; i++)); do (( on[i] )) && CHECKED_IDX+=("$i"); done
  return 0
}

ask() {  # ask "prompt" [default]
  local p=$1 d=${2:-} r=""
  if ! read -r -e -p "$p${d:+ [$d]}: " r; then
    die "Input closed while asking: $p"
  fi
  ANS=${r:-$d}
}

ask_secret() {  # ask_secret "prompt": asks twice, must match, not empty
  local p=$1 a="" b=""
  while true; do
    read -rsp "$p: " a; echo
    read -rsp "Repeat to confirm: " b; echo
    if [[ -n $a && $a == "$b" && ! $a =~ [[:cntrl:]] ]]; then break; fi
    warn "Empty, different or invalid. Try again."
  done
  ANS=$a
}

pick_from_list() {  # pick_from_list "what" file
  local what=$1 file=$2 filter="" n=0
  local -a matches=()
  while true; do
    ask "Search $what (type part of the name, e.g. 'sao' or 'pt_BR')"
    filter=$ANS
    mapfile -t matches < <(grep -i -- "$filter" "$file" | head -n 50 || true)
    n=${#matches[@]}
    if (( n == 0 )); then warn "No matches. Try again."; continue; fi
    if (( n > 8 )); then
      warn "Too many matches ($n+). Type more letters. Examples:"
      printf '    %s\n' "${matches[@]:0:6}"
      continue
    fi
    menu "Matches for '$filter'" "${matches[@]}" "Search again"
    if (( MENU_IDX < n )); then PICK=${matches[MENU_IDX]}; return 0; fi
  done
}

# ----------------------------------------------------------------------------
# Network
# ----------------------------------------------------------------------------
fetch() {  # fetch URL OUTFILE
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$2" "$1"
  else
    wget --tries=3 --timeout=30 -O "$2" "$1"
  fi
}

# Lightweight availability/compatibility check for a binhost Packages index.
url_available() {  # url -> return 0 when reachable
  if command -v curl >/dev/null 2>&1; then
    curl -fsIL --retry 2 --retry-delay 2 --connect-timeout 15 "$1" >/dev/null 2>&1
  else
    wget --spider -q --tries=2 --timeout=30 "$1" 2>/dev/null
  fi
}

# Download two related files concurrently; both must succeed.
fetch_pair() {  # url1 out1 url2 out2
  local p1 p2 rc1 rc2
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$2" "$1" & p1=$!
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$4" "$3" & p2=$!
  else
    wget --tries=3 --timeout=30 -O "$2" "$1" & p1=$!
    wget --tries=3 --timeout=30 -O "$4" "$3" & p2=$!
  fi
  if wait "$p1"; then rc1=0; else rc1=$?; fi
  if wait "$p2"; then rc2=0; else rc2=$?; fi
  if (( rc1 != 0 || rc2 != 0 )); then
    rm -f -- "$2" "$4"
    die "Download failed: $([[ $rc1 -ne 0 ]] && echo "$1" || echo "$3")"
  fi
}
have_net() { fetch https://distfiles.gentoo.org/ /dev/null >/dev/null 2>&1; }

wifi_connect() {
  if ! command -v nmcli >/dev/null 2>&1; then
    warn "nmcli not found; use the net-setup option instead."
    return 0
  fi
  nmcli radio wifi on || true
  nmcli -f SSID,SIGNAL,SECURITY dev wifi list || true
  local ssid pass=""
  ask "Wi-Fi name (SSID)"; ssid=$ANS
  read -rsp "Wi-Fi password (empty = open network): " pass; echo
  if [[ -n $pass ]]; then
    nmcli dev wifi connect "$ssid" password "$pass" || warn "Could not connect."
  else
    nmcli dev wifi connect "$ssid" || warn "Could not connect."
  fi
  pass=""
  sleep 3
}

network_setup() {
  if (( DRY_RUN )); then plan "network check skipped in dry-run"; return 0; fi
  if (( UNATTENDED )); then
    have_net || die "No internet access (needed to download the stage3 and the binhost)."
    return 0
  fi
  until have_net; do
    warn "No internet access."
    menu "How do you want to connect?" \
      "Retry (wired / DHCP)" \
      "Wi-Fi (nmcli)" \
      "Manual setup (net-setup)" \
      "Quit"
    case $MENU_IDX in
      0) if command -v dhcpcd >/dev/null 2>&1; then dhcpcd -n >/dev/null 2>&1 || true; fi; sleep 3 ;;
      1) wifi_connect ;;
      2) if command -v net-setup >/dev/null 2>&1; then net-setup || true; else warn "net-setup not available."; fi ;;
      3) exit 1 ;;
    esac
  done
  msg "Internet OK."
  if command -v chronyd >/dev/null 2>&1; then
    chronyd -q 'pool pool.ntp.org iburst' >/dev/null 2>&1 || true
  fi
}

# ----------------------------------------------------------------------------
# Detection
# ----------------------------------------------------------------------------
cpu_has_v3() {
  local common_flags f
  # Use the intersection of flags across all logical CPUs, not the union: the
  # selected binhost ABI must be safe on every CPU the kernel may schedule on.
  common_flags=$(awk '
    /^flags[[:space:]]*:/ {
      for (i=2; i<=NF; i++) current[$i]=1
      if (!seen++) { for (f in current) common[f]=1 }
      else { for (f in common) if (!(f in current)) delete common[f] }
      delete current
    }
    END { for (f in common) printf "%s ", f }
  ' /proc/cpuinfo 2>/dev/null) || return 1
  [[ -n $common_flags ]] || return 1
  # x86-64-v3 baseline per the psABI. Linux's avx flag indicates usable AVX
  # state (including OSXSAVE/XCR0 support), so do not infer this from avx2 alone.
  for f in cx16 lahf_lm popcnt pni ssse3 sse4_1 sse4_2 avx avx2 fma bmi1 bmi2 f16c movbe; do
    [[ " $common_flags " == *" $f "* ]] || return 1
  done
  # Linux x86 commonly names CPUID's LZCNT capability "abm" (AMD bit
  # manipulation); some kernels/tooling also expose the alias "lzcnt".
  [[ " $common_flags " == *" abm "* || " $common_flags " == *" lzcnt "* ]] || return 1
  return 0
}

detect_resources() {
  THREADS=$(nproc)
  RAM_MB=$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)
  MEM_GB=$(awk '/MemTotal/ {print int(($2 + 524288) / 1048576)}' /proc/meminfo)
  : "${MEM_GB}"
  # Default parallelism is fixed at 18 jobs (-j18), regardless of nproc.
  JOBS_AUTO=18
  if [[ -d /sys/firmware/efi ]]; then BOOT_MODE=uefi; else BOOT_MODE=bios; fi
}

# Swap default: RAM-sized, but never less than 2 GiB or more than 8 GiB.
default_swap_mb() {
  local s=$RAM_MB
  (( s < 2048 )) && s=2048
  (( s > 8192 )) && s=8192
  echo "$s"
}

disk_is_whole() {
  [[ -b $DISK ]] || return 1
  local dtype
  dtype=$(lsblk -dno TYPE "$DISK" 2>/dev/null || true)
  [[ $dtype == disk ]] || return 1
  # External/USB whole disks are allowed as install targets if they are not
  # mounted, active swap, the live-media disk, or the running system's disk.
  return 0
}

disk_is_valid() {
  if [[ -b $DISK ]]; then
    disk_is_whole || return 1
    return 0
  fi
  (( DRY_RUN )) && [[ -n ${GQI_TEST_FILE_DISK:-} && -f $DISK ]] && return 0   # tests only
  return 1
}

disk_is_safe_target() {
  # Basic path and validity checks.
  [[ -n ${DISK:-} ]] || return 1
  # DISK is canonicalized before validation, but resolve it here too for
  # library/tests that call this function directly.
  if [[ -L $DISK ]]; then DISK=$(readlink -f -- "$DISK") || return 1; fi
  disk_is_valid || return 1

  if [[ -b $DISK ]]; then
    # Reject any mounted partition (including the live install media).
    lsblk -lnro MOUNTPOINTS "$DISK" 2>/dev/null | grep '[^[:space:]]' >/dev/null && return 1
    # Reject active swap on the target.
    if command -v swapon >/dev/null 2>&1; then
      local p
      while IFS= read -r p; do
        [[ -z $p ]] && continue
        if swapon --show=NAME --noheadings 2>/dev/null | grep -Fx "/dev/$p" >/dev/null; then
          return 1
        fi
      done < <(lsblk -lnro NAME "$DISK" 2>/dev/null)
    fi
    # Reject LUKS/crypt containers or device-mapper dependencies on the target.
    if lsblk -lnro TYPE "$DISK" 2>/dev/null | grep -E 'crypt|lvm|raid' >/dev/null; then
      return 1
    fi
    if command -v dmsetup >/dev/null 2>&1; then
      local dep
      while IFS= read -r dep; do
        [[ -z $dep ]] && continue
        if lsblk -s -nro NAME "/dev/mapper/$dep" 2>/dev/null | grep -Fx "$(basename "$DISK")" >/dev/null; then
          return 1
        fi
      done < <(dmsetup info -c --noheadings -o name 2>/dev/null || true)
    fi
    # Reject the disk that hosts the running root filesystem.
    local root_part root_disk
    root_part=$(findmnt -no SOURCE / 2>/dev/null || true)
    if [[ -n $root_part && -b $root_part ]]; then
      root_disk=$(lsblk -no PKNAME "$root_part" 2>/dev/null || true)
      [[ -z $root_disk ]] && root_disk=$(basename "$root_part")
      [[ $(basename "$DISK") == "$root_disk" ]] && return 1
    fi
    # Reject if any partition of this disk is the live root's parent.
    if [[ -n $root_part && -b $root_part ]]; then
      local root_pkname
      root_pkname=$(lsblk -no PKNAME "$root_part" 2>/dev/null || true)
      [[ -n $root_pkname && $(basename "$DISK") == "$root_pkname" ]] && return 1
    fi
  else
    # Test mode: only an explicit fake disk file is accepted, and only in dry-run.
    if [[ ${GQI_TEST_FILE_DISK:-} == 1 && -f $DISK && $DRY_RUN -eq 1 ]]; then
      :
    else
      return 1
    fi
  fi
  return 0
}

disk_in_use() {
  [[ -b $DISK ]] || return 1
  lsblk -lnro MOUNTPOINTS "$DISK" 2>/dev/null | grep . >/dev/null && return 0
  return 1
}

disk_bytes() {
  if [[ -b $DISK ]]; then lsblk -bdno SIZE "$DISK" 2>/dev/null | head -n1
  else stat -c %s "$DISK" 2>/dev/null || echo 0
  fi
}

# Returns an error message on stdout for an invalid swap size, nothing if valid.
swap_size_error() {
  local mb=$1 max_mb
  [[ $mb =~ ^[0-9]+$ ]] || { echo "swap size must be a whole number of MiB"; return; }
  # Force base 10 so values such as 08 are not parsed as invalid octal.
  mb=$((10#$mb))
  (( mb >= 512 )) || { echo "swap size must be at least 512 MiB"; return; }
  (( mb <= 65536 )) || { echo "swap size must be at most 65536 MiB"; return; }
  max_mb=$(( $(disk_bytes) / 4 / 1048576 ))
  if (( max_mb > 0 && mb > max_mb )); then echo "swap larger than 25% of the disk (max ${max_mb} MiB)"; fi
}

# ----------------------------------------------------------------------------
# Preflight: every tool the chosen options need, checked BEFORE any change
# ----------------------------------------------------------------------------
required_tools() {  # prints the live-system commands needed by the current choices
  local -a t=(sgdisk partprobe lsblk blkid wipefs udevadm mkfs.ext4 tar chroot
              mount umount mountpoint gpg sha512sum gzip python3)
  [[ $BOOT_MODE == uefi ]] && t+=(mkfs.vfat)
  case $FS in
    xfs)   t+=(mkfs.xfs) ;;
    btrfs) t+=(mkfs.btrfs) ;;
  esac
  (( LUKS )) && t+=(cryptsetup)
  if [[ $SWAP == swapfile ]]; then
    t+=(mkswap swapon swapoff fallocate)
    [[ $FS == btrfs ]] && t+=(chattr)
  fi
  printf '%s\n' "${t[@]}"
}

preflight_tools() {
  local -a missing=() gentoo_pkgs=() host_pkgs=() needed=()
  local t p hp
  # Collect required tools into an array without process substitution.
  while IFS= read -r t; do
    [[ -n $t ]] && needed+=("$t")
  done <<< "$(required_tools)"
  for t in "${needed[@]}"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    missing+=("curl|wget")
  fi
  if (( ${#missing[@]} == 0 )); then
    msg "All required tools are present."
    return 0
  fi

  # Gentoo package names are used only when the installer itself is running
  # on Gentoo. On Arch/Artix hosts, install host utilities with pacman instead;
  # emerge is only available inside the target Gentoo chroot later.
  for t in "${missing[@]}"; do
    p=${PKG_FOR[$t]:-"(find the package that provides $t)"}
    [[ $t == curl\|wget ]] && p=net-misc/curl
    [[ " ${gentoo_pkgs[*]:-} " == *" $p "* ]] || gentoo_pkgs+=("$p")

    hp=""
    case "$t" in
      sgdisk) hp=gptfdisk ;;
      partprobe) hp=parted ;;
      lsblk|blkid|wipefs|mount|umount|mountpoint|swapon|swapoff|mkswap|fallocate) hp=util-linux ;;
      udevadm) hp=eudev ;;
      mkfs.ext4|chattr) hp=e2fsprogs ;;
      mkfs.vfat) hp=dosfstools ;;
      mkfs.xfs) hp=xfsprogs ;;
      mkfs.btrfs) hp=btrfs-progs ;;
      cryptsetup) hp=cryptsetup ;;
      gpg) hp=gnupg ;;
      sha512sum) hp=coreutils ;;
      gzip) hp=gzip ;;
      python3) hp=python ;;
      tar) hp=tar ;;
      chroot) hp=coreutils ;;
      curl\|wget) hp=curl ;;
    esac
    if [[ -n $hp && " ${host_pkgs[*]:-} " != *" $hp "* ]]; then
      host_pkgs+=("$hp")
    fi
  done

  warn "Missing tools: ${missing[*]}"
  if (( DRY_RUN )); then
    if command -v pacman >/dev/null 2>&1; then
      plan "dry-run: would install missing host utilities using pacman binary packages: ${host_pkgs[*]}"
    elif command -v emerge >/dev/null 2>&1; then
      plan "dry-run: would install missing host utilities using official Gentoo binary packages: ${gentoo_pkgs[*]}"
    else
      plan "dry-run: no supported package manager detected for missing host utilities"
    fi
    return 0
  fi
  if (( UNATTENDED )); then
    if command -v pacman >/dev/null 2>&1; then
      ((${#host_pkgs[@]})) || die "Could not map missing host tools to pacman packages: ${missing[*]}"
      pacman -S --needed --noconfirm "${host_pkgs[@]}" \
        || die "pacman could not install the required host utilities: ${host_pkgs[*]}. No target disk changes have been made."
    elif command -v emerge >/dev/null 2>&1; then
      emerge --ask=n --getbinpkgonly --usepkgonly --noreplace \
        --jobs=1 --load-average="$((JOBS + 1))" "${gentoo_pkgs[@]}" \
        || die "Official Gentoo binary packages could not provide the required host utilities: ${gentoo_pkgs[*]}. No target disk changes have been made."
    else
      die "Missing host tools ${missing[*]}; neither pacman nor emerge is available. No target disk changes have been made."
    fi
  else
    if command -v pacman >/dev/null 2>&1; then
      ((${#host_pkgs[@]})) || die "Could not map missing host tools to pacman packages: ${missing[*]}"
      menu "Install missing host utilities from binary packages using pacman? (No target disk changes yet)" \
        "Yes, pacman -S --needed --noconfirm ${host_pkgs[*]}" "No, quit"
      (( MENU_IDX == 0 )) || die "Install the host utilities first. No target disk changes have been made."
      pacman -S --needed --noconfirm "${host_pkgs[@]}" \
        || die "pacman could not install the required host utilities: ${host_pkgs[*]}. No target disk changes have been made."
    elif command -v emerge >/dev/null 2>&1; then
      menu "Install missing host utilities from official Gentoo binaries only?" \
        "Yes, emerge --getbinpkgonly --usepkgonly --noreplace ${gentoo_pkgs[*]}" "No, quit"
      (( MENU_IDX == 0 )) || die "Install the host utilities first. No target disk changes have been made."
      emerge --ask=n --getbinpkgonly --usepkgonly --binpkg-respect-use=n --noreplace \
        --jobs=1 --load-average="$((JOBS + 1))" "${gentoo_pkgs[@]}" \
        || die "Official Gentoo binary packages could not provide the required host utilities: ${gentoo_pkgs[*]}. No target disk changes have been made."
    else
      die "Missing host tools ${missing[*]}; neither pacman nor emerge is available. No target disk changes have been made."
    fi
  fi

  for t in "${missing[@]}"; do
    [[ $t == curl\|wget ]] && continue
    command -v "$t" >/dev/null 2>&1 || die "still missing after host package installation: $t. No target disk changes have been made."
  done
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    die "curl/wget still unavailable after host package installation. No target disk changes have been made."
  fi
  msg "Required host utilities are available; no target disk changes were made during preflight."
}

# ----------------------------------------------------------------------------
# Configuration: unattended file, validation, interactive questions
# ----------------------------------------------------------------------------
usage() {
  cat <<'USAGE'
Usage: gentoo-quick-install.sh [options]

  (no options)          interactive installation
  --dry-run             print the complete plan; does not partition, format,
                        encrypt, mount or change anything on this system
  --unattended, --yes   no questions; requires --config
  --config FILE         KEY=VALUE file (only with --unattended)
  -h, --help            this help

Config keys (defaults in brackets):
  DISK=/dev/sdX         disk to erase (required)
  CONFIRM_ERASE=/dev/sdX  must equal DISK (required, safety check)
  BOOT_MODE=uefi        [auto-detected; BIOS is not supported]
  INIT=openrc           [openrc] (systemd is not supported)
  FS=ext4|xfs|btrfs     [ext4]
  LUKS=yes|no           [no]     passphrase from env LUKS_PASSPHRASE
  DESKTOP=kde           [kde] (KDE Plasma is required)
  KERNEL=bin            [bin]    (only prebuilt kernel; source builds are not supported)
  JOBS=N                [default 18]
  CPU_LEVEL=x86-64-v3|x86-64  [auto]
  BINPKG_MODE=bin-only  [bin-only] (requires official binary dependency coverage; binaries preferred)
  HOSTNAME=name         [gentoo]
  TIMEZONE=Area/City    [UTC]
  LOCALE=en_US.UTF-8    [en_US.UTF-8]
  KEYMAP=us             [us]
  NETMGR=nm|dhcpcd       [nm] (KDE always uses nm)
  SWAP=none|swapfile    [none]
  SWAP_SIZE_MB=N        [RAM-sized, 2048..8192]
  WORLD_UPDATE=best-effort|required|skip   [best-effort]
                        attempt @world update; failures do not block boot setup; "skip" omits it
  USERS=name:sudo,other:nosudo   (required)
  EXTRAS=git vim htop bash-completion fastfetch firefox   [none]

Passwords come from the environment, never from the file:
  ROOT_PASSWORD, LUKS_PASSPHRASE
  The ROOT_PASSWORD is also assigned to every user listed in USERS.
USAGE
}

parse_args() {
  while (( $# )); do
    case $1 in
      --unattended|--yes|-y) UNATTENDED=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --config)
        shift; (( $# )) || die "--config needs a file name"
        CONFIG_FILE=$1 ;;
      --config=*) CONFIG_FILE=${1#*=} ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  if (( UNATTENDED )) && [[ -z $CONFIG_FILE ]]; then die "--unattended needs --config FILE"; fi
  if [[ -n $CONFIG_FILE ]] && (( ! UNATTENDED )); then die "--config only works with --unattended"; fi
}

load_config() {
  local f=$1 line key val n=0
  [[ -r $f ]] || die "Config file not readable: $f"
  local mode; mode=$(stat -c %a "$f" 2>/dev/null || echo "?")
  case $mode in 600|400) ;; *) warn "Config file permissions are $mode; consider chmod 600 $f" ;; esac
  while IFS= read -r line || [[ -n $line ]]; do
    n=$(( n + 1 ))
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -z $line ]] && continue
    [[ $line == *=* ]] || die "$f:$n: expected KEY=VALUE"
    key=${line%%=*}; val=${line#*=}
    val=${val#\"}; val=${val%\"}; val=${val#\'}; val=${val%\'}
    case $key in
      *PASS*|*SECRET*)
        die "$f:$n: passwords must not be in the config file; use environment variables" ;;
      DISK|BOOT_MODE|INIT|FS|LUKS|DESKTOP|KERNEL|JOBS|CPU_LEVEL|BINPKG_MODE|HOSTNAME|TIMEZONE|\
      LOCALE|KEYMAP|NETMGR|SWAP|SWAP_SIZE_MB|USERS|EXTRAS|CONFIRM_ERASE|WORLD_UPDATE)
        [[ -z ${CFG[$key]+x} ]] || die "$f:$n: $key is given twice"
        CFG[$key]=$val ;;
      *) die "$f:$n: unknown key: $key" ;;
    esac
  done < "$f"
}

# Turn CFG into the real variables, applying defaults. Interactive mode never calls this.
apply_config() {
  local entry name sud i
  DISK=${CFG[DISK]:-}
  CONFIRM_ERASE=${CFG[CONFIRM_ERASE]:-}
  BOOT_MODE=${CFG[BOOT_MODE]:-$BOOT_MODE}
  INIT=${CFG[INIT]:-openrc}
  FS=${CFG[FS]:-ext4}
  DESKTOP=${CFG[DESKTOP]:-kde}
  KERNEL=${CFG[KERNEL]:-bin}
  TARGET_HOST=${CFG[HOSTNAME]:-gentoo}
  TZONE=${CFG[TIMEZONE]:-UTC}
  LOCALE=${CFG[LOCALE]:-en_US.UTF-8}
  KEYMAP=${CFG[KEYMAP]:-us}
  NETMGR=${CFG[NETMGR]:-nm}
  SWAP=${CFG[SWAP]:-none}
  WORLD_UPDATE=${CFG[WORLD_UPDATE]:-best-effort}
  JOBS=${CFG[JOBS]:-$JOBS_AUTO}
  [[ $JOBS == auto ]] && JOBS=$JOBS_AUTO
  case ${CFG[CPU_LEVEL]:-auto} in
    auto) if cpu_has_v3; then BINHOST_LEVEL=x86-64-v3; else BINHOST_LEVEL=x86-64; fi ;;
    *) BINHOST_LEVEL=${CFG[CPU_LEVEL]:-x86-64} ;;
  esac
  case ${CFG[BINPKG_MODE]:-bin-only} in
    bin-only) BINPKG_MODE=bin-only ;;
    *) BINPKG_MODE=invalid ;;
  esac
  case ${CFG[LUKS]:-no} in
    yes|1) LUKS=1 ;;
    no|0)  LUKS=0 ;;
    *) LUKS=invalid ;;
  esac
  if [[ -n ${CFG[SWAP_SIZE_MB]:-} ]]; then SWAP_SIZE_MB=${CFG[SWAP_SIZE_MB]}
  else SWAP_SIZE_MB=$(default_swap_mb); fi
  if [[ $DESKTOP == kde ]]; then NETMGR="nm"; fi

  # Users: "name:sudo,other:nosudo"
  USER_NAMES=(); USER_SUDO=(); USER_PASSES=()
  if [[ -n ${CFG[USERS]:-} ]]; then
    IFS=',' read -ra entries <<< "${CFG[USERS]}"
    for entry in "${entries[@]}"; do
      entry=${entry//[[:space:]]/}
      [[ -z $entry ]] && continue
      name=${entry%%:*}; sud=nosudo
      [[ $entry == *:* ]] && sud=${entry#*:}
      case $sud in sudo) USER_SUDO+=(1) ;; nosudo) USER_SUDO+=(0) ;;
        *) die "USERS: bad flag '$sud' for $name (use sudo or nosudo)" ;; esac
      USER_NAMES+=("$name")
      # All regular user accounts use the same password as root/admin.
      USER_PASSES+=("")
    done
  fi

  # Extras
  EXTRAS=""; EXTRA_NAMES=""
  local x
  for x in ${CFG[EXTRAS]:-}; do
    local i found=0
    for i in "${!X_KEYS[@]}"; do
      if [[ $x == "${X_KEYS[i]}" ]]; then
        EXTRAS+="${X_ATOMS[i]} "; EXTRA_NAMES+="${X_LABELS[i]}, "; found=1
      fi
    done
    (( found )) || die "EXTRAS: unknown package '$x'"
  done

  ROOT_PASS=${ROOT_PASSWORD:-}
  LUKS_PASS=${LUKS_PASSPHRASE:-}
  # The administrator password is also the password for every created user.
  for i in "${!USER_PASSES[@]}"; do USER_PASSES[i]=$ROOT_PASS; done
  xkb_for "$KEYMAP"
}

# Every question is checked here, before anything destructive. Collects all problems.

normalize_disk_paths() {
  # Accept stable /dev/disk/by-id symlinks, but always validate/erase the
  # resolved whole-disk device, never a partition alias.
  if [[ -n ${DISK:-} && -L $DISK ]]; then
    DISK=$(readlink -f -- "$DISK") || die "Could not resolve DISK symlink"
  fi
  if [[ -n ${CONFIRM_ERASE:-} && -L $CONFIRM_ERASE ]]; then
    CONFIRM_ERASE=$(readlink -f -- "$CONFIRM_ERASE") || die "Could not resolve CONFIRM_ERASE symlink"
  fi
}

check_secure_boot_compatibility() {
  [[ ${BOOT_MODE:-} == uefi ]] || return 0
  local state_file state
  if command -v mokutil >/dev/null 2>&1; then
    state=$(mokutil --sb-state 2>/dev/null || true)
    if grep -qi 'SecureBoot enabled' <<< "$state"; then
      die "Secure Boot is enabled, but this installer does not enroll keys or sign the GRUB/kernel boot chain. Nothing has been erased; disable Secure Boot in firmware or use a signed-boot workflow."
    elif grep -qi 'SecureBoot disabled' <<< "$state"; then
      return 0
    fi
  fi
  shopt -s nullglob
  local -a vars=(/sys/firmware/efi/efivars/SecureBoot-*)
  shopt -u nullglob
  for state_file in "${vars[@]}"; do
    state=$(od -An -tu1 -j4 -N1 "$state_file" 2>/dev/null | tr -d '[:space:]')
    case $state in
      0) return 0 ;;
      1) die "Secure Boot is enabled, but this installer does not sign the boot chain. Nothing has been erased; disable Secure Boot or use a signed-boot workflow." ;;
    esac
  done
  die "Could not reliably determine Secure Boot state. For safety, no disk will be erased; install mokutil or ensure efivarfs is mounted and SecureBoot-* is readable."
}

validate_config() {
  local -a errs=()
  local i name dup j

  case $BOOT_MODE in uefi) ;; *) errs+=("BOOT_MODE must be uefi (BIOS is not supported by this installer)") ;; esac
  if [[ $BOOT_MODE == uefi ]] && (( ! DRY_RUN )) && [[ ! -d /sys/firmware/efi ]]; then
    errs+=("BOOT_MODE=uefi but this system did not boot in UEFI mode")
  fi
  case $INIT in openrc) ;; *) errs+=("INIT must be openrc (systemd is not supported by this installer)") ;; esac
  case $FS in ext4|xfs|btrfs) ;; *) errs+=("FS must be ext4, xfs or btrfs") ;; esac
  case $DESKTOP in kde) ;; *) errs+=("DESKTOP must be kde (KDE Plasma is required by this installer)") ;; esac
  case $KERNEL in bin) ;; *) errs+=("KERNEL must be bin (source kernel builds are disabled)") ;; esac
  [[ $LUKS == 0 || $LUKS == 1 ]] || errs+=("LUKS must be yes or no")
  [[ $JOBS =~ ^[1-9][0-9]?$ ]] && (( 10#$JOBS <= 64 )) || errs+=("JOBS must be an integer from 1 to 64; the default remains -j18")
  case $BINPKG_MODE in
    bin-only) ;;
    *) errs+=("BINPKG_MODE must be bin-only") ;;
  esac
  case $BINHOST_LEVEL in
    x86-64) ;;
    x86-64-v3)
      if ! cpu_has_v3 && (( ! DRY_RUN )); then errs+=("CPU_LEVEL=x86-64-v3 needs AVX2 and friends"); fi ;;
    *) errs+=("CPU_LEVEL must be x86-64-v3 or x86-64") ;;
  esac
  case $NETMGR in nm|dhcpcd) ;; *) errs+=("NETMGR must be nm or dhcpcd") ;; esac
  case $SWAP in none|swapfile) ;; *) errs+=("SWAP must be none or swapfile") ;; esac
  case $WORLD_UPDATE in best-effort|required|skip) ;; *) errs+=("WORLD_UPDATE must be best-effort, required or skip") ;; esac
  if [[ $SWAP == swapfile ]]; then
    local e; e=$(swap_size_error "$SWAP_SIZE_MB" || true)
    [[ -z $e ]] || errs+=("$e")
  fi

  # Disk
  if [[ -z $DISK ]]; then
    errs+=("DISK is empty")
  elif ! disk_is_valid; then
    errs+=("DISK $DISK is not a valid whole disk")
  elif ! disk_is_safe_target; then
    errs+=("DISK $DISK is unsafe (partition, mounted, active swap, encrypted dependency or the running system's disk)")
  fi
  if (( UNATTENDED )) && [[ $CONFIRM_ERASE != "$DISK" ]]; then
    errs+=("CONFIRM_ERASE must be set to exactly the DISK value ($DISK) for unattended erasure")
  fi

  # Identity and region
  [[ $TARGET_HOST =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || errs+=("HOSTNAME is invalid")
  if [[ -d /usr/share/zoneinfo ]]; then
    [[ -e /usr/share/zoneinfo/$TZONE ]] || errs+=("TIMEZONE $TZONE not found in /usr/share/zoneinfo")
  else
    warn "zoneinfo not available: TIMEZONE not checked"
  fi
  [[ $LOCALE =~ ^[a-zA-Z]{2,3}_[A-Z]{2}\.UTF-8$ ]] || errs+=("LOCALE must look like en_US.UTF-8")
  if [[ -f /usr/share/i18n/SUPPORTED ]]; then
    awk -v l="$LOCALE" '$2=="UTF-8" && $1==l {f=1} END {exit !f}' /usr/share/i18n/SUPPORTED \
      || errs+=("LOCALE $LOCALE is not a supported UTF-8 locale")
  fi
  [[ $KEYMAP =~ ^[A-Za-z0-9_.-]+$ ]] || errs+=("KEYMAP has invalid characters")

  # Users and passwords
  if (( ${#USER_NAMES[@]} == 0 )); then
    errs+=("at least one user is required (USERS=...)")
  fi
  for i in "${!USER_NAMES[@]}"; do
    name=${USER_NAMES[i]}
    [[ $name =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || errs+=("username '$name' is invalid")
    [[ $name == root ]] && errs+=("'root' is created automatically; do not list it")
    dup=0
    for j in "${!USER_NAMES[@]}"; do [[ $i != "$j" && ${USER_NAMES[j]} == "$name" ]] && dup=1; done
    (( dup )) && errs+=("user '$name' is listed twice")
    [[ -n ${USER_PASSES[i]:-} ]] || errs+=("administrator password is not set; it is also used for user '$name'")
  done
  # Reject empty, newline or control characters in passwords.
  if [[ -z $ROOT_PASS || $ROOT_PASS == *$'\n'* || $ROOT_PASS == *$'\r'* || $ROOT_PASS =~ [[:cntrl:]] ]]; then
    errs+=("root password is empty or contains invalid characters")
  fi
  for p in "${USER_PASSES[@]}"; do
    if [[ -z $p || $p == *$'\n'* || $p == *$'\r'* || $p =~ [[:cntrl:]] ]]; then
      errs+=("a user password is empty or contains invalid characters")
    fi
  done
  if [[ $LUKS == 1 ]] && (( ${#LUKS_PASS} < 8 )); then
    errs+=("LUKS passphrase must have at least 8 characters")
  fi

  if (( ${#errs[@]} > 0 )); then
    printf '%sInvalid configuration (nothing was changed):%s\n' "$C_R" "$C_0" >&2
    for i in "${errs[@]}"; do printf '  - %s\n' "$i" >&2; done
    die "fix the items above and run again"
  fi
  msg "Configuration validated."
}

# Interactive questions: fill the same variables that apply_config fills.
collect_users() {
  local name dup i
  while true; do
    while true; do
      ask "New username (lowercase letters, digits, - or _)"
      name=$ANS
      if [[ ! $name =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then warn "Invalid username."; continue; fi
      if [[ $name == root ]]; then warn "'root' is created automatically."; continue; fi
      dup=0
      for i in "${USER_NAMES[@]}"; do [[ $i == "$name" ]] && dup=1; done
      if (( dup )); then warn "That user is already in the list."; continue; fi
      break
    done
    USER_NAMES+=("$name")
    USER_PASSES+=("")
    menu "Give '$name' administrator rights (sudo)?" "Yes" "No"
    if (( MENU_IDX == 0 )); then USER_SUDO+=(1); else USER_SUDO+=(0); fi
    menu "Create another user?" "No, continue" "Yes, add another user"
    (( MENU_IDX == 0 )) && break
  done
}

collect_config() {
  local -a labels=() devs=()
  local line dev desc threads=$THREADS

  msg "Detected boot mode: ${BOOT_MODE^^}"

  # Disk
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    dev=${line%% *}
    desc=$line
    if lsblk -lnro MOUNTPOINTS "$dev" 2>/dev/null | grep . >/dev/null; then
      desc+="  [IN USE - probably the live USB]"
    fi
    labels+=("$desc"); devs+=("$dev")
  done < <(lsblk -dpno NAME,SIZE,MODEL -e 1,7,11)
  (( ${#devs[@]} > 0 )) || die "No disks found."
  menu "Which disk do you want to install on? (it will be COMPLETELY ERASED)" "${labels[@]}"
  DISK=${devs[MENU_IDX]}
  if [[ ${labels[MENU_IDX]} == *"IN USE"* ]]; then
    die "That disk is mounted (probably the install media). Pick another one."
  fi
  CONFIRM_ERASE=$DISK

  INIT=openrc
  msg "Init system: OpenRC (systemd is not supported by this installer)"

  DESKTOP=kde
  msg "Desktop: KDE Plasma (prebuilt binaries from the binhost)"
  NETMGR="nm"
  msg "Network manager: NetworkManager (KDE Plasma)"

  KERNEL=bin
  msg "Kernel: gentoo-kernel-bin (prebuilt binary only)"

  if cpu_has_v3; then
    menu "CPU optimization level" \
      "x86-64-v3 (uses AVX2 - recommended, your CPU supports it)" \
      "x86-64 (generic, runs on any CPU)"
    if (( MENU_IDX == 0 )); then BINHOST_LEVEL=x86-64-v3; else BINHOST_LEVEL=x86-64; fi
  else
    warn "Your CPU does not support x86-64-v3 (AVX2 etc.). Using generic x86-64 binaries."
    BINHOST_LEVEL=x86-64
  fi

  BINPKG_MODE=bin-only
  msg "Package source: official binpkgs preferred; source only if no usable binary exists"

  menu "Parallel jobs (emerge --jobs; your system has $threads logical CPUs)" \
    "Default: $JOBS_AUTO jobs (-j$JOBS_AUTO)" "Type a custom number"
  case $MENU_IDX in
    0) JOBS=$JOBS_AUTO ;;
    1) while true; do
         ask "Number of jobs" "$JOBS_AUTO"
         [[ $ANS =~ ^[1-9][0-9]{0,3}$ ]] && break
         warn "Invalid number."
       done
       JOBS=$ANS ;;
  esac

  menu "Root filesystem" "ext4" "xfs" "btrfs"
  FS=$MENU_VAL

  menu "Encrypt the disk with LUKS?" "No" "Yes (LUKS2 on the root partition; /boot stays separate)"
  LUKS=$MENU_IDX
  if (( LUKS )); then
    warn "LUKS is the least tested path of this installer. Try it in a virtual machine first."
    echo "Choose the disk encryption passphrase (asked at every boot). At least 8 characters."
    while true; do
      ask_secret "LUKS passphrase"; LUKS_PASS=$ANS
      (( ${#LUKS_PASS} >= 8 )) && break
      warn "Too short (8 characters minimum)."
    done
  fi

  menu "Swap" "None" "Swapfile on the root filesystem (recommended for compiling)"
  if (( MENU_IDX == 1 )); then
    SWAP=swapfile
    local def e
    def=$(default_swap_mb)
    while true; do
      ask "Swapfile size in MiB" "$def"
      e=$(swap_size_error "$ANS" || true)
      if [[ -z $e ]]; then SWAP_SIZE_MB=$ANS; break; fi
      warn "$e"
    done
  else
    SWAP=none; SWAP_SIZE_MB=0
  fi

  msg "Bootloader: GRUB (${BOOT_MODE^^})"

  NETMGR="nm"
  msg "Network manager: NetworkManager (KDE Plasma)"

  menu "Timezone" "America/Sao_Paulo" "America/New_York" "Europe/London" "Europe/Lisbon" "UTC" \
    "Other (search the full list)"
  if (( MENU_IDX < 5 )); then TZONE=$MENU_VAL
  elif [[ -s "$GQI_TMPDIR/zones.txt" ]]; then pick_from_list "timezone" "$GQI_TMPDIR/zones.txt"; TZONE=$PICK
  else
    while true; do
      ask "Timezone (e.g. America/Bahia)"
      [[ -e /usr/share/zoneinfo/$ANS ]] && { TZONE=$ANS; break; }
      warn "Not found in /usr/share/zoneinfo."
    done
  fi

  menu "System language (locale)" "en_US.UTF-8" "pt_BR.UTF-8" "es_ES.UTF-8" "de_DE.UTF-8" "fr_FR.UTF-8" \
    "Other (search the full list)"
  if (( MENU_IDX < 5 )); then LOCALE=$MENU_VAL
  elif [[ -s "$GQI_TMPDIR/locales.txt" ]]; then pick_from_list "locale" "$GQI_TMPDIR/locales.txt"; LOCALE=$PICK
  else
    while true; do
      ask "Locale (e.g. it_IT.UTF-8)"
      [[ $ANS =~ ^[a-z]{2,3}_[A-Z]{2}\.UTF-8$ ]] && { LOCALE=$ANS; break; }
      warn "Format must look like it_IT.UTF-8"
    done
  fi

  menu "Keyboard layout" \
    "us        (US English)" "br-abnt2  (Brazilian ABNT2)" "uk        (United Kingdom)" \
    "de        (German)" "fr        (French)" "es        (Spanish)" \
    "pt-latin1 (Portuguese)" "it        (Italian)" "Other (search the full list)"
  if (( MENU_IDX < 8 )); then KEYMAP=${MENU_VAL%% *}
  elif [[ -s "$GQI_TMPDIR/keymaps.txt" ]]; then pick_from_list "keyboard layout" "$GQI_TMPDIR/keymaps.txt"; KEYMAP=$PICK
  else
    ask "Keymap name (e.g. dvorak)" "us"; KEYMAP=$ANS
  fi
  if (( ! DRY_RUN )); then loadkeys "$KEYMAP" 2>/dev/null || true; fi
  xkb_for "$KEYMAP"

  while true; do
    ask "Hostname (computer name)" "gentoo"
    [[ $ANS =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] && break
    warn "Invalid hostname (letters, digits and hyphen only)."
  done
  TARGET_HOST=$ANS

  echo
  echo "Now create your user account(s)."
  collect_users
  echo
  echo "Set the administrator password. This will also be used for every created user."
  ask_secret "Administrator/root password"; ROOT_PASS=$ANS
  for i in "${!USER_PASSES[@]}"; do USER_PASSES[i]=$ROOT_PASS; done

  checklist "Extra packages (installed from binaries)" "${X_LABELS[@]}"
  EXTRAS=""; EXTRA_NAMES=""
  local i
  for i in "${CHECKED_IDX[@]}"; do
    EXTRAS+="${X_ATOMS[i]} "
    EXTRA_NAMES+="${X_LABELS[i]}, "
  done
}

# Keymap -> X11 layout (for KDE)
xkb_for() {
  case $1 in
    br-abnt2)   XKB_LAYOUT=br; XKB_VARIANT=abnt2 ;;
    uk)         XKB_LAYOUT=gb; XKB_VARIANT="" ;;
    pt-latin1)  XKB_LAYOUT=pt; XKB_VARIANT="" ;;
    us|de|fr|es|it) XKB_LAYOUT=$1; XKB_VARIANT="" ;;
    *)          XKB_LAYOUT=us; XKB_VARIANT=""
                warn "Keymap '$1' has no known X11 layout; KDE will use layout 'us'. Edit /etc/X11/xorg.conf.d/00-keyboard.conf after install." ;;
  esac
  : "${XKB_LAYOUT}" "${XKB_VARIANT}"
}

# Searchable lists for interactive pickers (built only when interactive).
build_lists() {
  : > "$GQI_TMPDIR/zones.txt"; : > "$GQI_TMPDIR/locales.txt"; : > "$GQI_TMPDIR/keymaps.txt"
  if [[ -d /usr/share/zoneinfo ]]; then
    (cd /usr/share/zoneinfo \
      && find . \( -type f -o -type l \) \
      | sed 's|^\./||' \
      | grep -E '^(Africa|America|Antarctica|Arctic|Asia|Atlantic|Australia|Europe|Indian|Pacific)/' \
      | sort) > "$GQI_TMPDIR/zones.txt" || true
    echo UTC >> "$GQI_TMPDIR/zones.txt"
  fi
  if [[ -f /usr/share/i18n/SUPPORTED ]]; then
    awk '$2 == "UTF-8" {print $1}' /usr/share/i18n/SUPPORTED | sort -u > "$GQI_TMPDIR/locales.txt" || true
  fi
  find /usr/share/keymaps /usr/share/kbd/keymaps -name '*.map.gz' 2>/dev/null \
    | sed -E 's|.*/||; s|\.map\.gz$||' | sort -u > "$GQI_TMPDIR/keymaps.txt" || true
}

summary() {
  local i users="" s extras
  for i in "${!USER_NAMES[@]}"; do
    s=""; [[ ${USER_SUDO[i]} == 1 ]] && s=" (sudo)"
    users+="${USER_NAMES[i]}$s, "
  done
  extras=${EXTRA_NAMES%, }
  (( DRY_RUN )) || clear 2>/dev/null || true
  printf '%s=== Summary%s ===%s\n' "$C_B" "$( (( DRY_RUN )) && echo ' (DRY RUN - nothing will be changed)')" "$C_0"
  cat <<EOF
 Disk        : $DISK   (WILL BE ERASED)
 Boot        : $BOOT_MODE + GRUB
 Init        : $INIT   (profile: $( [[ $DESKTOP == kde ]] && echo "desktop/plasma$( [[ $INIT == systemd ]] && echo /systemd)" || echo "base$( [[ $INIT == systemd ]] && echo ' systemd')" ))
 Desktop     : $( [[ $DESKTOP == kde ]] && echo 'KDE Plasma, minimal (shell only, no KDE apps; login via SDDM, or tty1 if SDDM has no binary)' || echo 'none (terminal)' )
 Kernel      : gentoo-kernel-bin (prebuilt payload, nothing compiled)
 Packages    : official binpkgs preferred; source build only when no usable binary exists
 CPU level   : $BINHOST_LEVEL $( [[ $BINHOST_LEVEL == x86-64-v3 ]] && echo '(AVX2)' )
 Jobs        : $JOBS (default -j18 for per-package build parallelism; package merges are serialized)
 Root FS     : $FS  $( (( LUKS )) && echo '+ LUKS2' || echo '(no encryption)' )
 Swap        : $( [[ $SWAP == swapfile ]] && echo "swapfile ${SWAP_SIZE_MB} MiB" || echo 'none' )
 Network     : $NETMGR
 Timezone    : $TZONE
 Language    : $LOCALE
 Keyboard    : $KEYMAP
 Hostname    : $TARGET_HOST
 Users       : ${users%, }
 Extras      : ${extras:-none}
EOF
}

# ----------------------------------------------------------------------------
# Installation (destructive part; every command goes through run/plan)
# ----------------------------------------------------------------------------
# Lightweight check of the official binary package indexes BEFORE wipefs/sgdisk.
# Full Portage dependency resolution remains in the target before the first merge.
preflight_binhost_before_wipe() {
  (( DRY_RUN )) && { plan "pre-wipe check: verify official Gentoo binhost Packages index and required atoms"; return 0; }

  # The current stage3/profile generation is 23.0. Override if Gentoo changes it.
  local profver=${GQI_PREFLIGHT_PROFILE_VERSION:-23.0}
  local base_url="https://distfiles.gentoo.org/releases/amd64/binpackages/$profver/x86-64/Packages"
  # gentoo-kernel-bin / linux-firmware are payload ebuilds (not binhost packages): not checked here.
  local -a urls=("$base_url") atoms=(sys-boot/grub)
  local url idx atom found outfile
  if [[ $BOOT_MODE == uefi ]]; then atoms+=(sys-boot/efibootmgr); fi
  if [[ $DESKTOP == kde ]]; then atoms+=(kde-plasma/plasma-desktop); fi
  if [[ $INIT == openrc && $DESKTOP == kde ]]; then atoms+=(sys-auth/elogind); fi
  [[ $FS == xfs ]] && atoms+=(sys-fs/xfsprogs)
  [[ $FS == btrfs ]] && atoms+=(sys-fs/btrfs-progs)
  [[ $LUKS == 1 ]] && atoms+=(sys-fs/cryptsetup)
  [[ $NETMGR == nm ]] && atoms+=(net-misc/networkmanager)
  [[ $NETMGR == dhcpcd ]] && atoms+=(net-misc/dhcpcd)
  # Optional extras (Firefox, vim, ...) are installed best-effort later, so a
  # missing optional binary never blocks the installation or the disk erase.
  if [[ $BINHOST_LEVEL == x86-64-v3 ]]; then
    urls+=("https://distfiles.gentoo.org/releases/amd64/binpackages/$profver/x86-64-v3/Packages")
  fi

  msg "Checking official binary repository before any disk erasure"
  local -a pids=()
  local pid prefetch_fail=0
  for idx in "${!urls[@]}"; do
    fetch "${urls[$idx]}" "$GQI_TMPDIR/Packages-$idx" & pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || prefetch_fail=1
  done
  for idx in "${!urls[@]}"; do
    url=${urls[$idx]}
    outfile="$GQI_TMPDIR/Packages-$idx"
    if (( prefetch_fail )); then
      die "Cannot download official binhost index before disk erasure: $url. Nothing has been erased. Check network/profile version or set GQI_PREFLIGHT_PROFILE_VERSION."
    fi
    [[ -s $outfile ]] || die "Official binhost index is empty: $url. Nothing has been erased."
    # A real Packages index is plain text with "CPV:" entries. An HTML error page
    # or a truncated download would otherwise look like "atom absent".
    grep -q '^CPV: ' "$outfile" || die "Downloaded file is not a valid Packages index: $url. Nothing has been erased."
  done
  # SDDM must be validated before disk erasure. Use its current Gentoo category
  # and require official binaries for SDDM plus the OpenRC display-manager service;
  # otherwise Portage could start an unplanned source build after the disk is wiped.
  DM_MODE=sddm
  if [[ $DESKTOP == kde ]]; then
    local have_sddm=0
    for idx in "${!urls[@]}"; do
      awk '/^CPV: gui-apps\/sddm-[0-9]/ {f=1} END {exit !f}' "$GQI_TMPDIR/Packages-$idx" && have_sddm=1
    done
    if (( ! have_sddm )); then
      warn "No gui-apps/sddm binpkg was found in the checked indexes. Portage may build SDDM from source only if no usable official binary exists."
    fi
    atoms+=(gui-apps/sddm)
    [[ $INIT == openrc ]] && atoms+=(gui-libs/display-manager-init)
  fi
  # An atom is accepted when ANY of the downloaded indexes (x86-64 and, if chosen,
  # x86-64-v3) carries a binary for it. Portage merges both binhosts anyway.
  local missing=()
  for atom in "${atoms[@]}"; do
    found=0
    for idx in "${!urls[@]}"; do
      outfile="$GQI_TMPDIR/Packages-$idx"
      if awk -v atom="$atom" '
        /^CPV: / { cpv=substr($0,6)
                   if (index(cpv, atom "-") == 1 && substr(cpv, length(atom)+2) ~ /^[0-9]/) f=1 }
        END { exit !f }
      ' "$outfile"; then found=1; break; fi
    done
    (( found )) || missing+=("$atom")
  done
  if (( ${#missing[@]} > 0 )); then
    warn "Not found in the binhost indexes: ${missing[*]}"
    for idx in "${!urls[@]}"; do
      warn "Index ${urls[$idx]}: $(grep -c '^CPV: ' "$GQI_TMPDIR/Packages-$idx") entries; kernel-related entries:"
      grep '^CPV: sys-kernel/' "$GQI_TMPDIR/Packages-$idx" | sed 's/^CPV: /    /' | head -20 >&2 || true
    done
    warn "These atoms are absent from the checked binhost indexes: ${missing[*]}. Portage will use source only for atoms/dependencies with no usable binary; all available binpkgs remain preferred."
    warn "The installer will still abort on incompatible critical binary features or actual Portage dependency errors."
  fi
  local rc flag
  if [[ $INIT == openrc && $DESKTOP == kde ]]; then
    for idx in "${!urls[@]}"; do
      for atom in gui-apps/sddm kde-plasma/plasma-workspace; do
        rc=0; binpkg_flag_state "$GQI_TMPDIR/Packages-$idx" "$atom" elogind 0 || rc=$?
        if (( rc == 1 )); then
          warn "Available $atom binpkgs lack USE=elogind. The target merge will reject incompatible binaries and may build a compatible package from source."
        fi
      done
    done
  fi
  if [[ $DESKTOP == kde ]]; then
    local rcx rcw
    for idx in "${!urls[@]}"; do
      for atom in gui-apps/sddm kde-plasma/kwin kde-plasma/plasma-workspace; do
        rcx=0; rcw=0
        binpkg_flag_state "$GQI_TMPDIR/Packages-$idx" "$atom" X 0 || rcx=$?
        binpkg_flag_state "$GQI_TMPDIR/Packages-$idx" "$atom" wayland 0 || rcw=$?
        if (( rcx == 1 && rcw == 1 )); then
          warn "Available $atom binpkgs have neither X nor Wayland support. The target merge will reject incompatible binaries and may build a compatible package from source."
        fi
      done
    done
  fi
  if [[ $BOOT_MODE == uefi ]]; then flag=grub_platforms_efi-64; else flag=grub_platforms_pc; fi
  local usable_grub_binpkg=0
  for idx in "${!urls[@]}"; do
    rc=0; binpkg_flag_state "$GQI_TMPDIR/Packages-$idx" sys-boot/grub "$flag" 1 || rc=$?
    (( rc == 0 )) && usable_grub_binpkg=1
  done
  if (( ! usable_grub_binpkg )); then
    warn "No usable official GRUB binpkg with $flag was found in the selected binhost indexes. Portage will prefer all available binaries and build GRUB from source only if no usable binary exists."
  fi
  msg "Pre-wipe repository index check passed for profile $profver."
  warn "Package presence is checked here; the full dependency closure is checked next. Blockers, license acceptance and REQUIRED_USE are only checked by Portage after stage3 setup."
}

# Official Gentoo release-key bundle (sec-keys/openpgp-keys-gentoo-release-20260125).
# SHA512 is copied from the Gentoo repository Manifest; this permits Artix/Arch hosts
# without the Gentoo key package while retaining a pinned trust anchor.
GENTOO_RELEASE_KEYRING_URL=https://distfiles-cdn.gentoo.org/distfiles/37/gentoo-release.asc.20260125.gz
GENTOO_RELEASE_KEYRING_SHA512=12cb97e0c0d613d75f36e3543eb8ed566f5ab66895ca7b4abcf3d60adae23ac6230b905972f0ca668187755cef2aaae68b6b01d6372796a8ee566957e36cd3e5
ensure_gentoo_release_keyring() {
  local archive="$GQI_TMPDIR/gentoo-release.asc.20260125.gz"
  local key="$GQI_TMPDIR/gentoo-release.asc"
  local unpacked="$GQI_TMPDIR/gentoo-release.asc.new"
  if [[ ! -s $archive ]]; then
    msg "Fetching the checksum-pinned Gentoo release keyring"
    fetch "$GENTOO_RELEASE_KEYRING_URL" "$archive" \
      || die "Could not download the official Gentoo release keyring. Nothing has been erased."
  fi
  printf '%s  %s\n' "$GENTOO_RELEASE_KEYRING_SHA512" "$archive" | sha512sum --check --status \
    || die "The Gentoo release keyring checksum does not match the pinned official Manifest. Nothing has been erased."
  gzip -dc -- "$archive" > "$unpacked" \
    || die "Could not decompress the official Gentoo release keyring. Nothing has been erased."
  [[ -s $unpacked ]] || die "The official Gentoo release keyring is empty. Nothing has been erased."
  chmod 600 "$unpacked"
  mv -f -- "$unpacked" "$key"
}

# binpkg_flag_state INDEX ATOM FLAG STRICT
#   Looks at every binary entry of ATOM in a binhost "Packages" index.
#   exit 0: at least one entry has FLAG enabled (or, when STRICT=0, does not declare it)
#   exit 1: every entry lacks FLAG
#   exit 2: ATOM is not in the index
binpkg_flag_state() {
  awk -v atom="$2" -v flag="$3" -v strict="${4:-0}" '
    function flush(   rest, n, i, f, declared, enabled, a, b) {
      if (cpv != "" && index(cpv, atom "-") == 1) {
        rest = substr(cpv, length(atom) + 2)
        if (rest ~ /^[0-9]/) {
          found = 1
          declared = 0; enabled = 0
          n = split(iuse, a, " ")
          for (i = 1; i <= n; i++) { f = a[i]; sub(/^[+-]/, "", f); if (f == flag) declared = 1 }
          n = split(use, b, " ")
          for (i = 1; i <= n; i++) if (b[i] == flag) enabled = 1
          if (enabled || (!strict && !declared)) ok = 1
        }
      }
      cpv = ""; iuse = ""; use = ""
    }
    /^CPV: /  { cpv = substr($0, 6); next }
    /^IUSE: / { iuse = substr($0, 7); next }
    /^USE: /  { use = substr($0, 6); next }
    /^$/      { flush() }
    END       { flush(); if (!found) exit 2; exit ok ? 0 : 1 }
  ' "$1"
}

# Before anything is erased: the stage3 signature must come from the Gentoo
# release key that this installer trusts (catches a rotated key early).
preflight_stage3_signer() {
  if (( DRY_RUN )); then
    plan "pre-wipe check: verify the stage3 signer against the checksum-pinned official Gentoo release keyring"
    return 0
  fi
  local variant key="$GQI_TMPDIR/gentoo-release.asc"
  local fpr=${GQI_GENTOO_KEY_FPR:-}
  local txt="$GQI_TMPDIR/early-stage3.txt" asc="$GQI_TMPDIR/stage3.tar.xz.asc"
  local tarball="$GQI_TMPDIR/stage3.tar.xz"
  local gh rel keyid="" known_key=0 gpg_status
  if [[ $DESKTOP == kde && $INIT == openrc ]]; then variant=desktop-openrc
  elif [[ $DESKTOP == kde && $INIT == systemd ]]; then variant=desktop-systemd
  elif [[ $INIT == systemd ]]; then variant=systemd
  else variant=openrc
  fi
  msg "Checking the stage3 signing key before any disk erasure"
  command -v gpg >/dev/null 2>&1 || die "gpg is required. Nothing has been erased."
  ensure_gentoo_release_keyring
  fetch "$DIST/latest-stage3-amd64-$variant.txt" "$txt" \
    || die "Cannot download the stage3 listing. Nothing has been erased."
  rel=$(grep -E "stage3-amd64-${variant}-[^[:space:]]+\.tar\.xz" "$txt" | head -n1 | awk '{print $1}' || true)
  [[ -n $rel ]] || die "No stage3 entry for $variant in the listing. Nothing has been erased."
  STAGE3_REL=$rel
  msg "Pre-downloading the exact stage3 tarball and signature before disk erasure"
  fetch_pair "$DIST/$rel" "$tarball" "$DIST/$rel.asc" "$asc" \
    || die "Cannot download the stage3 tarball/signature before disk erasure. Nothing has been erased."
  [[ -s $tarball && -s $asc ]] || die "Pre-downloaded stage3 tarball or signature is empty. Nothing has been erased."
  gh=$(mktemp -d -p "$GQI_TMPDIR")
  GNUPGHOME=$gh gpg --quiet --import "$key" >/dev/null 2>&1 \
    || { rm -rf -- "$gh"; die "Could not import the checksum-verified Gentoo release keyring. Nothing has been erased."; }
  if [[ -n $fpr ]] && ! GNUPGHOME=$gh gpg --with-colons --list-keys 2>/dev/null | grep -ix "fpr:::::::::${fpr}:" >/dev/null; then
    GNUPGHOME=$gh gpgconf --kill gpg-agent >/dev/null 2>&1 || true
    rm -rf -- "$gh"
    die "GQI_GENTOO_KEY_FPR=$fpr is not present in the checksum-verified official Gentoo keyring. Nothing has been erased."
  fi
  keyid=$(GNUPGHOME=$gh gpg --list-packets "$asc" 2>/dev/null \
          | grep -oiE '(issuer key ID|keyid) [0-9A-F]{16}' | awk '{print toupper($NF)}' | head -n1 || true)
  if [[ -n $keyid ]]; then
    if GNUPGHOME=$gh gpg --with-colons --with-subkey-fingerprints --list-keys 2>/dev/null \
       | grep '^fpr:' | grep -i "${keyid}:\$" >/dev/null; then
      known_key=1
    fi
  fi
  (( known_key )) || { GNUPGHOME=$gh gpgconf --kill gpg-agent >/dev/null 2>&1 || true; rm -rf -- "$gh"; die "The stage3 signature issuer is not present in the checksum-verified Gentoo release keyring (key ID: ${keyid:-unreadable}). Nothing has been erased."; }
  if ! gpg_status=$(GNUPGHOME=$gh gpg --status-fd 1 --verify "$asc" "$tarball" 2>/dev/null); then
    GNUPGHOME=$gh gpgconf --kill gpg-agent >/dev/null 2>&1 || true
    rm -rf -- "$gh"
    die "The stage3 tarball signature failed verification before disk erasure. Nothing has been erased."
  fi
  if ! awk '$2 == "VALIDSIG" {ok=1} END {exit !ok}' <<< "$gpg_status"; then
    GNUPGHOME=$gh gpgconf --kill gpg-agent >/dev/null 2>&1 || true
    rm -rf -- "$gh"
    die "GPG did not report a cryptographically valid stage3 signature. Nothing has been erased."
  fi
  if [[ -n $fpr ]] && ! awk -v fpr="$fpr" '$2 == "VALIDSIG" && ($3 == fpr || $NF == fpr) {ok=1} END {exit !ok}' <<< "$gpg_status"; then
    GNUPGHOME=$gh gpgconf --kill gpg-agent >/dev/null 2>&1 || true
    rm -rf -- "$gh"
    die "Stage3 signature is valid but does not match the explicitly pinned fingerprint $fpr. Nothing has been erased."
  fi
  GNUPGHOME=$gh gpgconf --kill gpg-agent >/dev/null 2>&1 || true
  rm -rf -- "$gh"
  msg "Stage3 tarball signature verified before disk erasure; the verified archive is cached for installation."
}


# The package atoms requested by the chroot step (keep in sync with stage2).
core_package_atoms() {
  # gentoo-kernel-bin and linux-firmware are NOT in the official binhost; they are
  # "payload" ebuilds that only unpack ready-made files (no compilation) and are
  # installed separately by emerge_payload in the chroot.
  local -a p=(sys-boot/grub sys-kernel/installkernel sys-kernel/dracut)
  local s
  if [[ $BOOT_MODE == uefi ]]; then p+=(sys-boot/efibootmgr sys-fs/dosfstools); fi
  case $FS in
    xfs)   p+=(sys-fs/xfsprogs) ;;
    btrfs) p+=(sys-fs/btrfs-progs) ;;
  esac
  if (( LUKS )); then p+=(sys-fs/cryptsetup); fi
  if [[ $NETMGR == nm ]]; then p+=(net-misc/networkmanager); fi
  if [[ $NETMGR == dhcpcd ]]; then p+=(net-misc/dhcpcd); fi
  if [[ $INIT == openrc ]]; then p+=(app-admin/sysklogd net-misc/chrony); fi
  if [[ $DESKTOP == kde ]]; then
    p+=(media-video/pipewire media-video/wireplumber
        kde-plasma/plasma-desktop kde-plasma/breeze kde-plasma/kscreen kde-plasma/plasma-pa
        kde-plasma/polkit-kde-agent)
    [[ $NETMGR == nm ]] && p+=(kde-plasma/plasma-nm)
    # SDDM and its OpenRC display-manager integration are included in the
    # pre-wipe dependency closure; binaries are preferred and source fallback is reserved for missing binpkgs.
    if [[ $DM_MODE == sddm ]]; then
      p+=(gui-apps/sddm)
      [[ $INIT == openrc ]] && p+=(gui-libs/display-manager-init)
    fi
    [[ $INIT == openrc ]] && p+=(sys-auth/elogind)
  fi
  for s in ${USER_SUDO[@]+"${USER_SUDO[@]}"}; do
    if [[ $s == 1 ]]; then p+=(app-admin/sudo); break; fi
  done
  printf '%s\n' "${p[@]}"
}

write_depcheck_py() {  # write_depcheck_py FILE
  cat > "$1" <<'PYEOF'
#!/usr/bin/env python3
# Pre-wipe dependency closure check for gentoo-quick-install.sh
#
# Resolves the runtime dependencies (RDEPEND/PDEPEND/IDEPEND) of the requested
# packages using ONLY the official binhost "Packages" indexes plus the list of
# packages already present in the stage3. It never touches the disk.
#
# usage: depcheck.py --index FILE [--index FILE ...] --installed CONTENTS.gz -- atom...
# exit : 0 = every dependency has a binary (or is in the stage3)
#        1 = something has no usable binary
#        3 = the input data is unusable (check could not run)
import gzip
import re
import sys
from functools import cmp_to_key

VER = r'[0-9]+(?:\.[0-9]+)*[a-z]?(?:_(?:alpha|beta|pre|rc|p)[0-9]*)*(?:-r[0-9]+)?'
CPV_RE = re.compile(r'^(?P<name>.+?)-(?P<ver>' + VER + r')$')
VER_RE = re.compile(r'^([0-9]+(?:\.[0-9]+)*)([a-z]?)((?:_(?:alpha|beta|pre|rc|p)[0-9]*)*)(?:-r([0-9]+))?$')
SUF = {'alpha': 0, 'beta': 1, 'pre': 2, 'rc': 3, 'p': 5}
NONE_RANK = 4
NEEDED = ('CPV', 'SLOT', 'USE', 'KEYWORDS', 'RDEPEND', 'PDEPEND', 'IDEPEND')


def split_cpv(s):
    m = CPV_RE.match(s)
    if not m:
        return None, None
    return m.group('name'), m.group('ver')


def parse_ver(v):
    m = VER_RE.match(v)
    if not m:
        return None
    sufs = [(SUF[s], int(n) if n else 0)
            for s, n in re.findall(r'_(alpha|beta|pre|rc|p)([0-9]*)', m.group(3))]
    return (m.group(1).split('.'), m.group(2), sufs, int(m.group(4) or 0))


def cmp_ver(a, b):
    na, nb = a[0], b[0]
    ia, ib = int(na[0]), int(nb[0])
    if ia != ib:
        return -1 if ia < ib else 1
    for i in range(1, max(len(na), len(nb))):
        if i >= len(na):
            return -1
        if i >= len(nb):
            return 1
        x, y = na[i], nb[i]
        if x.startswith('0') or y.startswith('0'):
            x2, y2 = x.rstrip('0'), y.rstrip('0')
            if x2 != y2:
                return -1 if x2 < y2 else 1
        elif int(x) != int(y):
            return -1 if int(x) < int(y) else 1
    if a[1] != b[1]:
        return -1 if a[1] < b[1] else 1
    sa, sb = a[2], b[2]
    for i in range(max(len(sa), len(sb))):
        xa = sa[i] if i < len(sa) else (NONE_RANK, 0)
        xb = sb[i] if i < len(sb) else (NONE_RANK, 0)
        if xa != xb:
            return -1 if xa < xb else 1
    if a[3] != b[3]:
        return -1 if a[3] < b[3] else 1
    return 0


class Entry:
    __slots__ = ('name', 'ver', 'pv', 'slot', 'use', 'kw', 'deps')


index = {}      # name -> [Entry]
installed = {}  # name -> [version]


def add_entry(f):
    cpv = f.get('CPV')
    if not cpv:
        return
    name, ver = split_cpv(cpv)
    if name is None:
        return
    pv = parse_ver(ver)
    if pv is None:
        return
    lst = index.setdefault(name, [])
    for e in lst:
        if e.ver == ver and e.slot == f.get('SLOT', '0'):
            return
    e = Entry()
    e.name, e.ver, e.pv = name, ver, pv
    e.slot = f.get('SLOT', '0').split('/')[0]
    e.use = set(f.get('USE', '').split())
    e.kw = f.get('KEYWORDS', '').split()
    e.deps = ' '.join(f.get(k, '') for k in ('RDEPEND', 'PDEPEND', 'IDEPEND'))
    lst.append(e)


def load_index(path):
    cur = {}
    with open(path, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            line = line.rstrip('\n')
            if not line:
                add_entry(cur)
                cur = {}
                continue
            k, _, v = line.partition(':')
            if k in NEEDED:
                cur[k] = v.strip()
    add_entry(cur)


def load_installed(path):
    pat = re.compile(r'var/db/pkg/([A-Za-z0-9+_.-]+)/([^/\s]+)/')
    seen = set()
    with gzip.open(path, 'rt', encoding='utf-8', errors='replace') as fh:
        for line in fh:
            m = pat.search(line)
            if not m:
                continue
            pf = m.group(1) + '/' + m.group(2)
            if pf in seen:
                continue
            seen.add(pf)
            name, ver = split_cpv(pf)
            if name:
                installed.setdefault(name, []).append(ver)
    return len(seen)


def parse_atom(tok):
    if tok.startswith('!'):
        return None
    t = re.sub(r'\[[^\]]*\]$', '', tok)
    t = re.sub(r'::[^:\s]+$', '', t)
    slot = None
    if ':' in t:
        t, slot = t.split(':', 1)
        slot = slot.split('/')[0].rstrip('=')
        if slot in ('', '*'):
            slot = None
    m = re.match(r'^(>=|<=|>|<|=|~)?(.+)$', t)
    op, rest = m.group(1), m.group(2)
    glob = False
    if rest.endswith('*'):
        glob = True
        rest = rest[:-1]
    if op:
        name, ver = split_cpv(rest)
        if name is None:
            return None
        return {'name': name, 'op': op, 'ver': ver, 'glob': glob, 'slot': slot, 'raw': tok}
    return {'name': rest, 'op': None, 'ver': None, 'glob': False, 'slot': slot, 'raw': tok}


def ver_ok(a, v):
    if a['op'] is None:
        return True
    pa, pv = parse_ver(a['ver']), parse_ver(v)
    if pa is None or pv is None:
        return True
    if a['op'] == '=':
        if a['glob']:
            return v.startswith(a['ver'])
        return cmp_ver(pv, pa) == 0
    if a['op'] == '~':
        return cmp_ver((pv[0], pv[1], pv[2], 0), (pa[0], pa[1], pa[2], 0)) == 0
    c = cmp_ver(pv, pa)
    return {'>': c > 0, '>=': c >= 0, '<': c < 0, '<=': c <= 0}[a['op']]


def kw_ok(e):
    return (not e.kw) or ('amd64' in e.kw)


def installed_ok(a):
    return any(ver_ok(a, v) for v in installed.get(a['name'], []))


def find_index(a):
    cands = [e for e in index.get(a['name'], [])
             if kw_ok(e) and ver_ok(a, e.ver) and (a['slot'] is None or e.slot == a['slot'])]
    if not cands:
        return None
    return max(cands, key=cmp_to_key(lambda x, y: cmp_ver(x.pv, y.pv)))


def satisfiable(tok):
    a = parse_atom(tok)
    if a is None:
        return True
    return installed_ok(a) or find_index(a) is not None


def parse_deps(s):
    toks = s.split()
    pos = 0

    def parse_list():
        nonlocal pos
        out = []
        while pos < len(toks):
            t = toks[pos]
            if t == ')':
                return out
            pos += 1
            if t == '(':
                out.append(('all', parse_list()))
                pos += 1
            elif t == '||':
                pos += 1
                out.append(('any', parse_list()))
                pos += 1
            elif t.endswith('?') and len(t) > 1:
                flag = t[:-1]
                neg = flag.startswith('!')
                flag = flag.lstrip('!')
                pos += 1
                out.append(('cond', flag, neg, parse_list()))
                pos += 1
            else:
                out.append(('atom', t))
        return out

    return parse_list()


def flatten(items, use):
    out = []
    for it in items:
        k = it[0]
        if k == 'atom':
            out.append(it[1])
        elif k == 'all':
            out += flatten(it[1], use)
        elif k == 'cond':
            _, flag, neg, sub = it
            if (flag in use) != neg:
                out += flatten(sub, use)
        elif k == 'any':
            pick = None
            for alt in it[1]:
                atoms = [x for x in flatten([alt], use) if isinstance(x, str)]
                if all(satisfiable(x) for x in atoms):
                    pick = atoms
                    break
            if pick is None:
                shown = []
                for alt in it[1][:4]:
                    shown.append(' '.join(x for x in flatten([alt], use) if isinstance(x, str)))
                out.append(('ANYFAIL', ' | '.join(shown)))
            else:
                out += pick
    return out


def main():
    argv = sys.argv[1:]
    idx_files, inst_file, atoms, provided = [], None, [], []
    i = 0
    while i < len(argv):
        if argv[i] == '--index':
            idx_files.append(argv[i + 1])
            i += 2
        elif argv[i] == '--installed':
            inst_file = argv[i + 1]
            i += 2
        elif argv[i] == '--provided':
            provided.append(argv[i + 1])
            i += 2
        elif argv[i] == '--':
            atoms = argv[i + 1:]
            break
        else:
            i += 1
    try:
        for f in idx_files:
            load_index(f)
        n_inst = load_installed(inst_file)
        for name in provided:
            installed.setdefault(name, []).append('99.0')
    except (OSError, EOFError, UnicodeError) as exc:
        print('depcheck: cannot read input data: %s' % exc)
        return 3
    if not index or n_inst < 100:
        print('depcheck: index or stage3 package list looks empty or unreadable '
              '(%d index names, %d installed packages)' % (len(index), n_inst))
        return 3

    chosen = {}
    missing = []
    stack = []

    def need(tok, by):
        if isinstance(tok, tuple):
            missing.append('no installable alternative in any-of group ( %s )   [needed by %s]' % (tok[1], by))
            return
        a = parse_atom(tok)
        if a is None:
            return
        if installed_ok(a):
            return
        e = find_index(a)
        if e is None:
            missing.append('%s   [needed by %s]' % (tok, by))
            return
        key = (e.name, e.ver)
        if key not in chosen:
            chosen[key] = e
            stack.append(e)

    for tok in atoms:
        need(tok, 'the installer request')
    while stack:
        e = stack.pop()
        for tok in flatten(parse_deps(e.deps), e.use):
            need(tok, '%s-%s' % (e.name, e.ver))

    if missing:
        seen = set()
        uniq = [m for m in missing if not (m in seen or seen.add(m))]
        print('depcheck: %d dependency problem(s) found; no usable official binary for:' % len(uniq))
        for m in uniq[:40]:
            print('  - ' + m)
        return 1
    print('depcheck: %d binary packages needed in total (%d packages already in the stage3); '
          'every dependency has an official binary.' % (len(chosen), n_inst))
    return 0


if __name__ == '__main__':
    sys.exit(main())
PYEOF
}

depcheck_unavailable() {  # depcheck_unavailable REASON
  warn "Dependency pre-check could not run: $1"
  if [[ ${GQI_SKIP_DEPCHECK:-0} == 1 ]]; then
    warn "GQI_SKIP_DEPCHECK=1 is set: continuing without the dependency pre-check."
    return 0
  fi
  if (( UNATTENDED )); then
    die "Unattended mode will not erase the disk without the dependency pre-check. Nothing has been erased. Fix the cause above, or set GQI_SKIP_DEPCHECK=1 to accept the risk."
  fi
  menu "Without the pre-check, a missing binary would only be discovered AFTER the disk is erased. Continue anyway?" \
    "No, cancel (recommended)" "Yes, erase the disk and continue"
  (( MENU_IDX == 1 )) || die "Cancelled. Nothing was changed."
}

# Resolves the full runtime-dependency closure of every requested package against
# the official binhost indexes and the stage3 package list, with NO disk access.
preflight_dependency_resolution() {
  if (( DRY_RUN )); then
    plan "pre-wipe check: resolve the dependency closure of every requested package against the binhost index and the stage3 package list (python3, no disk access)"
    return 0
  fi
  if [[ ${GQI_SKIP_DEPCHECK:-0} == 1 ]]; then
    warn "GQI_SKIP_DEPCHECK=1: dependency pre-check skipped."
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    depcheck_unavailable "python3 is not available on this live system"
    return 0
  fi
  if [[ -z $STAGE3_REL ]]; then
    depcheck_unavailable "the stage3 listing was not read"
    return 0
  fi
  local py="$GQI_TMPDIR/depcheck.py" cont="$GQI_TMPDIR/stage3.CONTENTS.gz"
  local f out rc=0
  local -a args=() atoms=()
  if ! fetch "$DIST/$STAGE3_REL.CONTENTS.gz" "$cont"; then
    depcheck_unavailable "could not download the stage3 package list ($STAGE3_REL.CONTENTS.gz)"
    return 0
  fi
  write_depcheck_py "$py"
  for f in "$GQI_TMPDIR"/Packages-*; do
    [[ -s $f ]] && args+=(--index "$f")
  done
  (( ${#args[@]} > 0 )) || { depcheck_unavailable "no binhost index was downloaded"; return 0; }
  mapfile -t atoms < <(core_package_atoms)
  msg "Resolving the dependencies of ${#atoms[@]} requested packages against the official binaries (before any disk erasure)"
  [[ $DM_MODE == tty ]] && args+=(--provided gui-apps/sddm)
  out=$(python3 -I "$py" "${args[@]}" --installed "$cont" -- "${atoms[@]}" 2>&1) || rc=$?
  printf '%s\n' "$out"
  case $rc in
    0) msg "Dependency pre-check passed." ;;
    3) depcheck_unavailable "the binhost index or the stage3 package list could not be used" ;;
    1) warn "The pre-wipe audit found dependencies without usable official binaries. Portage may build only the missing binary packages/dependencies from source; all available binpkgs remain preferred." ;;
    *) die "Unexpected dependency-audit exit code $rc. Nothing has been erased." ;;
  esac
}

pp() {  # pp N -> partition N of the disk (handles nvme0n1p1 / sda1)
  if [[ $DISK =~ [0-9]$ ]]; then echo "${DISK}p$1"; else echo "${DISK}$1"; fi
}

prepare_disk() {
  msg "Partitioning $DISK"
  if mountpoint -q "$MNT" 2>/dev/null; then die "$MNT is already mounted; unmount it before installing"; fi
  disk_in_use && die "Target disk $DISK is in use (mounted). Pick another disk."
  disk_is_safe_target || die "Target disk $DISK is not a safe whole-disk target."
  # Re-check immediately before any destructive operation.
  disk_is_safe_target || die "Target disk $DISK became unsafe before erasure."
  run wipefs -af "$DISK"
  run sgdisk --zap-all "$DISK"
  if [[ $BOOT_MODE == uefi ]]; then
    run sgdisk -n1:0:+512M -t1:ef00 -c1:EFI "$DISK"
  else
    run sgdisk -n1:0:+2M -t1:ef02 -c1:BIOSBOOT "$DISK"
  fi
  run sgdisk -n2:0:+1G -t2:8300 -c2:boot "$DISK"
  if (( LUKS )); then
    run sgdisk -n3:0:0 -t3:8309 -c3:cryptroot "$DISK"
  else
    run sgdisk -n3:0:0 -t3:8300 -c3:root "$DISK"
  fi
  run partprobe "$DISK"
  run udevadm settle
  run sleep 2
  if (( ! DRY_RUN )); then
    for i in 1 2 3; do
      [[ -b $(pp "$i") ]] || die "Expected partition $(pp "$i") was not created."
    done
  fi

  msg "Formatting"
  [[ $BOOT_MODE == uefi ]] && run mkfs.vfat -F32 -n EFI "$(pp 1)"
  run mkfs.ext4 -F -L boot "$(pp 2)"

  local root_dev fs_dev
  root_dev=$(pp 3)
  if (( LUKS )); then
    msg "Creating LUKS2 volume on $root_dev (physical partition; filesystem goes on the mapper)"
    if (( DRY_RUN )); then
      plan "cryptsetup luksFormat --type luks2 $root_dev  (passphrase via stdin, never on the command line)"
      plan "cryptsetup open $root_dev luks-<LUKS-UUID>  (mapper; then mkfs on /dev/mapper/...)"
      LUKS_UUID="<LUKS-UUID>"
      MAPPER="luks-$LUKS_UUID"
      # Dry-run: do not open a real mapper; fs_dev is only used in plan strings.
      fs_dev="/dev/mapper/$MAPPER"
    else
      printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "$root_dev"
      # UUID of the LUKS *container* on the physical partition (for rd.luks.uuid / crypttab).
      LUKS_UUID=$(cryptsetup luksUUID "$root_dev")
      [[ -n $LUKS_UUID ]] || die "cryptsetup luksUUID returned empty for $root_dev"
      MAPPER="luks-$LUKS_UUID"
      printf '%s' "$LUKS_PASS" | cryptsetup open --key-file=- "$root_dev" "$MAPPER"
      LUKS_OPENED=1
      # Filesystem will be created on the unlocked mapper, not on the raw LUKS partition.
      fs_dev=/dev/mapper/$MAPPER
    fi
  else
    fs_dev=$root_dev
  fi

  case $FS in
    ext4)  run mkfs.ext4 -F -L gentoo "$fs_dev" ;;
    xfs)   run mkfs.xfs -f -L gentoo "$fs_dev" ;;
    btrfs) run mkfs.btrfs -f -L gentoo "$fs_dev" ;;
  esac

  msg "Mounting"
  run mkdir -p "$MNT"
  run mount "$fs_dev" "$MNT"
  # TARGET_MOUNTED tracks mounts this script actually performed — never set in dry-run.
  if (( ! DRY_RUN )); then
    TARGET_MOUNTED=1
    MOUNTS+=("$MNT")
  fi
  run chmod 755 "$MNT"
  run mkdir -p "$MNT/boot"
  run chmod 755 "$MNT/boot"
  run mount "$(pp 2)" "$MNT/boot"
  if (( ! DRY_RUN )); then MOUNTS+=("$MNT/boot"); fi
  if [[ $BOOT_MODE == uefi ]]; then
    run mkdir -p "$MNT/efi"
    run chmod 755 "$MNT/efi"
    run mount "$(pp 1)" "$MNT/efi"
    if (( ! DRY_RUN )); then MOUNTS+=("$MNT/efi"); fi
  fi
  if (( DRY_RUN )); then
    # Placeholders only; dry-run never reads real blkid or writes fstab.
    ROOT_FS_UUID="<FS-UUID>"
    if (( LUKS )); then LUKS_UUID="<LUKS-UUID>"; fi
  else
    # ROOT_FS_UUID = filesystem UUID on the root device (mapper if LUKS, else the partition).
    # LUKS_UUID     = LUKS *container* UUID on the physical partition (set above when LUKS=1).
    # These must never be swapped: rd.luks.uuid uses LUKS_UUID; root=UUID and fstab use ROOT_FS_UUID.
    ROOT_FS_UUID=$(blkid -s UUID -o value "$fs_dev")
    [[ -n $ROOT_FS_UUID ]] || die "could not read filesystem UUID from $fs_dev"
    if (( LUKS )); then
      [[ -n $LUKS_UUID ]] || die "LUKS container UUID is empty"
      [[ $LUKS_UUID != "$ROOT_FS_UUID" ]] || die "internal error: LUKS UUID equals filesystem UUID"
    fi
  fi
}

# Swapfile on the root filesystem. Created before the stage3 is extracted so
# that the live system can use it while compiling too.
create_swapfile() {
  [[ $SWAP == swapfile ]] || return 0
  msg "Creating a ${SWAP_SIZE_MB} MiB swapfile"
  local f=$MNT/swapfile
  run touch "$f"
  if [[ $FS == btrfs ]]; then run chattr +C "$f"; fi   # btrfs swapfiles must be NOCOW
  run fallocate -l "${SWAP_SIZE_MB}M" "$f"
  run chmod 600 "$f"
  run mkswap "$f"
  run swapon "$f"
}

install_stage3() {
  local variant rel key gnupg_home tarball="$GQI_TMPDIR/stage3.tar.xz" asc="$GQI_TMPDIR/stage3.tar.xz.asc"
  if [[ $DESKTOP == kde && $INIT == openrc ]]; then variant=desktop-openrc
  elif [[ $DESKTOP == kde && $INIT == systemd ]]; then variant=desktop-systemd
  elif [[ $INIT == systemd ]]; then variant=systemd
  else variant=openrc
  fi
  msg "Looking up the latest stage3 ($variant)"
  if (( DRY_RUN )); then
    plan "fetch $DIST/latest-stage3-amd64-$variant.txt  (read-only, skipped in dry-run)"
    plan "fetch and verify the stage3 tarball and its .asc signature"
    plan "extract stage3 into $MNT; write $MNT/etc/fstab"
    return 0
  fi
  rel=$STAGE3_REL
  [[ -n $rel && -s $tarball && -s $asc ]] \
    || die "The stage3 archive verified before disk erasure is missing; refusing to fetch an unverified replacement after erasure."
  msg "Using the exact stage3 archive verified before disk erasure: $rel"
  key="$GQI_TMPDIR/gentoo-release.asc"
  local GENTOO_KEY_FPR=${GQI_GENTOO_KEY_FPR:-}
  ensure_gentoo_release_keyring
  command -v gpg >/dev/null 2>&1 || die "gpg is required to verify the stage3 signature."
  msg "Verifying GPG signature"
  gnupg_home=$(mktemp -d); export GNUPGHOME=$gnupg_home
  if ! gpg --quiet --import "$key"; then
    rm -rf -- "$gnupg_home"; unset GNUPGHOME
    die "failed to import the Gentoo release key"
  fi
  if [[ -n $GENTOO_KEY_FPR ]] && ! gpg --with-colons --list-keys 2>/dev/null | grep -ix "fpr:::::::::${GENTOO_KEY_FPR}:" >/dev/null; then
    rm -rf -- "$gnupg_home"; unset GNUPGHOME
    die "GQI_GENTOO_KEY_FPR=$GENTOO_KEY_FPR is not present in the checksum-verified official Gentoo keyring."
  fi
  local gpg_status
  if ! gpg_status=$(gpg --status-fd 1 --verify "$asc" "$tarball" 2>/dev/null); then
    rm -rf -- "$gnupg_home"; unset GNUPGHOME
    die "stage3 signature verification failed with the checksum-verified official Gentoo release keyring."
  fi
  if ! awk '$2 == "VALIDSIG" {ok=1} END {exit !ok}' <<< "$gpg_status"; then
    rm -rf -- "$gnupg_home"; unset GNUPGHOME
    die "GPG did not report a cryptographically valid stage3 signature."
  fi
  if [[ -n $GENTOO_KEY_FPR ]] && ! awk -v fpr="$GENTOO_KEY_FPR" '$2 == "VALIDSIG" && ($3 == fpr || $NF == fpr) {ok=1} END {exit !ok}' <<< "$gpg_status"; then
    rm -rf -- "$gnupg_home"; unset GNUPGHOME
    die "stage3 signature is valid, but it was not made by the explicitly pinned key $GENTOO_KEY_FPR."
  fi
  rm -rf -- "$gnupg_home"; unset GNUPGHOME

  [[ -s $tarball && -s $asc ]] || die "stage3 tarball or signature is empty or missing."
  msg "Extracting the verified stage3 into $MNT"
  tar --extract --file="$tarball" --directory="$MNT" --xattrs-include='*.*' --numeric-owner
  # The target chroot also needs the same checksum-verified release keyring for
  # emerge-webrsync; do not assume a Gentoo key package exists in every stage3.
  mkdir -p "$MNT/usr/share/openpgp-keys"
  cp -f -- "$key" "$MNT/usr/share/openpgp-keys/gentoo-release.asc" \
    || die "Could not install the verified Gentoo release keyring into the target stage3."
  chmod 644 "$MNT/usr/share/openpgp-keys/gentoo-release.asc"
  cd /

  local ropts="noatime" rpass=1
  [[ $FS != ext4 ]] && rpass=0
  {
    echo "# generated by gentoo-quick-install"
    echo "UUID=$ROOT_FS_UUID  /      $FS   $ropts  0 $rpass"
    echo "UUID=$(blkid -s UUID -o value "$(pp 2)")  /boot  ext4  noatime  0 2"
    if [[ $BOOT_MODE == uefi ]]; then
      # Handbook: ESP at /efi with umask=0077,tz=UTC
      echo "UUID=$(blkid -s UUID -o value "$(pp 1)")  /efi   vfat  umask=0077,tz=UTC  0 2"
    fi
    if [[ $SWAP == swapfile ]]; then
      echo "/swapfile  none  swap  sw  0 0"
    fi
  } > "$MNT/etc/fstab"
  chmod 644 "$MNT/etc/fstab"
}

prep_chroot() {
  msg "Preparing chroot"
  run cp --dereference /etc/resolv.conf "$MNT/etc/"
  run chmod 644 "$MNT/etc/resolv.conf"
  run mount --types proc /proc "$MNT/proc"
  (( DRY_RUN )) || MOUNTS+=("$MNT/proc")
  run mount --rbind /sys "$MNT/sys"
  (( DRY_RUN )) || MOUNTS+=("$MNT/sys")
  run mount --make-rslave "$MNT/sys"
  run mount --rbind /dev "$MNT/dev"
  (( DRY_RUN )) || MOUNTS+=("$MNT/dev")
  run mount --make-rslave "$MNT/dev"
  run mount --bind /run "$MNT/run"
  (( DRY_RUN )) || MOUNTS+=("$MNT/run")
  run mount --make-slave "$MNT/run"
  if (( DRY_RUN )); then plan "write secrets to $MNT/root/secrets.env (mode 600, deleted on exit)"; return 0; fi

  mkdir -p "$MNT/root"
  local env_file=$MNT/root/install.env sec_file=$MNT/root/secrets.env v
  {
    for v in TARGET_HOST TZONE LOCALE KEYMAP XKB_LAYOUT XKB_VARIANT INIT FS LUKS LUKS_UUID \
             NETMGR BOOT_MODE DISK BINHOST_LEVEL BINPKG_MODE ROOT_FS_UUID EXTRAS DESKTOP KERNEL JOBS \
             SWAP SWAP_SIZE_MB WORLD_UPDATE DM_MODE; do
      printf '%s=%q\n' "$v" "${!v}"
    done
    printf 'ROOTPFX=""\n'
    declare -p USER_NAMES USER_SUDO
  } > "$env_file"
  {
    printf 'ROOT_PASS=%q\n' "$ROOT_PASS"
    declare -p USER_PASSES
  } > "$sec_file"
  chmod 600 "$env_file" "$sec_file"
  SECRET_FILES+=("$sec_file")

  # ---- script that runs INSIDE the chroot -----------------------------------
  # The verification functions go FIRST, so they exist when verify_system is called.
  declare -f v_ok v_bad select_installed_kernel_pair verify_fstab verify_boot verify_luks verify_services \
              verify_desktop verify_profile verify_users verify_system > "$MNT/root/stage2.sh"
  cat >> "$MNT/root/stage2.sh" <<'CHROOT_EOF'
#!/usr/bin/env bash
set -Eeo pipefail
# Files created by system configuration tools should be readable by normal
# users unless explicitly secret; sensitive files below are chmod 600.
umask 022
# Gentoo's profile scripts may inspect unset optional variables.
source /etc/profile
set -u
# shellcheck disable=SC2154
trap 'rc=$?; rm -f /root/secrets.env /root/install.env /root/stage2.sh; exit "$rc"' ERR
trap 'rm -f /root/secrets.env /root/install.env /root/stage2.sh; exit 130' INT
trap 'rm -f /root/secrets.env /root/install.env /root/stage2.sh; exit 143' TERM
source /root/install.env
source /root/secrets.env
say() { printf '\n\e[32m==>\e[0m %s\n' "$*"; }
die() {
  trap - ERR INT TERM
  rm -f /root/secrets.env /root/install.env /root/stage2.sh
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}
warn() { printf '!! %s\n' "$*" >&2; }
fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$2" "$1"
  else
    wget --tries=3 --timeout=30 -O "$2" "$1"
  fi
}

say "Syncing the Portage tree"
emerge-webrsync

# Gentoo profile version (e.g. 23.0) comes from the stage3, so the binhost path matches it.
PROFVER=$(readlink /etc/portage/make.profile | grep -oE 'amd64/[0-9]+\.[0-9]+' | head -n1 | cut -d/ -f2 || true)
[[ -n $PROFVER ]] || { echo "Cannot detect the Gentoo profile version"; exit 1; }
say "Profile version $PROFVER"

# ---- profile: must match the init system, never a mix --------------------------
if [[ $INIT == systemd ]]; then SYS_SUFFIX=/systemd; else SYS_SUFFIX=""; fi
if [[ $DESKTOP == kde ]]; then
  PROFILE="default/linux/amd64/$PROFVER/desktop/plasma$SYS_SUFFIX"
else
  PROFILE="default/linux/amd64/$PROFVER$SYS_SUFFIX"
fi
say "Selecting profile $PROFILE"
PROFILE_LIST=$(eselect profile list | awk '{print $2}')   # captured: avoids pipefail with grep -q
if ! grep -qxF "$PROFILE" <<< "$PROFILE_LIST"; then
  echo "Profile $PROFILE is not available in this Portage tree."; exit 1
fi
eselect profile set "$PROFILE"
if ! readlink /etc/portage/make.profile | grep -F "$PROFILE" >/dev/null; then
  echo "Profile was not set correctly"; exit 1
fi


say "Configuring the binhost ($BINHOST_LEVEL, $BINPKG_MODE)"
mkdir -p /etc/portage/binrepos.conf /etc/portage/package.use
# Preserve unrelated user configuration; only replace our own managed file.
cat > /etc/portage/binrepos.conf/gentoobinhost.conf <<EOF
[gentoo-x86-64]
priority = 9998
sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/$PROFVER/x86-64/
location = /var/cache/binhost/gentoo
EOF
BINHOST_URLS=("https://distfiles.gentoo.org/releases/amd64/binpackages/$PROFVER/x86-64/Packages")
if [[ $BINHOST_LEVEL == x86-64-v3 ]]; then
  # Handbook: with the v3 binhost, keep the x86-64 one too (some packages are missing in v3)
  cat >> /etc/portage/binrepos.conf/gentoobinhost.conf <<EOF

[gentoo-x86-64-v3]
priority = 9999
sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/$PROFVER/x86-64-v3/
location = /var/cache/binhost/gentoo-x86-64-v3
EOF
  BINHOST_URLS+=("https://distfiles.gentoo.org/releases/amd64/binpackages/$PROFVER/x86-64-v3/Packages")
fi
# Binary packages only are enforced on each emerge command issued by this installer.
# Do NOT persist --usepkgonly in EMERGE_DEFAULT_OPTS: that would unexpectedly force
# every future emerge run by the installed user to remain binary-only forever.
# Accept only USE-compatible official binpkgs; if no usable binary exists, Portage
# may build that package from source. This matches the requested binary-first policy.
if grep -q '# --- gentoo-quick-install ---' /etc/portage/make.conf 2>/dev/null; then
  sed -i '/# --- gentoo-quick-install ---/,/# --- end gentoo-quick-install ---/d' /etc/portage/make.conf
fi
# Preserve stage3 MAKEOPTS and any existing EMERGE_DEFAULT_OPTS. They are not the
# mechanism used to enforce binary-only mode for this installer.
cat >> /etc/portage/make.conf <<EOF

# --- gentoo-quick-install ---
ACCEPT_LICENSE="-* @FREE @BINARY-REDISTRIBUTABLE"
FEATURES="\${FEATURES} getbinpkg binpkg-request-signature parallel-install parallel-fetch"
MAKEOPTS="-j${JOBS}"
# Keep package-level merges serial; MAKEOPTS controls parallel compilation within one package.
# This avoids multiplying -j${JOBS} across several concurrent C/C++ builds.
EMERGE_DEFAULT_OPTS="\${EMERGE_DEFAULT_OPTS} --jobs=1"
# --- end gentoo-quick-install ---
EOF
getuto || die "getuto failed; cannot establish binpkg trust"

# Lightweight reachability check for binhost Packages indexes (defined inside chroot).
url_available() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsIL --retry 2 --retry-delay 2 --connect-timeout 15 "$1" >/dev/null 2>&1
  else
    wget --spider -q --tries=2 --timeout=30 "$1" 2>/dev/null
  fi
}

say "Validating official binhost indexes"
for url in "${BINHOST_URLS[@]}"; do
  if ! url_available "$url"; then
    echo "Official binhost index is unavailable or incompatible: $url"
    exit 1
  fi
done

# Do not download and grep the large Packages indexes here: Portage downloads and
# parses the same indexes during dependency resolution. The text grep was only a
# preliminary heuristic and could not prove USE/dependency compatibility anyway.

# Prefer official binpkgs only when their recorded USE flags match the target.
# If no compatible binary exists, Portage falls back to source for that package;
# compatible official binaries remain preferred for all other packages.
# Usage: emerge_binpkgs [emerge options...] -- atom...
emerge_binpkgs() {
  local -a opts=() atoms=()
  local seen=0 a
  for a in "$@"; do
    if (( ! seen )) && [[ $a == -- ]]; then seen=1; continue; fi
    if (( seen )); then atoms+=("$a"); else opts+=("$a"); fi
  done
  (( ${#atoms[@]} > 0 )) || { echo "emerge_binpkgs: no packages given"; exit 1; }

  # Portage accepts official/local binpkgs only when their USE flags are compatible.
  # If no usable binary exists, normal Portage resolution falls back to source.
  if emerge --ask=n --getbinpkg --usepkg --binpkg-respect-use=y \
      --jobs=1 --load-average="$((JOBS + 1))" "${opts[@]}" "${atoms[@]}"; then
    return 0
  else
    local status=$?
    echo "Official binary installation failed for: ${atoms[*]}" >&2
    echo "Portage's error above is authoritative; it includes the binary-first resolution and any source fallback attempted." >&2
    return "$status"
  fi
}

# These ebuilds install prebuilt kernel/firmware payloads. Keep normal dependency
# resolution enabled; source fallback is allowed only when a usable binpkg is absent.
emerge_payload() {  # emerge_payload atom...
  env -u SECUREBOOT_SIGN_CERT -u SECUREBOOT_SIGN_KEY -u SECUREBOOT_SIGN_TOOL \
    emerge --ask=n --oneshot --getbinpkg --usepkg --binpkg-respect-use=y \
      --jobs=1 --load-average="$((JOBS + 1))" "$@"
}

# No display manager (SDDM has no official binary): tell Portage it is provided so
# the Plasma binaries install without it.
if [[ ${DM_MODE:-sddm} == tty ]]; then
  mkdir -p /etc/portage/profile
  grep -qxF 'gui-apps/sddm-99.0' /etc/portage/profile/package.provided 2>/dev/null \
    || echo 'gui-apps/sddm-99.0' >> /etc/portage/profile/package.provided
fi

# Gentoo Handbook: use the traditional /boot layout with GRUB, and let
# installkernel invoke dracut for distribution kernels. Explicitly disable UKI,
# ukify and ugrd paths: this installer does not configure Secure Boot or UKI signing.
# The final initramfs is regenerated to a known filename and validated below.
mkdir -p /etc/portage/package.use
cat > /etc/portage/package.use/gqi-kernel <<'USEEOF'
sys-kernel/installkernel dracut -ugrd -ukify -uki -systemd -systemd-boot -efistub
sys-kernel/gentoo-kernel-bin -initramfs
USEEOF

# This installer does not provision Secure Boot keys or sign the GRUB/kernel chain.
# Stage3 may ship SECUREBOOT_SIGN_* assignments in make.conf or Portage env snippets.
# Leaving even one active assignment makes gentoo-kernel-bin invoke sbverify with a
# stage3 certificate; that caused the observed fatal error "UKI signature is invalid"
# when sbverify was absent. Remove only those assignments from Portage configuration,
# then clear inherited shell variables and fail closed if any active assignment remains.
clear_inherited_secureboot_signing() {
  local f
  local -a config_files=(/etc/make.conf /etc/portage/make.conf)
  [[ -d /etc/portage ]] && while IFS= read -r -d '' f; do config_files+=("$f"); done \
    < <(find /etc/portage -type f -print0 2>/dev/null)
  for f in "${config_files[@]}"; do
    [[ -f $f ]] || continue
    sed -i -E '/^[[:space:]]*(export[[:space:]]+)?SECUREBOOT_SIGN_(CERT|KEY|TOOL)[[:space:]]*=/d' "$f"
  done
  unset SECUREBOOT_SIGN_CERT SECUREBOOT_SIGN_KEY SECUREBOOT_SIGN_TOOL
  if grep -RInE '^[[:space:]]*(export[[:space:]]+)?SECUREBOOT_SIGN_(CERT|KEY|TOOL)[[:space:]]*=' \
      /etc/make.conf /etc/portage 2>/dev/null; then
    die "A Secure Boot signing override remains in Portage configuration; refusing to install the kernel with an inherited certificate."
  fi
}
clear_inherited_secureboot_signing

# Set GRUB platforms before any GRUB emerge so binary packages can supply the
# correct modules when available (Handbook: GRUB_PLATFORMS before emerge).
sed -i -E '/^GRUB_PLATFORMS=/d' /etc/portage/make.conf
if [[ $BOOT_MODE == uefi ]]; then
  echo 'GRUB_PLATFORMS="efi-64"' >> /etc/portage/make.conf
else
  echo 'GRUB_PLATFORMS="pc"' >> /etc/portage/make.conf
fi


# OpenRC safety: some official binaries (dbus, dracut, ...) exist in a variant built
# with USE=systemd. With --binpkg-respect-use=y Portage may pick that variant, which
# drags sys-apps/systemd in and blocks against elogind/systemd-utils. Masking systemd
# makes Portage pick the non-systemd binary variants instead (still binaries only).
if [[ $INIT == openrc ]]; then
  mkdir -p /etc/portage/package.mask
  cat > /etc/portage/package.mask/gqi-openrc <<'MASKEOF'
# gentoo-quick-install: this is an OpenRC system, never pull systemd
sys-apps/systemd
sys-apps/gentoo-systemd-integration
MASKEOF
fi

say "Preparing complete official-binpkg dependency plan for preflight"
gpkgs=(sys-boot/grub)
[[ $BOOT_MODE == uefi ]] && gpkgs+=(sys-boot/efibootmgr)
pkgs=(sys-kernel/installkernel sys-kernel/dracut)
[[ $BOOT_MODE == uefi ]] && pkgs+=(sys-fs/dosfstools)
# gentoo-kernel-bin and linux-firmware are installed later by emerge_payload (no compilation).
[[ $FS == xfs   ]] && pkgs+=(sys-fs/xfsprogs)
[[ $FS == btrfs ]] && pkgs+=(sys-fs/btrfs-progs)
[[ $LUKS == 1   ]] && pkgs+=(sys-fs/cryptsetup)
[[ $NETMGR == nm ]] && pkgs+=(net-misc/networkmanager)
[[ $NETMGR == dhcpcd ]] && pkgs+=(net-misc/dhcpcd)
if [[ $INIT == openrc ]]; then
  pkgs+=(app-admin/sysklogd net-misc/chrony)
fi
if [[ $DESKTOP == kde ]]; then
  pkgs+=(media-video/pipewire media-video/wireplumber)
  [[ $INIT == openrc ]] && pkgs+=(sys-auth/elogind)
fi
for s in "${USER_SUDO[@]}"; do
  if [[ $s == 1 ]]; then pkgs+=(app-admin/sudo); break; fi
done
read -ra extra <<< "${EXTRAS:-}" || true
opt_pkgs=("${extra[@]}")
if [[ $DESKTOP == kde ]]; then
  say "Including KDE Plasma in one dependency resolution (display manager mode: ${DM_MODE:-sddm})"
  # Minimal Plasma: the desktop shell only. No plasma-meta, no KDE applications.
  pkgs+=(kde-plasma/plasma-desktop kde-plasma/breeze kde-plasma/kscreen kde-plasma/plasma-pa kde-plasma/polkit-kde-agent)
  [[ $NETMGR == nm ]] && pkgs+=(kde-plasma/plasma-nm)
  if [[ ${DM_MODE:-sddm} == sddm ]]; then
    pkgs+=(gui-apps/sddm)
    [[ $INIT == openrc ]] && pkgs+=(gui-libs/display-manager-init)
  fi
fi

# Deduplicate package atoms (Firefox can be selected as an extra even though KDE includes it by default).
all_pkgs=()
declare -A seen_pkg=()
for atom in "${gpkgs[@]}" "${pkgs[@]}"; do
  [[ -n $atom && -z ${seen_pkg[$atom]+x} ]] || continue
  seen_pkg[$atom]=1
  all_pkgs+=("$atom")
done

# The pre-wipe audit checks official binary coverage. Portage uses any available
# binpkg despite USE metadata differences; source fallback is reserved for missing
# usable binaries. MAKEOPTS remains -j18 by default.

say "Timezone, locale, keyboard, hostname"
echo "$TZONE" > /etc/timezone
ln -sf "/usr/share/zoneinfo/$TZONE" /etc/localtime
# Ensure required UTF-8 locales without duplicating lines already present in stage3.
for _loc in en_US.UTF-8 "$LOCALE"; do
  grep -qxF "${_loc} UTF-8" /etc/locale.gen 2>/dev/null || echo "${_loc} UTF-8" >> /etc/locale.gen
done
unset _loc
locale-gen || warn "locale-gen failed; continuing boot setup. Generate the configured locale after first boot."
cat > /etc/env.d/02locale <<EOF
LANG="$LOCALE"
LC_COLLATE="C.UTF-8"
EOF
echo "LANG=$LOCALE" > /etc/locale.conf
env-update || warn "env-update failed; continuing boot setup."
if [[ -f /etc/conf.d/keymaps ]]; then
  sed -i "s|^keymap=.*|keymap=\"$KEYMAP\"|" /etc/conf.d/keymaps
fi
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
if [[ $DESKTOP == kde ]]; then
  mkdir -p /etc/X11/xorg.conf.d
  cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "$XKB_LAYOUT"
    Option "XkbVariant" "$XKB_VARIANT"
EndSection
EOF
fi
echo "$TARGET_HOST" > /etc/hostname
if [[ $INIT == openrc ]]; then
  echo "hostname=\"$TARGET_HOST\"" > /etc/conf.d/hostname
fi
cat > /etc/hosts <<EOF
127.0.0.1 localhost $TARGET_HOST
::1       localhost $TARGET_HOST
EOF

# initramfs + kernel command line + crypttab (must agree with each other).
# Configure BEFORE emerging the kernel so installkernel/dracut pick these up.
#
# UUID roles (must not be swapped):
#   LUKS_UUID     — UUID of the LUKS container on the physical partition (cryptsetup luksUUID)
#   ROOT_FS_UUID  — UUID of the filesystem on the unlocked mapper (or on the plain partition)
# Boot path with LUKS:
#   1) rd.luks.uuid=$LUKS_UUID  → unlock partition → /dev/mapper/luks-$LUKS_UUID
#   2) root=UUID=$ROOT_FS_UUID → mount the filesystem on that mapper
mkdir -p /etc/dracut.conf.d
{
  echo 'hostonly="no"'
  echo 'hostonly_cmdline="no"'
} > /etc/dracut.conf.d/00-quick.conf
cmdline="root=UUID=$ROOT_FS_UUID"
if [[ $LUKS == 1 ]]; then
  [[ -n $LUKS_UUID && -n $ROOT_FS_UUID ]] || { echo "LUKS_UUID/ROOT_FS_UUID missing in chroot env"; exit 1; }
  [[ $LUKS_UUID != "$ROOT_FS_UUID" ]] || { echo "LUKS_UUID must not equal ROOT_FS_UUID"; exit 1; }
  # dm + crypt modules; pull crypttab into the image for consistent unlock naming.
  {
    echo 'add_dracutmodules+=" dm crypt "'
    echo 'install_items+=" /etc/crypttab "'
  } >> /etc/dracut.conf.d/00-quick.conf
  # crypttab: target name → /dev/mapper/<name>; UUID= is the LUKS *container* UUID.
  echo "luks-$LUKS_UUID UUID=$LUKS_UUID none luks" > /etc/crypttab
  chmod 600 /etc/crypttab
  cmdline="rd.luks.uuid=$LUKS_UUID root=UUID=$ROOT_FS_UUID"
  # Also embed the same parameters in the initramfs (belt and suspenders with GRUB).
  echo "kernel_cmdline+=\" $cmdline \"" >> /etc/dracut.conf.d/00-quick.conf
fi
cat > /etc/default/grub <<EOF
GRUB_DISTRIBUTOR="Gentoo"
GRUB_TIMEOUT=3
GRUB_CMDLINE_LINUX="$cmdline"
EOF

# Bring the stage3 up to date from the latest binaries. This runs BEFORE the
# kernel/initramfs/GRUB steps so a kernel upgrade cannot leave GRUB stale. A
# failure here is not fatal: the system above is already complete.
world_status=skipped-by-config
if [[ $WORLD_UPDATE != skip ]]; then
  say "Updating @world from the latest official binaries (WORLD_UPDATE=$WORLD_UPDATE)"
  if emerge_binpkgs --update --deep --with-bdeps=n -- @world; then
    world_status=updated
  else
    world_status=PENDING
    warn "The @world update failed (WORLD_UPDATE=$WORLD_UPDATE). Continuing so kernel/initramfs/GRUB can be installed and validated; retry the update after first boot with: emerge --ask --update --deep --getbinpkg @world"
  fi
fi

# Optional packages (extras, Firefox) never abort the installation.

# Install initramfs tooling and (when selected) cryptsetup BEFORE the kernel package.
# gentoo-kernel-bin hooks may generate an initramfs during installation; dracut and
# cryptsetup must already be present for a LUKS-enabled install. The second phase
# excludes already-installed prerequisites to avoid duplicate package resolution.
# Install the boot-critical packages first. Desktop packages are handled separately
# so a missing SDDM/Plasma binpkg cannot abort before the kernel and bootloader exist.
pre_pkgs=(sys-boot/grub sys-kernel/installkernel sys-kernel/dracut)
[[ $BOOT_MODE == uefi ]] && pre_pkgs+=(sys-boot/efibootmgr sys-fs/dosfstools)
[[ $LUKS == 1 ]] && pre_pkgs+=(sys-fs/cryptsetup)
emerge --ask=n --getbinpkg --usepkg --binpkg-respect-use=y --noreplace \
  --jobs=1 --load-average="$((JOBS + 1))" "${pre_pkgs[@]}" \
  || die "Boot-critical packages (GRUB/initramfs tooling/cryptsetup) could not be installed even with official binpkgs preferred. See Portage errors above."
remaining_pkgs=()
for atom in "${all_pkgs[@]}"; do
  case $atom in
    sys-boot/grub|sys-kernel/installkernel|sys-kernel/dracut) continue ;;
    sys-boot/efibootmgr|sys-fs/dosfstools) [[ $BOOT_MODE == uefi ]] && continue ;;
    sys-fs/cryptsetup) [[ $LUKS == 1 ]] && continue ;;
  esac
  remaining_pkgs+=("$atom")
done
say "Installing the system (GRUB, KDE Plasma), official binaries first"
# Portage prefers binpkgs even if their USE metadata differs; only missing usable
# binaries may trigger source builds. Package merges stay serialized; MAKEOPTS keeps
# -j18 for the rare package that genuinely needs a source build.
use_mode=preferred-binpkg-source-fallback-only-if-missing
desktop_transaction_status=installed
if ! emerge --ask=n --getbinpkg --usepkg --binpkg-respect-use=y --noreplace \
  --jobs=1 --load-average="$((JOBS + 1))" "${remaining_pkgs[@]}"; then
  desktop_transaction_status=failed
  warn "The main desktop/runtime package transaction failed. Continuing with the independently installed boot chain so a Portage/KDE failure cannot by itself prevent kernel + initramfs + GRUB installation. Review the Portage error above; desktop/services may need repair after first boot."
fi

# Kernel: gentoo-kernel-bin ships the kernel and modules already built (no
# kernel compilation). installkernel is configured for the Handbook's dracut path;
# after unpacking, the installer regenerates and validates the initramfs explicitly.
say "Installing the prebuilt Gentoo kernel (boot-critical; no kernel compilation)"
# Recheck at the exact failure point: no inherited certificate may trigger UKI signing.
clear_inherited_secureboot_signing
if ! emerge_payload --noreplace sys-kernel/gentoo-kernel-bin; then
  warn "Initial prebuilt-kernel transaction failed. Reapplying the traditional dracut setup and retrying once."
  emerge --ask=n --getbinpkg --usepkg --binpkg-respect-use=y --noreplace \
    --jobs=1 --load-average="$((JOBS + 1))" sys-kernel/installkernel sys-kernel/dracut \
    || die "Kernel recovery prerequisites failed; the boot chain cannot be completed."
  clear_inherited_secureboot_signing
  emerge_payload --noreplace sys-kernel/gentoo-kernel-bin \
    || die "The prebuilt kernel payload failed twice; the installer cannot create a bootable system. See the Portage diagnostics immediately above."
fi
# Firmware is installed after the kernel so a firmware package conflict cannot prevent
# kernel/initramfs/GRUB setup. Missing firmware may affect particular devices, not bootloader discovery.
if ! emerge_payload --noreplace sys-kernel/linux-firmware; then
  warn "linux-firmware could not be installed; continuing boot-chain setup. GPU, Wi-Fi or other device firmware may need repair after first boot."
fi
grep -qxF 'sys-kernel/gentoo-kernel-bin' /var/lib/portage/world 2>/dev/null \
  || echo 'sys-kernel/gentoo-kernel-bin' >> /var/lib/portage/world


install_optional() {
  local -a want=()
  local a
  local -A seen_opt=()
  for a in "$@"; do
    [[ -n $a && -z ${seen_opt[$a]+x} ]] || continue
    seen_opt[$a]=1
    want+=("$a")
  done
  (( ${#want[@]} > 0 )) || return 0
  say "Installing optional packages (best effort): ${want[*]}"
  if emerge_binpkgs --noreplace -- "${want[@]}"; then return 0; fi
  warn "Combined optional install failed; retrying one package at a time."
  for a in "${want[@]}"; do
    if emerge_binpkgs --noreplace -- "$a"; then continue; fi
    if [[ $a == www-client/firefox-bin ]]; then
      warn "www-client/firefox-bin has no official binary; installing the prebuilt payload ebuild (nothing compiled)."
      emerge_payload --noreplace www-client/firefox-bin \
        || emerge_binpkgs --noreplace -- www-client/firefox \
        || warn "Firefox could not be installed; install it after the first boot."
    else
      warn "Optional package $a skipped (no official binary)."
    fi
  done
  return 0
}
install_optional "${opt_pkgs[@]}"
if compgen -G "/var/db/pkg/www-client/firefox-*" >/dev/null; then firefox_status=installed
elif [[ " ${opt_pkgs[*]} " == *firefox* ]]; then firefox_status=MISSING
else firefox_status=not-requested; fi

# With --binpkg-respect-use=y, verify the runtime-critical elogind flag where the
# installed SDDM/Plasma binary actually declares support for it. Abort rather than
# silently accept a desktop package known to lack the required OpenRC integration.
if [[ $INIT == openrc && $DESKTOP == kde ]]; then
  found_elogind_iuse=0
  for pkgdir in /var/db/pkg/gui-apps/sddm-* /var/db/pkg/kde-plasma/*; do
    [[ -d $pkgdir && -f $pkgdir/IUSE && -f $pkgdir/USE ]] || continue
    if grep -Eq '(^|[[:space:]])\+?elogind([[:space:]]|$)' "$pkgdir/IUSE"; then
      found_elogind_iuse=1
      if ! grep -Eq '(^|[[:space:]])elogind([[:space:]]|$)' "$pkgdir/USE"; then
        warn "Binary $(basename "$pkgdir") declares elogind support but was installed without USE=elogind; desktop login may need repair after first boot."
      fi
    fi
  done
  if (( ! found_elogind_iuse )); then
    warn "No installed SDDM/Plasma package metadata declared an elogind USE flag; the OpenRC elogind service and desktop validation will still be checked."
  fi
fi

# Whether installed from a binary or source fallback, the selected GRUB platform
# modules must exist before proceeding to grub-install.
if [[ $BOOT_MODE == uefi ]]; then need=x86_64-efi; else need=i386-pc; fi
if [[ ! -d /usr/lib/grub/$need ]]; then
  echo "The installed GRUB package does not provide the required $need platform (/usr/lib/grub/$need)."
  echo "Both binary preference and Portage fallback have completed, but the bootloader platform is still missing."
  exit 1
fi

select_installed_kernel() {
  local candidate base version
  local -a candidates=() versions=()
  shopt -s nullglob
  candidates=(/boot/vmlinuz-* /boot/kernel-*)
  shopt -u nullglob
  for candidate in "${candidates[@]}"; do
    [[ -s $candidate ]] || continue
    base=${candidate##*/}
    version=${base#vmlinuz-}; version=${version#kernel-}
    [[ -n $version ]] || continue
    # The image must correspond to a kernel module tree installed by the same ebuild.
    [[ -d "/lib/modules/$version" ]] || continue
    versions+=("$version")
  done
  (( ${#versions[@]} > 0 )) || die "No usable prebuilt kernel image with a matching /lib/modules/<version> tree exists in /boot."
  if (( ${#versions[@]} > 1 )); then
    warn "Multiple usable kernel images found; selecting the newest version with version-aware sorting."
  fi
  SELECTED_KERNEL_VERSION=$(printf '%s\n' "${versions[@]}" | sort -Vu | tail -n1)
  if [[ -s /boot/vmlinuz-$SELECTED_KERNEL_VERSION ]]; then
    SELECTED_KERNEL="/boot/vmlinuz-$SELECTED_KERNEL_VERSION"
  elif [[ -s /boot/kernel-$SELECTED_KERNEL_VERSION ]]; then
    SELECTED_KERNEL="/boot/kernel-$SELECTED_KERNEL_VERSION"
  else
    die "Could not resolve the selected kernel image for version $SELECTED_KERNEL_VERSION."
  fi
  SELECTED_INITRAMFS="/boot/initramfs-${SELECTED_KERNEL_VERSION}.img"
}
select_installed_kernel
kimg=$SELECTED_KERNEL
kver=$SELECTED_KERNEL_VERSION
expected_initrd=$SELECTED_INITRAMFS
[[ -s $kimg ]] || die "Kernel image is missing or empty: $kimg"
[[ -d "/lib/modules/$kver" ]] || die "Kernel modules are missing for $kver: /lib/modules/$kver"
command -v dracut >/dev/null 2>&1 || die "dracut is not installed; cannot create the required initramfs."
[[ -f /etc/dracut.conf.d/00-quick.conf ]] || die "dracut configuration is missing."

# Always regenerate the image after finalizing root/LUKS parameters. Passing the
# destination explicitly avoids relying on dracut's default filename or stale hooks.
luks_label=""
(( LUKS )) && luks_label=", LUKS modules enabled"
say "Generating a fresh initramfs with dracut (kernel=$kver$luks_label)"
rm -f -- "$expected_initrd"
if ! dracut --force --no-hostonly "$expected_initrd" "$kver"; then
  die "dracut failed to create $expected_initrd for kernel $kver; refusing to install GRUB without a valid initramfs."
fi
[[ -s $expected_initrd ]] || die "dracut returned success but the expected initramfs is missing or empty: $expected_initrd"
command -v lsinitrd >/dev/null 2>&1 || die "lsinitrd is unavailable; cannot validate the generated initramfs."
lsinitrd "$expected_initrd" >/dev/null 2>&1 || die "Generated initramfs is not a readable archive: $expected_initrd"
if (( LUKS )); then
  initrd_listing=$(lsinitrd "$expected_initrd" 2>/dev/null) \
    || die "Could not inspect the generated LUKS initramfs."
  grep -Eiq 'cryptsetup|90crypt|cryptroot' <<< "$initrd_listing" \
    || die "The generated initramfs does not contain cryptsetup support required for LUKS."
  grep -Eiq 'dm[-_]?crypt|dm_mod|/dm-' <<< "$initrd_listing" \
    || die "The generated initramfs does not contain device-mapper/crypt support required for LUKS."
  grep -Fq "rd.luks.uuid=$LUKS_UUID" /etc/default/grub \
    || die "GRUB kernel command line is missing the exact LUKS container UUID."
fi
unset initrd_listing

say "Installing the bootloader"
if [[ $BOOT_MODE == uefi ]]; then
  # Validate the EFI filesystem and paths before invoking GRUB.
  mountpoint -q /efi || die "EFI partition is not mounted at /efi."
  [[ -d /efi/EFI ]] || mkdir -p /efi/EFI
  grub_log=$(mktemp); chmod 600 "$grub_log"
  if grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=Gentoo >"$grub_log" 2>&1; then
    cat "$grub_log"
    grub_rc=0
  else
    grub_rc=$?
    cat "$grub_log" >&2
    grub_err=$(<"$grub_log")
    # Only treat NVRAM/firmware/efibootmgr failures as non-fatal and try --removable.
    if grep -Eiq 'efibootmgr|NVRAM|Boot (variable|entry)|efivars' <<<"$grub_err"; then
      warn "NVRAM registration failed (exit $grub_rc); original error preserved above. Trying --removable fallback."
      rm -f "$grub_log"; grub_log=$(mktemp); chmod 600 "$grub_log"
      if grub-install --target=x86_64-efi --efi-directory=/efi --removable >"$grub_log" 2>&1; then
        cat "$grub_log"
        grub_rc2=0
      else
        grub_rc2=$?
        cat "$grub_log" >&2
        rm -f "$grub_log"
        die "grub-install (--removable) failed (exit $grub_rc2) after NVRAM error (original exit $grub_rc)."
      fi
    else
      rm -f "$grub_log"
      die "grub-install (UEFI) failed (exit $grub_rc): $grub_err"
    fi
  fi
  rm -f "$grub_log"
  [[ -s /efi/EFI/BOOT/BOOTX64.EFI || -s /efi/EFI/Gentoo/grubx64.efi ]] \
    || die "GRUB EFI loader missing after installation."
else
  grub-install --target=i386-pc "$DISK" || die "grub-install (BIOS) failed."
  [[ -d /boot/grub/i386-pc ]] || die "GRUB BIOS modules missing after installation."
fi
# Force a firmware-discoverable UEFI fallback loader when the standard GRUB
# install succeeded but did not leave BOOTX64.EFI. Keep the vendor path too.
if [[ $BOOT_MODE == uefi && ! -s /efi/EFI/BOOT/BOOTX64.EFI ]]; then
  if [[ -s /efi/EFI/Gentoo/grubx64.efi ]]; then
    mkdir -p /efi/EFI/BOOT
    cp -f /efi/EFI/Gentoo/grubx64.efi /efi/EFI/BOOT/BOOTX64.EFI \
      || die "Could not create the UEFI removable-media fallback loader."
    sync
    warn "Created EFI/BOOT/BOOTX64.EFI fallback loader."
  else
    die "No GRUB EFI executable exists to create a fallback boot path."
  fi
fi
grub-mkconfig -o /boot/grub/grub.cfg || die "grub-mkconfig failed."
# Validate generated entries point to existing kernel/initramfs files.
grub_bad=0
while read -r cmd path; do
  [[ -n $path ]] || { echo "GRUB entry has an empty $cmd path"; grub_bad=1; continue; }
  if [[ -e "/boot${path}" || -e "$path" ]]; then
    :
  else
    echo "GRUB entry refers to missing $cmd: $path"
    grub_bad=1
  fi
done < <(grep -E '^[[:space:]]*(linux|initrd)[[:space:]]' /boot/grub/grub.cfg \
         | sed -E 's/^[[:space:]]+//' | awk '{print $1, $2}')
(( grub_bad == 0 )) || exit 1
grep -qE '^[[:space:]]*linux[[:space:]]' /boot/grub/grub.cfg || die "grub.cfg has no kernel entry."
selected_kernel_base=${kimg##*/}
[[ -s $kimg && -s $expected_initrd ]] || die "Selected kernel or initramfs is empty; refusing to mark installation bootable."
grep -E '^[[:space:]]*linux[[:space:]]' /boot/grub/grub.cfg | grep -F "$selected_kernel_base" >/dev/null \
  || die "GRUB does not reference the selected kernel image $selected_kernel_base."
grep -E '^[[:space:]]*initrd[[:space:]]' /boot/grub/grub.cfg | grep -F "${expected_initrd##*/}" >/dev/null \
  || die "GRUB does not reference the initramfs matching $selected_kernel_base."

say "Enabling services"
if [[ $INIT == openrc ]]; then
  enable_openrc_service() {
    local svc=$1 runlevel=${2:-default}
    if [[ ! -x "/etc/init.d/$svc" ]]; then
      warn "OpenRC service $svc is missing; skipping enablement so root/user credentials and boot validation can still finish."
      return 0
    fi
    rc-update add "$svc" "$runlevel" || warn "Could not enable OpenRC service $svc in $runlevel; repair it after first boot."
  }
  [[ $NETMGR == nm ]] && enable_openrc_service NetworkManager default
  [[ $NETMGR == dhcpcd ]] && enable_openrc_service dhcpcd default
  enable_openrc_service sysklogd default
  enable_openrc_service chronyd default
  if [[ $DESKTOP == kde ]]; then
    enable_openrc_service dbus default
    enable_openrc_service elogind boot
    if [[ ${DM_MODE:-sddm} == sddm ]]; then
      echo 'DISPLAYMANAGER="sddm"' > /etc/conf.d/display-manager
      enable_openrc_service display-manager default
    fi
  fi
else
  if [[ $NETMGR == nm ]]; then systemctl enable NetworkManager || warn "Could not enable NetworkManager; repair after first boot."; fi
  if [[ $NETMGR == dhcpcd ]]; then systemctl enable dhcpcd || warn "Could not enable dhcpcd; repair after first boot."; fi
  systemctl enable systemd-timesyncd || true
  systemd-machine-id-setup || true
  if [[ $DESKTOP == kde ]]; then
    for unit in pipewire.socket pipewire-pulse.socket wireplumber.service; do
      [[ -f /usr/lib/systemd/user/$unit ]] && systemctl --global enable "$unit" || true
    done
    if [[ ${DM_MODE:-sddm} == sddm ]]; then
      systemctl enable sddm || warn "Could not enable SDDM; repair after first boot."
      [[ -f /usr/lib/systemd/system/sddm.service ]] && ln -sf /usr/lib/systemd/system/sddm.service /etc/systemd/system/display-manager.service
      [[ -f /usr/lib/systemd/system/graphical.target ]] && ln -sf /usr/lib/systemd/system/graphical.target /etc/systemd/system/default.target
    fi
  fi
fi

if [[ $DESKTOP == kde && ${DM_MODE:-sddm} == tty ]]; then
  say "No display manager: Plasma will start when a normal user logs in on tty1"
  cat > /etc/profile.d/plasma-tty1.sh <<'PTTY'
# Start Plasma (Wayland) on tty1 for normal users. Official binhost has no SDDM binary.
if [ "$(id -u)" -ne 0 ] && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ] \
   && [ "$(tty 2>/dev/null)" = /dev/tty1 ] && command -v startplasma-wayland >/dev/null 2>&1; then
  exec dbus-run-session startplasma-wayland
fi
PTTY
  chmod 644 /etc/profile.d/plasma-tty1.sh
fi

say "Users and groups"
for g in wheel audio video usb input; do
  getent group "$g" >/dev/null || groupadd "$g"
done
printf '%s:%s\n' "root" "$ROOT_PASS" | chpasswd
for i in "${!USER_NAMES[@]}"; do
  u=${USER_NAMES[i]}
  if [[ ${USER_SUDO[i]} == 1 ]]; then groups=wheel,audio,video,usb,input; else groups=audio,video,usb,input; fi
  useradd -m -G "$groups" -s /bin/bash "$u"
  if [[ ${USER_SUDO[i]} == 1 ]]; then
    usermod -aG wheel "$u" || die "could not add administrator user $u to wheel"
  fi
  printf '%s:%s\n' "$u" "${USER_PASSES[i]}" | chpasswd
done
if [[ " ${USER_SUDO[*]} " == *" 1 "* ]]; then
  # Enable the standard wheel rule directly in /etc/sudoers when it exists commented.
  # Keep a backup and validate the full configuration before accepting the change.
  if grep -Eq '^[[:space:]]*#[[:space:]]*%wheel[[:space:]]+ALL=\(ALL:ALL\)[[:space:]]+ALL[[:space:]]*$' /etc/sudoers; then
    cp -f /etc/sudoers /etc/sudoers.gqi.bak
    sed -i -E 's/^[[:space:]]*#[[:space:]]*(%wheel[[:space:]]+ALL=\(ALL:ALL\)[[:space:]]+ALL)[[:space:]]*$/\1/' /etc/sudoers
    if command -v visudo >/dev/null 2>&1 && ! visudo -cf /etc/sudoers >/dev/null 2>&1; then
      mv -f /etc/sudoers.gqi.bak /etc/sudoers
      die "could not enable the commented wheel rule: /etc/sudoers would be invalid"
    fi
    rm -f /etc/sudoers.gqi.bak
    say "Enabled the commented %wheel rule in /etc/sudoers"
  fi

  # If /etc/sudoers has no active wheel rule, use a drop-in and ensure it is included.
  if ! grep -Eq '^[[:space:]]*%wheel[[:space:]]+ALL=\(ALL:ALL\)[[:space:]]+ALL[[:space:]]*$' /etc/sudoers; then
    install -d -m 755 /etc/sudoers.d
    if [[ ! -f /etc/sudoers.d/wheel ]] || ! grep -qxF '%wheel ALL=(ALL:ALL) ALL' /etc/sudoers.d/wheel; then
      printf '%s\n' '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
    fi
    chmod 440 /etc/sudoers.d/wheel
    if command -v visudo >/dev/null 2>&1; then
      visudo -cf /etc/sudoers.d/wheel || die "the wheel sudoers drop-in is invalid"
    fi
    if ! grep -Eq '^[#@]includedir[[:space:]]+/etc/sudoers\.d[[:space:]]*$' /etc/sudoers; then
      cp -f /etc/sudoers /etc/sudoers.gqi.bak
      printf '@includedir /etc/sudoers.d\n' >> /etc/sudoers
      if command -v visudo >/dev/null 2>&1 && ! visudo -cf /etc/sudoers >/dev/null 2>&1; then
        mv -f /etc/sudoers.gqi.bak /etc/sudoers
        die "could not enable /etc/sudoers.d: adding the includedir line made /etc/sudoers invalid"
      fi
      rm -f /etc/sudoers.gqi.bak
    fi
  fi
fi

# Secrets leave the target before the (slow) checks run.
rm -f /root/install.env /root/secrets.env /root/stage2.sh

say "Validating the installed system"
if ! ROOTPFX="" verify_system; then
  echo "Validation found non-boot issues; running the mandatory boot-chain checks separately." >&2
  VERIFY_FAILS=0
  verify_fstab
  verify_boot
  verify_luks
  if (( VERIFY_FAILS > 0 )); then
    die "Mandatory boot-chain validation failed ($VERIFY_FAILS issue(s)); do not reboot yet. Inspect the validation messages above."
  fi
  warn "Kernel, initramfs, root parameters and bootloader passed validation, but one or more non-boot checks failed. The OS boot chain is present; desktop/services/users may need repair."
  validation_status=boot-chain-valid-other-checks-failed
else
  validation_status=all-checks-passed
fi
notes=/root/gentoo-quick-install-notes.txt
{
  echo "Gentoo quick install - notes ($(date -Is))"
  echo
  echo "Package strategy: $use_mode (official binpkgs preferred; source fallback only if no usable binary exists)"
  echo "Validation status: ${validation_status:-unknown}"
  echo "Desktop transaction: ${desktop_transaction_status:-unknown}"
  echo "@world update   : $world_status"
  echo "Firefox         : $firefox_status"
  echo
  echo "Enabled USE flags of key packages:"
  for d in /var/db/pkg/gui-apps/sddm-* /var/db/pkg/kde-plasma/kwin-* /var/db/pkg/kde-plasma/plasma-workspace-* \
           /var/db/pkg/kde-plasma/plasma-desktop-* /var/db/pkg/net-misc/networkmanager-* /var/db/pkg/media-video/pipewire-*; do
    if [[ -f $d/USE ]]; then printf '  %s: %s\n' "${d#/var/db/pkg/}" "$(cat "$d/USE")"; fi
  done
  echo
  echo "Checked by the installer: files, services, users, sessions and shared libraries."
  echo "NOT provable from the installer - test after the first boot: graphical login, GPU acceleration, Wi-Fi, audio."
  if [[ $world_status == PENDING ]]; then echo "TODO: emerge --ask --update --deep --getbinpkg @world"; fi
  if [[ $firefox_status == MISSING ]]; then echo "TODO: install a web browser (no official Firefox binary was available)."; fi
  if [[ $use_mode == preferred-binary ]]; then echo "NOTE: Portage was allowed to use official binaries with differing USE metadata; critical desktop integration is validated separately."; fi
} > "$notes"
say "Notes saved in the new system as $notes"
cat "$notes"
say "Chroot finished."
CHROOT_EOF
  chmod 700 "$MNT/root/stage2.sh"
}

# ----------------------------------------------------------------------------
# Final validation (runs inside the chroot; ROOTPFX lets tests use a fake tree)
# ----------------------------------------------------------------------------
VERIFY_FAILS=0
v_ok()  { printf '    [ok]   %s\n' "$*"; }
v_bad() { printf '    [FAIL] %s\n' "$*" >&2; VERIFY_FAILS=$(( VERIFY_FAILS + 1 )); }

verify_fstab() {
  local r=${ROOTPFX:-} f="${ROOTPFX:-}/etc/fstab" dev mnt type rest
  local have_root=0 have_boot=0 have_efi=0 seen=" "
  if [[ ! -f $f ]]; then v_bad "fstab: $f is missing"; return 0; fi
  while read -r dev mnt type rest; do
    [[ -z ${dev:-} || $dev == \#* ]] && continue
    if [[ $type == swap ]]; then
      if [[ -f $r$dev ]]; then v_ok "fstab: swap $dev exists"; else v_bad "fstab: swap file $dev missing"; fi
      continue
    fi
    if [[ $dev == UUID=* && -z ${ROOTPFX:-} ]]; then
      if blkid -U "${dev#UUID=}" >/dev/null 2>&1; then :; else v_bad "fstab: $dev matches no device"; fi
    fi
    case $seen in *" $mnt "*) v_bad "fstab: mount point $mnt is listed twice" ;; esac
    seen+="$mnt "
    [[ -d $r$mnt ]] || v_bad "fstab: mount point $mnt does not exist"
    case $mnt in
      /)     have_root=1
             [[ $type == "$FS" ]] || v_bad "fstab: root type is $type, expected $FS"
             if [[ -n ${ROOT_FS_UUID:-} && $dev != "UUID=$ROOT_FS_UUID" ]]; then
               v_bad "fstab: root device $dev does not match the installed root filesystem UUID $ROOT_FS_UUID"
             fi ;;
      /boot) have_boot=1 ;;
      /efi)  have_efi=1 ;;
    esac
  done < "$f"
  if (( have_root )); then v_ok "fstab: root entry present"; else v_bad "fstab: no root (/) entry"; fi
  if (( have_boot )); then v_ok "fstab: /boot entry present"; else v_bad "fstab: no /boot entry"; fi
  if [[ ${BOOT_MODE:-} == uefi ]]; then
    if (( have_efi )); then v_ok "fstab: /efi entry present"; else v_bad "fstab: no /efi entry (UEFI)"; fi
  fi
  if [[ ${SWAP:-none} == swapfile ]]; then
    if grep -qE '^/swapfile[[:space:]]+none[[:space:]]+swap' "$f"; then
      v_ok "fstab: swapfile entry present"
    else
      v_bad "fstab: swapfile entry missing"
    fi
    if [[ -f $r/swapfile ]]; then
      if [[ $(stat -c %a "$r/swapfile") == 600 ]]; then v_ok "swapfile permissions 600"; else v_bad "swapfile is not mode 600"; fi
    fi
  fi
}

select_installed_kernel_pair() {  # sets SELECTED_KERNEL SELECTED_KERNEL_VERSION SELECTED_INITRAMFS
  local r=${1:-${ROOTPFX:-}} candidate base version
  local -a candidates=() versions=()
  SELECTED_KERNEL=""
  SELECTED_KERNEL_VERSION=""
  SELECTED_INITRAMFS=""
  shopt -s nullglob
  candidates=("$r"/boot/vmlinuz-* "$r"/boot/kernel-*)
  shopt -u nullglob
  for candidate in "${candidates[@]}"; do
    [[ -s $candidate ]] || continue
    base=${candidate##*/}
    version=${base#vmlinuz-}; version=${version#kernel-}
    [[ -n $version && -s "$r/boot/initramfs-${version}.img" ]] || continue
    versions+=("$version")
  done
  (( ${#versions[@]} > 0 )) || return 1
  SELECTED_KERNEL_VERSION=$(printf '%s\n' "${versions[@]}" | sort -Vu | tail -n1)
  if [[ -s "$r/boot/vmlinuz-$SELECTED_KERNEL_VERSION" ]]; then
    SELECTED_KERNEL="$r/boot/vmlinuz-$SELECTED_KERNEL_VERSION"
  elif [[ -s "$r/boot/kernel-$SELECTED_KERNEL_VERSION" ]]; then
    SELECTED_KERNEL="$r/boot/kernel-$SELECTED_KERNEL_VERSION"
  else
    return 1
  fi
  SELECTED_INITRAMFS="$r/boot/initramfs-${SELECTED_KERNEL_VERSION}.img"
  [[ -s $SELECTED_KERNEL && -s $SELECTED_INITRAMFS ]]
}

verify_boot() {
  local r=${ROOTPFX:-} cfg="${ROOTPFX:-}/boot/grub/grub.cfg" n=0 cmd path img
  if [[ -s $cfg ]]; then v_ok "grub.cfg present"; else v_bad "grub.cfg missing or empty: $cfg"; return 0; fi
  n=$(grep -cE '^[[:space:]]*linux[[:space:]]' "$cfg" || true)
  if (( n > 0 )); then v_ok "grub.cfg has $n kernel entr$( (( n == 1 )) && echo y || echo ies)"
  else v_bad "grub.cfg has no kernel entry"; fi
  if select_installed_kernel_pair "$r"; then
    v_ok "kernel/initramfs pair selected: $(basename "$SELECTED_KERNEL") + $(basename "$SELECTED_INITRAMFS") (version $SELECTED_KERNEL_VERSION)"
    local selected_kernel_base=${SELECTED_KERNEL##*/} selected_initramfs_base=${SELECTED_INITRAMFS##*/}
    if grep -E '^[[:space:]]*linux[[:space:]]' "$cfg" | grep -F "$selected_kernel_base" >/dev/null; then
      v_ok "GRUB references the selected kernel image"
    else
      v_bad "GRUB does not reference selected kernel image $selected_kernel_base"
    fi
    if grep -E '^[[:space:]]*initrd[[:space:]]' "$cfg" | grep -F "$selected_initramfs_base" >/dev/null; then
      v_ok "GRUB references the matching initramfs"
    else
      v_bad "GRUB does not reference matching initramfs $selected_initramfs_base"
    fi
  else
    v_bad "no valid kernel/initramfs pair found in $r/boot"
  fi
  # Require the exact root filesystem UUID in the generated kernel command line
  # for both plain root and LUKS installs; a syntactically valid grub.cfg can
  # still fail to boot if it points at the wrong root device.
  if [[ -n ${ROOT_FS_UUID:-} ]] && grep -E '^[[:space:]]*linux[[:space:]]' "$cfg" | grep -F "root=UUID=$ROOT_FS_UUID" >/dev/null; then
    v_ok "GRUB kernel command line references the root filesystem UUID"
  else
    v_bad "GRUB kernel command line lacks root=UUID=${ROOT_FS_UUID:-<unset>}"
  fi
  # Validate every path referenced by GRUB against the real files.
  while read -r cmd path; do
    # GRUB paths are relative to /boot or /; normalize by checking both.
    if [[ -e "$r$path" || -e "$r/boot$path" ]]; then
      v_ok "grub.cfg $cmd $path exists"
    else
      v_bad "grub.cfg refers to missing $cmd $path"
    fi
  done < <(grep -E '^[[:space:]]*(linux|initrd)[[:space:]]' "$cfg" \
           | sed -E 's/^[[:space:]]+//' | awk '{print $1, $2}')

  if [[ ${BOOT_MODE:-} == uefi ]]; then
    if [[ -s $r/efi/EFI/Gentoo/grubx64.efi || -s $r/efi/EFI/BOOT/BOOTX64.EFI ]]; then
      v_ok "UEFI loader present"
    else v_bad "no UEFI GRUB loader in /efi/EFI"; fi
  else
    if [[ -d $r/boot/grub/i386-pc ]]; then v_ok "BIOS GRUB modules present"
    else v_bad "BIOS GRUB modules (i386-pc) missing"; fi
  fi
}

verify_luks() {
  [[ ${LUKS:-0} == 1 ]] || return 0
  local r=${ROOTPFX:-} img lsout=""
  if grep -qxF "luks-$LUKS_UUID UUID=$LUKS_UUID none luks" "$r/etc/crypttab" 2>/dev/null; then
    v_ok "crypttab matches LUKS UUID"
  else v_bad "crypttab missing or inconsistent with the LUKS UUID"; fi
  if grep -q "rd.luks.uuid=$LUKS_UUID" "$r/boot/grub/grub.cfg" 2>/dev/null; then
    v_ok "kernel command line has rd.luks.uuid"
  else v_bad "grub.cfg lacks rd.luks.uuid=$LUKS_UUID"; fi
  if [[ -n ${ROOT_FS_UUID:-} ]] && { grep -E '^[[:space:]]*linux[[:space:]]' "$r/boot/grub/grub.cfg" 2>/dev/null | grep -F "root=UUID=$ROOT_FS_UUID" >/dev/null \
       || grep -Fq "root=UUID=$ROOT_FS_UUID" "$r/etc/default/grub" 2>/dev/null; }; then
    v_ok "kernel command line has the exact root filesystem UUID"
  else v_bad "GRUB/default configuration lacks root=UUID=$ROOT_FS_UUID"; fi
  if grep -qE 'add_dracutmodules\+=" *(dm crypt|crypt dm) *"' "$r/etc/dracut.conf.d/00-quick.conf" 2>/dev/null; then
    v_ok "dracut includes the crypt module"
  else v_bad "dracut is not configured for LUKS"; fi
  if [[ -z ${ROOTPFX:-} ]] && command -v lsinitrd >/dev/null 2>&1; then
    if select_installed_kernel_pair "${ROOTPFX:-}"; then
      img=$SELECTED_INITRAMFS
    else
      img=""
    fi
    lsout=""
    if [[ -n $img && -s $img ]]; then lsout=$(lsinitrd "$img" 2>/dev/null || true); fi
    if [[ -n $img && -s $img ]] && grep -Eiq 'cryptsetup|90crypt|crypt-gpg' <<< "$lsout" && grep -Eiq 'dm[-_]?crypt|/dm_mod|dm_mod' <<< "$lsout"; then
      v_ok "initramfs contains cryptsetup and crypt modules"
    else v_bad "initramfs lacks cryptsetup or crypt/dm modules"; fi
  fi
}

verify_services() {
  local r=${ROOTPFX:-} svc
  if [[ ${INIT:-openrc} == openrc ]]; then
    local rl=$r/etc/runlevels/default
    local -a want=(sysklogd chronyd)
    case ${NETMGR:-nm} in nm) want+=(NetworkManager) ;; dhcpcd) want+=(dhcpcd) ;; esac
    if [[ ${DESKTOP:-none} == kde ]]; then
      want+=(dbus)
      [[ ${DM_MODE:-sddm} == sddm ]] && want+=(display-manager)
    fi
    for svc in "${want[@]}"; do
      if [[ -e $rl/$svc || -L $rl/$svc ]]; then v_ok "openrc: $svc in default runlevel"
      else v_bad "openrc: $svc is not in the default runlevel"; fi
    done
    if [[ ${DESKTOP:-none} == kde ]]; then
      if [[ -e $r/etc/init.d/elogind || -e $r/etc/runlevels/boot/elogind ]]; then v_ok "openrc: elogind present"
      else v_bad "openrc: elogind not found"; fi
    fi
  else
    local sd=$r/etc/systemd/system
    local -a want=(systemd-timesyncd)
    case ${NETMGR:-nm} in nm) want+=(NetworkManager) ;; dhcpcd) want+=(dhcpcd) ;; esac
    for svc in "${want[@]}"; do
      if compgen -G "$sd/*.wants/$svc.service" >/dev/null || [[ $svc == systemd-timesyncd && -L $sd/multi-user.target.wants/systemd-timesyncd.service ]]; then
        v_ok "systemd: $svc enabled"
      else v_bad "systemd: $svc is not enabled"; fi
    done
  fi
}

verify_desktop() {
  [[ ${DESKTOP:-none} == kde ]] || return 0
  local r=${ROOTPFX:-} prof
  local dm=${DM_MODE:-sddm}
  if [[ $dm == sddm ]]; then
    if [[ -x $r/usr/bin/sddm ]]; then v_ok "sddm binary present"; else v_bad "sddm binary missing"; fi
    if [[ -x $r/usr/bin/sddm-greeter || -x $r/usr/bin/sddm-greeter-qt6 ]]; then
      v_ok "sddm greeter executable present"
    else
      v_bad "sddm greeter executable missing"
    fi
  else
    if [[ -f $r/etc/profile.d/plasma-tty1.sh ]]; then v_ok "tty1 Plasma autostart present (no display manager)"
    else v_bad "tty1 Plasma autostart script missing"; fi
  fi
  if [[ -x $r/usr/bin/startplasma-x11 || -x $r/usr/bin/startplasma-wayland ]]; then
    v_ok "Plasma session launcher present"
  else v_bad "no Plasma session launcher (startplasma-*)"; fi
  if [[ $dm == sddm ]]; then
    if [[ -f $r/etc/pam.d/sddm ]]; then v_ok "sddm PAM file present"; else v_bad "/etc/pam.d/sddm missing"; fi
  fi
  if [[ $dm != sddm ]]; then
    :
  elif [[ ${INIT:-openrc} == openrc ]]; then
    if grep -qx 'DISPLAYMANAGER="sddm"' "$r/etc/conf.d/display-manager" 2>/dev/null; then
      v_ok "openrc: display-manager set to sddm"
    else v_bad "openrc: /etc/conf.d/display-manager does not select sddm"; fi
    if [[ -e $r/etc/init.d/display-manager ]]; then v_ok "openrc: display-manager service script present"
    else v_bad "openrc: /etc/init.d/display-manager missing (gui-libs/display-manager-init)"; fi
  else
    if [[ -f $r/usr/lib/systemd/system/sddm.service ]]; then v_ok "systemd: sddm.service present"
    else v_bad "systemd: sddm.service missing"; fi
    if [[ -L $r/etc/systemd/system/display-manager.service ]] \
       && [[ $(readlink "$r/etc/systemd/system/display-manager.service") == *sddm* ]]; then
      v_ok "systemd: display-manager.service points to sddm"
    else v_bad "systemd: display-manager.service does not point to sddm"; fi
    prof=$(readlink "$r/etc/systemd/system/default.target" 2>/dev/null || true)
    if [[ $prof == *graphical.target ]]; then v_ok "systemd: default target is graphical"
    else v_bad "systemd: default target is not graphical"; fi
  fi
  if [[ -x $r/usr/bin/pipewire || -x $r/usr/bin/pipewire-pulse ]]; then v_ok "audio: pipewire installed"
  else v_bad "audio: pipewire not installed"; fi
  if [[ -x $r/usr/bin/firefox || -x $r/usr/bin/firefox-bin || -x $r/opt/firefox/firefox ]]; then
    v_ok "Firefox executable present"
  fi
  if [[ -f $r/usr/share/wayland-sessions/plasma.desktop || -f $r/usr/share/xsessions/plasma.desktop \
        || -f $r/usr/share/xsessions/plasmax11.desktop ]]; then v_ok "Plasma session file present"
  else v_bad "no Plasma session file in /usr/share/wayland-sessions or /usr/share/xsessions"; fi
  if [[ $dm == sddm ]]; then
    if grep -q '^sddm:' "$r/etc/passwd" 2>/dev/null; then v_ok "sddm system user exists"
    else v_bad "sddm system user is missing (acct-user/sddm)"; fi
  fi
  if [[ -x $r/usr/bin/plasmashell ]]; then v_ok "plasmashell present"; else v_bad "plasmashell missing"; fi
  if [[ -x $r/usr/bin/kwin_wayland || -x $r/usr/bin/kwin_x11 ]]; then v_ok "kwin present"
  else v_bad "kwin_wayland/kwin_x11 missing"; fi
  if [[ -z ${ROOTPFX:-} ]] && command -v ldd >/dev/null 2>&1; then
    local b ldd_out broken=0
    for b in sddm sddm-greeter sddm-greeter-qt6 plasmashell kwin_wayland kwin_x11 startplasma-wayland startplasma-x11; do
      [[ -x /usr/bin/$b ]] || continue
      ldd_out=$(ldd "/usr/bin/$b" 2>&1 || true)
      if grep -q 'not found' <<< "$ldd_out"; then v_bad "$b has unresolved shared libraries"; broken=1; fi
    done
    if (( broken == 0 )); then v_ok "desktop binaries have no unresolved shared libraries"; fi
  fi
  if [[ ${INIT:-openrc} == systemd ]] && [[ ! -L $r/etc/systemd/user/sockets.target.wants/pipewire.socket ]]; then
    echo "    [note] audio: pipewire.socket not enabled globally (check after first boot)"
  fi
}

verify_profile() {  # the Gentoo profile must match the chosen init system
  local r=${ROOTPFX:-} tgt
  tgt=$(readlink "$r/etc/portage/make.profile" 2>/dev/null || true)
  [[ -n $tgt ]] || { v_bad "no /etc/portage/make.profile link"; return 0; }
  if [[ ${INIT:-openrc} == systemd ]]; then
    if [[ $tgt == */systemd* ]]; then v_ok "profile matches systemd"; else v_bad "profile is not a systemd profile: $tgt"; fi
  else
    if [[ $tgt != *systemd* ]]; then v_ok "profile matches OpenRC"; else v_bad "profile is systemd but INIT=openrc: $tgt"; fi
  fi
  if [[ ${DESKTOP:-none} == kde ]]; then
    if [[ $tgt == *desktop/plasma* ]]; then v_ok "profile is a Plasma desktop profile"
    else v_bad "profile is not desktop/plasma: $tgt"; fi
  fi
}

verify_users() {
  local r=${ROOTPFX:-} i u g any_sudo=0
  for g in wheel audio video usb input; do
    if grep -q "^$g:" "$r/etc/group" 2>/dev/null; then v_ok "group $g exists"; else v_bad "group $g missing"; fi
  done
  for i in "${!USER_NAMES[@]}"; do
    u=${USER_NAMES[i]}
    local passwd_entry shadow_entry user_shell shadow_hash
    passwd_entry=$(awk -F: -v u="$u" '$1==u {print; exit}' "$r/etc/passwd" 2>/dev/null || true)
    if [[ -n $passwd_entry ]]; then
      v_ok "user $u exists"
      user_shell=$(cut -d: -f7 <<< "$passwd_entry")
      if [[ -x "$r$user_shell" && $user_shell == /* ]]; then v_ok "user $u has an executable login shell ($user_shell)"
      else v_bad "user $u has no usable login shell ($user_shell)"; fi
    else
      v_bad "user $u missing"
    fi
    shadow_entry=$(awk -F: -v u="$u" '$1==u {print; exit}' "$r/etc/shadow" 2>/dev/null || true)
    shadow_hash=$(cut -d: -f2 <<< "$shadow_entry")
    if [[ -n $shadow_entry && -n $shadow_hash && $shadow_hash != '!'* && $shadow_hash != '*'* ]]; then
      v_ok "user $u has an enabled password entry"
    else
      v_bad "user $u password entry is missing or locked; console/SDDM login may fail"
    fi
    if [[ ${USER_SUDO[i]:-0} == 1 ]]; then
      any_sudo=1
      if grep -E "^wheel:.*[:,]$u(,|$)" "$r/etc/group" >/dev/null 2>&1; then
        v_ok "user $u is in wheel"
      else
        v_bad "user $u is not in wheel"
      fi
    fi
  done
  local root_shadow root_hash
  root_shadow=$(awk -F: '$1=="root" {print; exit}' "$r/etc/shadow" 2>/dev/null || true)
  root_hash=$(cut -d: -f2 <<< "$root_shadow")
  if [[ -n $root_shadow && -n $root_hash && $root_hash != '!'* && $root_hash != '*'* ]]; then
    v_ok "root has an enabled password entry"
  else
    v_bad "root password entry is missing or locked"
  fi
  if (( any_sudo )); then
    if grep -Eq '^[[:space:]]*%wheel[[:space:]]+ALL=\(ALL:ALL\)[[:space:]]+ALL[[:space:]]*$' "$r/etc/sudoers" || \
       { [[ -f $r/etc/sudoers.d/wheel ]] && grep -qxF '%wheel ALL=(ALL:ALL) ALL' "$r/etc/sudoers.d/wheel"; }; then
      v_ok "active sudoers rule for wheel is present"
    else
      v_bad "active sudoers rule for wheel is missing or incorrect"
    fi
    if grep -Eq '^[#@]includedir[[:space:]]+/etc/sudoers\\.d[[:space:]]*$' "$r/etc/sudoers"; then
      v_ok "sudoers includes /etc/sudoers.d"
    else
      v_bad "/etc/sudoers does not include /etc/sudoers.d"
    fi
    if [[ -z ${ROOTPFX:-} ]] && command -v visudo >/dev/null 2>&1; then
      if visudo -cf /etc/sudoers >/dev/null 2>&1; then
        v_ok "visudo accepts the complete sudoers configuration"
      else
        v_bad "visudo reports an invalid sudoers configuration"
      fi
    fi
  fi
}

verify_system() {
  VERIFY_FAILS=0
  echo "Validation:"
  verify_profile
  verify_fstab
  verify_boot
  verify_luks
  verify_services
  verify_desktop
  verify_users
  if (( VERIFY_FAILS == 0 )); then echo "Validation passed."; return 0; fi
  echo "Validation found $VERIFY_FAILS problem(s)." >&2
  return 1
}

# ----------------------------------------------------------------------------
# Dry-run and full install
# ----------------------------------------------------------------------------
plan_chroot() {
  plan "chroot: emerge-webrsync; select matching profile; configure official binhost; prefer binpkgs and compile only when no usable binary exists"
  plan "chroot: select profile $( [[ $DESKTOP == kde ]] && echo "desktop/plasma" || echo "base" )$( [[ $INIT == systemd ]] && echo "/systemd" )"
  plan "chroot: configure locale/timezone and boot parameters; install boot prerequisites, GRUB, KDE and prebuilt kernel with official binpkgs preferred; update @world before package installation (best-effort by default); then optional extras"
  plan "chroot: set GRUB_PLATFORMS before package merge; use official GRUB binary when available"
  plan "chroot: kernel gentoo-kernel-bin (prebuilt), dracut (hostonly=no), GRUB config (ESP at /efi for UEFI)"
  plan "chroot: services for $INIT, users, groups$( [[ $DESKTOP == kde ]] && echo ', KDE Plasma and SDDM' )"
  plan "chroot: validation of fstab, GRUB kernel/initramfs/root UUID, LUKS, services, login shells/password entries and sudoers"
  plan "cleanup: remove secrets, swapoff, unmount (reverse order), close LUKS"
}

install_all() {
  prepare_disk
  create_swapfile
  install_stage3
  if (( DRY_RUN )); then
    plan_chroot
    return 0
  fi
  prep_chroot
  msg "Entering chroot (the long part; with binaries it should be fast)"
  if ! chroot "$MNT" /bin/bash /root/stage2.sh; then
    # BUG (fixed): this used to copy the log only to /home/$SUDO_USER or /root
    # of the LIVE ISO session. That location is tmpfs/overlay, exactly like
    # /tmp - it is NOT on the disk being installed to, so it is gone the moment
    # the live session ends (reboot, poweroff, even some "safe to remove media"
    # prompts). The warning calling it "safe from /tmp cleanups" was misleading:
    # it survives a `tmpwatch`-style /tmp cleanup, but not a reboot of the ISO.
    # Fix: save it INSIDE the target filesystem ($MNT), which lives on the real
    # disk and survives a reboot - still readable later by booting the live ISO
    # again and mounting/opening (LUKS) that partition, even though the system
    # itself cannot boot yet. We also keep a copy on the live session for
    # convenience, but it must never be the only copy.
    local keep_name="gentoo-install-failed-$(date +%Y%m%d-%H%M%S).log"
    local keep_target="" keep_live="${SUDO_USER:+/home/$SUDO_USER}"
    [[ -d ${keep_live:-} ]] || keep_live=/root
    keep_live="$keep_live/$keep_name"
    if (( TARGET_MOUNTED )) && [[ -d $MNT/root ]]; then
      keep_target="$MNT/root/$keep_name"
      cp -f -- "$LOG" "$keep_target" 2>/dev/null && chmod 644 "$keep_target" 2>/dev/null \
        && sync 2>/dev/null \
        && warn "A copy of the log was saved INSIDE the new system's disk at: $keep_target (persists even after you reboot off this live session; re-mount that partition, or boot the live ISO and open it with cryptsetup first if LUKS is used, to read it)." \
        || { keep_target=""; warn "Could not save the log copy onto the target disk."; }
    fi
    cp -f -- "$LOG" "$keep_live" 2>/dev/null && chmod 644 "$keep_live" 2>/dev/null \
      && warn "A second copy was also saved at: $keep_live (THIS ONE IS LOST if you reboot or shut down the live session - copy it to a USB stick or scp it elsewhere now if you need it)."
    echo "------------- recent installation log (actual failure context) -------------" >&2
    tail -n 160 "$LOG" 2>/dev/null >&2 || true
    echo "------------- matching Portage diagnostics -------------" >&2
    grep -n -i -B12 -A8 -E 'autounmask|masked|required by|blocks|cannot be installed|emerge: |no binary|Error:|failed \(configure phase\)|UKI signature|sbverify' "$LOG" 2>/dev/null | tail -n 100 >&2 || true
    echo "------------------------------------------------------------------------" >&2
    die "The installation stage failed after the disk was erased. This message alone does NOT prove the system is unbootable; inspect the actual error above and the durable log at ${keep_target:-$keep_live}. Do NOT rerun the installer blindly: it erases the target disk again. If boot-chain validation passed, repair the specific failed package/service instead of reinstalling."
  fi
  rm -f -- "$MNT/root/install.env" "$MNT/root/secrets.env" "$MNT/root/stage2.sh"
  msg "Installation complete! (validated inside the new system)"
  warn "These checks cannot prove the graphical session works. After the first boot test: SDDM graphical login, GPU acceleration, network and audio. Details and pending items: /root/gentoo-quick-install-notes.txt (inside the new system)."
  warn "All package transactions prefer official binpkgs and ignore USE mismatches for binpkg selection; source compilation is only the fallback when no usable binary exists. MAKEOPTS remains -j18."
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
main() {
  parse_args "$@"
  if (( ! DRY_RUN )); then
    [[ $EUID -eq 0 ]] || die "Run as root (sudo -i)."
  fi
  [[ $(uname -m) == x86_64 ]] || die "amd64 only for now."

  if (( UNATTENDED )); then
    [[ -f $CONFIG_FILE ]] || die "Config file not found: $CONFIG_FILE"
  fi
  detect_resources
  if (( ! UNATTENDED )); then
    clear 2>/dev/null || true
    printf '%s=== Gentoo Quick Install (binary packages) ===%s\n' "$C_B" "$C_0"
    (( DRY_RUN )) && printf '%s*** DRY RUN: nothing will be partitioned, formatted, mounted or changed ***%s\n' "$C_Y" "$C_0"
    if (( ! DRY_RUN )); then build_lists; fi
    collect_config
  else
    printf '%s=== Gentoo Quick Install (unattended) ===%s\n' "$C_B" "$C_0"
    (( DRY_RUN )) && msg "DRY RUN: nothing will be changed."
    load_config "$CONFIG_FILE"
    apply_config
  fi
  normalize_disk_paths
  validate_config
  # This installer does not provision or sign Secure Boot keys. Detect that before
  # the user confirms erasure, so the resulting EFI loader will not be rejected.
  check_secure_boot_compatibility
  # Establish networking before preflight tries to fetch missing tools.
  network_setup
  preflight_tools
  summary

  if (( DRY_RUN )); then
    msg "Planned steps (dry-run; nothing was changed):"
    install_all
    echo; msg "Dry-run complete. Run again without --dry-run to install."
    return 0
  fi

  if (( UNATTENDED )); then
    msg "Unattended mode: erasing $DISK in 5 seconds (Ctrl-C to abort)."
    sleep 5
  else
    menu "Continue?" "Yes, erase $DISK and install" "Cancel"
    (( MENU_IDX == 0 )) || { echo "Cancelled. Nothing was changed."; exit 0; }
    ask "To confirm, type the disk path ($DISK)"
    [[ $ANS == "$DISK" ]] || die "Confirmation did not match. Nothing was changed."
  fi

  # Repository checks must finish before install_all starts destructive disk work.
  preflight_binhost_before_wipe
  preflight_stage3_signer
  preflight_dependency_resolution

  # From here on, the whole output also goes to the log (no passwords are printed).
  exec > >(tee -a "$LOG") 2>&1
  printf '\n# gentoo-quick-install started %s\n' "$(date -Is)"

  install_all

  if (( UNATTENDED )); then
    msg "Done. Remove the install media and reboot when you are ready."
    return 0
  fi
  menu "Installation complete. What would you like to do?" "1) Reboot now" "2) Maybe later (exit installer)"
  cleanup_target
  CLEANED=1
  (( CLEANUP_OK )) || die "Cleanup failed; refusing to exit or reboot while target mounts, swap or LUKS may still be active."
  if (( MENU_IDX == 0 )); then
    echo "Remove the installation media. Rebooting the LiveCD system..."
    sleep 2
    reboot
  else
    echo "Leaving the installer. The LiveCD session will remain running; reboot whenever you are ready."
    return 0
  fi
}

# Tests source this file with GQI_LIB=1 to call individual functions.
if [[ ${GQI_LIB:-0} != 1 ]]; then
  main "$@"
fi
