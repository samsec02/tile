#!/usr/bin/env bash
# =============================================================================
#
#   ████████╗██╗██╗     ███████╗
#   ╚══██╔══╝██║██║     ██╔════╝    TILE // ARCH + HYPRLAND
#      ██║   ██║██║     █████╗      Automated tiling desktop deployment
#      ██║   ██║██║     ██╔══╝
#      ██║   ██║███████╗███████╗
#      ╚═╝   ╚═╝╚══════╝╚══════╝
#
#  Run from the official Arch ISO (UEFI mode, internet connected):
#      bash tile-archinstall.sh
#  Skip the animations:
#      FAST=1 bash tile-archinstall.sh
# =============================================================================
set -Eeuo pipefail

# ----------------------------- Common settings -------------------------------
TIMEZONE="Europe/Stockholm"
KEYMAP="sv-latin1"
XKB_LAYOUT="se"
LANG_LOCALE="en_US.UTF-8"
FORMAT_LOCALE="sv_SE.UTF-8"

COMMON_PKGS=(
  # Base system
  base linux linux-firmware
  btrfs-progs cryptsetup dosfstools
  networkmanager sudo nano vim git base-devel man-db man-pages
  pacman-contrib zram-generator xdg-user-dirs python
  # Hyprland desktop
  hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
  hyprlock hypridle waybar fuzzel mako swaybg
  greetd greetd-tuigreet
  kitty thunar gvfs tumbler firefox
  # Desktop helpers
  network-manager-applet blueman pavucontrol brightnessctl playerctl
  grim slurp wl-clipboard libnotify polkit gnome-keyring
  # Firewall
  ufw
  # Look & fonts
  gnome-themes-extra dconf gsettings-desktop-schemas
  ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji
  qt5-wayland qt6-wayland
  # Audio
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
  # Bluetooth
  bluez bluez-utils
  # Apps
  flatpak
)
EXTRA_PKGS=(hyprpolkitagent hyprland-guiutils cliphist papirus-icon-theme adwaita-cursors)

COMMON_SERVICES=(NetworkManager greetd bluetooth ufw fstrim.timer paccache.timer systemd-timesyncd systemd-boot-update)
COMMON_FLATPAKS=(
  com.discordapp.Discord
  org.signal.Signal
  com.spotify.Client
  com.vscodium.codium
  org.videolan.VLC
  com.valvesoftware.Steam
  com.bitwarden.desktop
  io.missioncenter.MissionCenter
)
FLATHUB="https://dl.flathub.org/repo/flathub.flatpakrepo"
WALLPAPER_DIR="/usr/share/backgrounds/tile"

# ----------------------------- Machine profiles ------------------------------
profile_laptop() {
  MACHINE="laptop"
  MACHINE_LABEL="LAPTOP // INTEL"
  DEFAULT_HOSTNAME="arch-laptop"
  IS_LAPTOP="yes"
  MACHINE_PKGS=(
    intel-ucode
    mesa vulkan-intel intel-media-driver
    sof-firmware
    power-profiles-daemon
  )
  MACHINE_SERVICES=(power-profiles-daemon)
  MACHINE_FLATPAKS=()
  KERNEL_PARAMS="quiet i915.enable_psr=0"
  BOOT_TIMEOUT=3
  NVIDIA="no"
  MKINIT_HOOKS="base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck"
}

profile_desktop() {
  MACHINE="desktop"
  MACHINE_LABEL="DESKTOP // AMD"
  DEFAULT_HOSTNAME="arch-desktop"
  IS_LAPTOP="no"
  MACHINE_PKGS=(
    amd-ucode
    mesa vulkan-radeon
  )
  MACHINE_SERVICES=()
  MACHINE_FLATPAKS=(
    net.lutris.Lutris
    com.heroicgameslauncher.hgl
  )
  KERNEL_PARAMS="quiet"
  BOOT_TIMEOUT=5
  NVIDIA="no"
  MKINIT_HOOKS="base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck"
}

profile_gaming_laptop() {
  MACHINE="gaming-laptop"
  MACHINE_LABEL="GAMING LAPTOP // NVIDIA"
  DEFAULT_HOSTNAME="arch-gaming"
  IS_LAPTOP="yes"
  MACHINE_PKGS=(
    intel-ucode
    mesa vulkan-intel intel-media-driver
    nvidia-open nvidia-utils nvidia-settings
    nvidia-prime
    sof-firmware
    power-profiles-daemon
  )
  MACHINE_SERVICES=(
    power-profiles-daemon
    nvidia-suspend nvidia-hibernate nvidia-resume
    nvidia-powerd
  )
  MACHINE_FLATPAKS=(
    net.lutris.Lutris
    com.heroicgameslauncher.hgl
  )
  KERNEL_PARAMS="quiet nvidia_drm.modeset=1"
  BOOT_TIMEOUT=3
  NVIDIA="yes"
  MKINIT_HOOKS="base systemd autodetect microcode modconf keyboard sd-vconsole block sd-encrypt filesystems fsck"
}

ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
MSR_GUID="e3c9e316-0b5c-4db8-817d-f92df00215ae"

# =============================================================================
#  UI ENGINE
# =============================================================================
FAST="${FAST:-0}"
LOG=/tmp/arch-install.log
: > "$LOG"

C0=$'\e[0m'; DIM=$'\e[2m'; WH=$'\e[1;37m'
CY=$'\e[1;36m'; MG=$'\e[1;35m'; BL=$'\e[1;34m'
GR=$'\e[1;32m'; YL=$'\e[1;33m'; RD=$'\e[1;31m'

BOX_W=62
RUN_PID=""

cols()       { tput cols 2>/dev/null || echo 80; }
rep()        { local s="" i; for ((i=0; i<$2; i++)); do s+="$1"; done; printf '%s' "$s"; }
pause()      { [[ "$FAST" == 1 ]] || sleep "$1"; }
fmt_time()   { printf '%02d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }
cursor_off() { tput civis 2>/dev/null || true; }
cursor_on()  { tput cnorm 2>/dev/null || true; }

typeout() {
  local s="$1" d="${2:-0.008}" i
  if [[ "$FAST" == 1 ]]; then printf '%s' "$s"; return; fi
  for ((i=0; i<${#s}; i++)); do printf '%s' "${s:i:1}"; sleep "$d"; done
}

section() {
  local title=" $1 // $2 "
  printf '\n  %s══[%s%s%s]%s%s\n\n' "$MG" "$WH" "$title" "$MG" "$(rep ═ $(( BOX_W - ${#title} - 4 )))" "$C0"
  pause 0.15
}

box() {
  local title="$1" l inner=$(( BOX_W - 2 )); shift
  printf '  %s╔══[ %s%s%s ]%s╗%s\n' "$CY" "$WH" "$title" "$CY" "$(rep ═ $(( BOX_W - 6 - ${#title} )))" "$C0"
  for l in "$@"; do
    printf '  %s║%s %-*s %s║%s\n' "$CY" "$C0" "$inner" "${l:0:$inner}" "$CY" "$C0"
    pause 0.02
  done
  printf '  %s╚%s╝%s\n' "$CY" "$(rep ═ "$BOX_W")" "$C0"
}

ok()   { printf '  %s[%s  OK  %s]%s %s\n' "$DIM" "$GR" "$DIM" "$C0" "$1"; pause 0.06; }
note() { printf '  %s[%s INFO %s]%s %s\n' "$DIM" "$CY" "$DIM" "$C0" "$1"; }
warn() { printf '  %s[%s WARN %s]%s %s\n' "$DIM" "$YL" "$DIM" "$C0" "$1"; }

dots() {
  printf '%s %s%s%s %s' "$1" "$DIM" "$(rep . $(( 22 - ${#1} )))" "$C0" "$2"
}

die() {
  cursor_on
  printf '\n  %s╔%s╗%s\n' "$RD" "$(rep ═ "$BOX_W")" "$C0"
  printf '  %s║%s %-*s %s║%s\n' "$RD" "$WH" $(( BOX_W - 2 )) "!! SYSTEM HALT" "$RD" "$C0"
  printf '  %s║%s %-*s %s║%s\n' "$RD" "$C0" $(( BOX_W - 2 )) "${1:0:$(( BOX_W - 2 ))}" "$RD" "$C0"
  printf '  %s╚%s╝%s\n\n' "$RD" "$(rep ═ "$BOX_W")" "$C0"
  exit 1
}

ask() {
  local -n __ans="$2"
  printf '  %s►%s %s' "$CY" "$C0" "$1"
  IFS= read -r __ans
}

read_secret() {
  local -n __sec="$2"
  local c
  __sec=""
  printf '  %s►%s %s: ' "$CY" "$C0" "$1"
  while IFS= read -rsn1 c; do
    if [[ -z "$c" ]]; then
      break
    elif [[ "$c" == $'\x7f' || "$c" == $'\b' ]]; then
      if [[ -n "$__sec" ]]; then __sec="${__sec%?}"; printf '\b \b'; fi
    else
      __sec+="$c"; printf '%s*%s' "$MG" "$C0"
    fi
  done
  echo
}

ask_password() {
  local p1 p2
  local -n __pw="$2"
  while true; do
    read_secret "$1" p1
    read_secret "Confirm" p2
    if [[ -n "$p1" && "$p1" == "$p2" ]]; then __pw="$p1"; return; fi
    warn "Empty or mismatched — try again."
  done
}

fail_screen() {
  cursor_on
  printf '\n  %s╔%s╗%s\n' "$RD" "$(rep ═ "$BOX_W")" "$C0"
  printf '  %s║%s %-*s %s║%s\n' "$RD" "$WH" $(( BOX_W - 2 )) "!! DEPLOYMENT FAILED" "$RD" "$C0"
  printf '  %s║%s %-*s %s║%s\n' "$RD" "$C0" $(( BOX_W - 2 )) "Step: ${1:0:50}" "$RD" "$C0"
  printf '  %s╚%s╝%s\n' "$RD" "$(rep ═ "$BOX_W")" "$C0"
  printf '\n  %sLast lines of %s:%s\n' "$DIM" "$LOG" "$C0"
  tail -n 20 "$LOG" | sed 's/^/    /'
  printf '\n  Nothing important is lost — fix the problem and run the script again.\n\n'
  exit 1
}

STEP=0; TOTAL=0; LAST_OK="yes"
SPIN=("▓░░░░░" "▒▓░░░░" "░▒▓░░░" "░░▒▓░░" "░░░▒▓░" "░░░░▒▓" "░░░░▓▒" "░░░▓▒░" "░░▓▒░░" "░▓▒░░░")
_run() {
  local mode="$1" label="$2"; shift 2
  local t0=$SECONDS i=0 rc=0 head width tailtxt
  STEP=$(( STEP + 1 ))
  head=$(printf '  %s[%02d/%02d]%s %-26s' "$MG" "$STEP" "$TOTAL" "$C0" "${label:0:26}")
  printf '\n>>> [%02d/%02d] %s\n' "$STEP" "$TOTAL" "$label" >> "$LOG"

  ( trap - ERR; "$@" ) >> "$LOG" 2>&1 &
  RUN_PID=$!
  cursor_off
  while kill -0 "$RUN_PID" 2>/dev/null; do
    width=$(( $(cols) - 52 ))
    tailtxt=""
    if (( width > 12 )); then
      tailtxt=$(tail -n 1 "$LOG" 2>/dev/null | tr '\r' '\n' | tail -n 1 | tr -cd '[:print:]')
      tailtxt="${tailtxt:0:$width}"
    fi
    printf '\r\e[K%s %s%s%s %s%s%s %s%s%s' "$head" "$CY" "${SPIN[i % 10]}" "$C0" \
      "$DIM" "$(fmt_time $(( SECONDS - t0 )))" "$C0" "$DIM" "$tailtxt" "$C0"
    i=$(( i + 1 ))
    sleep 0.12
  done
  wait "$RUN_PID" || rc=$?
  RUN_PID=""
  cursor_on

  local took; took=$(fmt_time $(( SECONDS - t0 )))
  if (( rc == 0 )); then
    printf '\r\e[K%s %s██████%s %s%s%s  %s[ DONE ]%s\n' "$head" "$GR" "$C0" "$DIM" "$took" "$C0" "$GR" "$C0"
    LAST_OK="yes"
  elif [[ "$mode" == soft ]]; then
    printf '\r\e[K%s %s░░░░░░%s %s%s%s  %s[DEFER ]%s\n' "$head" "$YL" "$C0" "$DIM" "$took" "$C0" "$YL" "$C0"
    LAST_OK="no"
  else
    printf '\r\e[K%s %s██████%s %s%s%s  %s[ FAIL ]%s\n' "$head" "$RD" "$C0" "$DIM" "$took" "$C0" "$RD" "$C0"
    fail_screen "$label"
  fi
}
run() { _run hard "$@"; }
try() { _run soft "$@"; }

on_err() {
  cursor_on
  printf '\n  %s[ FAIL ]%s Unexpected error on line %s. Log: %s\n\n' "$RD" "$C0" "$1" "$LOG"
}
on_int() {
  trap - INT TERM
  cursor_on; stty echo 2>/dev/null || true
  printf '\n\n  %s[ABORT ]%s Deployment cancelled by operator.\n\n' "$YL" "$C0"
  kill 0 2>/dev/null || true
  exit 130
}
trap 'on_err $LINENO' ERR
trap on_int INT
trap 'cursor_on; stty echo 2>/dev/null || true' EXIT

# ----------------------------- Visual effects --------------------------------
glitch() {
  [[ "$FAST" == 1 ]] && return 0
  local i j line n=$(( ($(cols) - 4) / 5 ))
  (( n > 14 )) && n=14
  cursor_off
  for ((i=0; i<14; i++)); do
    line=""
    for ((j=0; j<n; j++)); do line+=$(printf '%04X ' $(( RANDOM * 2 % 65536 ))); done
    printf '  %s%s%s\n' "$DIM" "$line" "$C0"
    sleep 0.03
  done
  sleep 0.15
  cursor_on
}

banner() {
  local art=(
    '████████╗██╗██╗     ███████╗'
    '╚══██╔══╝██║██║     ██╔════╝'
    '   ██║   ██║██║     █████╗  '
    '   ██║   ██║██║     ██╔══╝  '
    '   ██║   ██║███████╗███████╗'
    '   ╚═╝   ╚═╝╚══════╝╚══════╝'
  )
  local colors=("$BL" "$BL" "$CY" "$CY" "$MG" "$MG")
  local side=(
    ""
    "${WH}ARCH + HYPRLAND${C0}  ${DIM}tiling deployment v2.2${C0}"
    "${DIM}dynamic tiling // wayland // 10 themes${C0}"
    "${DIM}status   ${C0}${GR}ready${C0}"
    "${DIM}target   ${C0}x86_64 / uefi / luks2"
    ""
  )
  local i
  printf '\n'
  for i in "${!art[@]}"; do
    printf '   %s%s%s    %s\n' "${colors[i]}" "${art[i]}" "$C0" "${side[i]}"
    pause 0.05
  done
  printf '   %s%s%s\n' "$DIM" "$(rep ─ 66)" "$C0"
}

done_banner() {
  local art=(
    '██████╗  ██████╗ ███╗   ██╗███████╗'
    '██╔══██╗██╔═══██╗████╗  ██║██╔════╝'
    '██║  ██║██║   ██║██╔██╗ ██║█████╗  '
    '██║  ██║██║   ██║██║╚██╗██║██╔══╝  '
    '██████╔╝╚██████╔╝██║ ╚████║███████╗'
    '╚═════╝  ╚═════╝ ╚═╝  ╚═══╝╚══════╝'
  )
  local colors=("$GR" "$GR" "$CY" "$CY" "$MG" "$MG") i
  printf '\n'
  for i in "${!art[@]}"; do
    printf '   %s%s%s\n' "${colors[i]}" "${art[i]}" "$C0"
    pause 0.06
  done
}

app_name() {
  case "$1" in
    *Discord) echo Discord ;;   *Signal) echo Signal ;;    *spotify*) echo Spotify ;;
    *codium)  echo VSCodium ;;  *VLC)    echo VLC ;;       *Steam)    echo Steam ;;
    *bitwarden*) echo Bitwarden ;; *Lutris) echo Lutris ;; *hgl)      echo Heroic ;;
    *MissionCenter) echo "Mission-Center" ;;
    *) echo "${1##*.}" ;;
  esac
}

# =============================================================================
#  PHASE 0 — BOOT SEQUENCE
# =============================================================================
printf '\e[2J\e[H'
glitch
printf '\e[2J\e[H'
banner

[[ $EUID -eq 0 ]] || die "Run as root (default on the Arch ISO)."

section "PHASE 0" "BOOT SEQUENCE"
printf '  '; typeout "Initializing tiling deployment core..."; printf '\n'; pause 0.2

[[ -d /sys/firmware/efi/efivars ]] || die "Not booted in UEFI mode. Enable UEFI and disable CSM/Legacy in BIOS."
FW_BITS=$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null || echo "64")
ok "$(dots "Firmware" "UEFI ${FW_BITS}-bit")"

loadkeys "$KEYMAP"
ok "$(dots "Keymap" "$KEYMAP")"

ping -c1 -W3 archlinux.org &>/dev/null || die "No uplink. Wi-Fi: iwctl -> station wlan0 connect \"SSID\""
ok "$(dots "Uplink" "archlinux.org reachable")"

timedatectl set-ntp true
ok "$(dots "Clock sync" "NTP enabled")"

umount -R /mnt 2>/dev/null || true
umount /tmp/winesp 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true
ok "$(dots "Workspace" "clean")"

# =============================================================================
#  PHASE 1 — SYSTEM SCAN & AUTO-DETECTION
# =============================================================================
section "PHASE 1" "SYSTEM SCAN"

CPU_NAME=$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo)
CPU_NAME=$(echo "$CPU_NAME" | tr -s ' ')
RAM_MIB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
GPU_LIST=""
if command -v lspci &>/dev/null; then
  GPU_LIST=$(lspci | grep -Ei 'vga|3d controller|display controller' \
             | sed -E 's/^[^:]+: [^:]+: //; s/ \(rev [^)]*\)//' || true)
fi

SCAN_LINES=("CPU      : ${CPU_NAME:-unknown}")
if [[ -n "$GPU_LIST" ]]; then
  while IFS= read -r g; do SCAN_LINES+=("GPU      : $g"); done <<< "$GPU_LIST"
else
  SCAN_LINES+=("GPU      : unknown")
fi
SCAN_LINES+=("MEMORY   : $(( (RAM_MIB + 512) / 1024 )) GiB")
SCAN_LINES+=("FIRMWARE : UEFI ${FW_BITS}-bit")
box "HARDWARE" "${SCAN_LINES[@]}"

# Auto-detect target profile
if grep -qi 'nvidia' <<< "$GPU_LIST"; then
  profile_gaming_laptop
elif grep -qiE 'amd|ati|radeon' <<< "$GPU_LIST" && grep -qi 'amd' <<< "$CPU_NAME"; then
  profile_desktop
else
  profile_laptop
fi

echo
note "Auto-detected profile: ${MG}${MACHINE_LABEL}${C0}"
ask "Confirm detected hardware profile? [Y/n]: " CONFIRM_HW
if [[ "${CONFIRM_HW,,}" == "n" ]]; then
  printf '\n  %s┌─ MANUAL PROFILE OVERRIDE %s%s\n' "$CY" "$(rep ─ 36)" "$C0"
  printf '  %s│%s  %s[1]%s LAPTOP         %sIntel CPU/GPU / power profiles%s\n'      "$CY" "$C0" "$MG" "$C0" "$DIM" "$C0"
  printf '  %s│%s  %s[2]%s DESKTOP        %sAMD CPU/GPU / dual-boot support%s\n'    "$CY" "$C0" "$MG" "$C0" "$DIM" "$C0"
  printf '  %s│%s  %s[3]%s GAMING LAPTOP  %sIntel + NVIDIA hybrid graphics%s\n'     "$CY" "$C0" "$MG" "$C0" "$DIM" "$C0"
  printf '  %s└%s%s\n' "$CY" "$(rep ─ 62)" "$C0"
  while true; do
    ask "Select profile [1-3]: " CHOICE
    case "$CHOICE" in
      1) profile_laptop;        break ;;
      2) profile_desktop;       break ;;
      3) profile_gaming_laptop; break ;;
      *) warn "Type 1, 2 or 3." ;;
    esac
  done
fi
ok "Profile locked: ${MG}${MACHINE_LABEL}${C0}"

PKGS=("${COMMON_PKGS[@]}" "${MACHINE_PKGS[@]}")
SERVICES=("${COMMON_SERVICES[@]}" "${MACHINE_SERVICES[@]}")
FLATPAKS=("${COMMON_FLATPAKS[@]}" "${MACHINE_FLATPAKS[@]}")

# =============================================================================
#  PHASE 2 — TARGET ACQUISITION & IDENTITY
# =============================================================================
section "PHASE 2" "TARGET ACQUISITION"

printf '  %sAvailable drives:%s\n' "$DIM" "$C0"
lsblk -dpno NAME,SIZE,MODEL,TRAN -e 7,11 | sed "s/^/    ${CY}►${C0} /"
echo
ask "Drive to ERASE and install on (e.g. /dev/nvme0n1): " DISK
[[ -b "$DISK" ]] || die "$DISK is not a block device."

ISO_DEV=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)
if [[ -n "$ISO_DEV" && "$ISO_DEV" == "$DISK"* ]]; then
  die "$DISK is the USB stick you booted from. Pick an internal drive."
fi

CONFIRM_WORD="ERASE"
if lsblk -lno FSTYPE,PARTTYPE "$DISK" | grep -qiE "ntfs|bitlocker|$MSR_GUID"; then
  echo
  lsblk -po NAME,SIZE,FSTYPE,LABEL,MODEL "$DISK" | sed 's/^/    /'
  warn "${YL}WINDOWS DETECTED on this drive!${C0}"
  warn "For dual boot, install Arch on a separate drive."
  CONFIRM_WORD="ERASE WINDOWS"
fi

echo
while true; do
  ask "Username [user]: " USERNAME
  USERNAME="${USERNAME:-user}"
  USERNAME="${USERNAME,,}"
  [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
  warn "Lowercase letters, digits, underscores, or dashes only (must start with a letter)."
done
ask "Display name [${USERNAME^}]: " FULLNAME
FULLNAME="${FULLNAME:-${USERNAME^}}"
ok "Operator: ${CY}${USERNAME}${C0} (${FULLNAME})"

echo
while true; do
  ask "Hostname [${DEFAULT_HOSTNAME}]: " HOSTNAME
  HOSTNAME="${HOSTNAME:-$DEFAULT_HOSTNAME}"
  HOSTNAME="${HOSTNAME,,}"
  [[ "$HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] && break
  warn "Letters, digits and dashes only (cannot start/end with a dash)."
done
ok "Hostname: ${CY}${HOSTNAME}${C0}"

WIN_ESP=""
ADD_WINDOWS="no"
if [[ "$MACHINE" == "desktop" ]]; then
  mkdir -p /tmp/winesp
  while read -r part ptype; do
    [[ "${ptype,,}" == "$ESP_GUID" ]] || continue
    [[ "$part" == "$DISK"* ]] && continue
    if mount -o ro "$part" /tmp/winesp 2>/dev/null; then
      [[ -f /tmp/winesp/EFI/Microsoft/Boot/bootmgfw.efi ]] && WIN_ESP="$part"
      umount /tmp/winesp
    fi
    [[ -n "$WIN_ESP" ]] && break
  done < <(lsblk -lnpo NAME,PARTTYPE)

  if [[ -n "$WIN_ESP" ]]; then
    note "Windows boot manager found on $WIN_ESP"
    ask "Add Windows to the Arch boot menu? [Y/n]: " yn
    [[ "${yn,,}" == "n" ]] || ADD_WINDOWS="yes"
  else
    note "No Windows EFI found on other drives — use your motherboard boot menu for Windows."
  fi
fi

DISK_BYTES=$(lsblk -bdno SIZE "$DISK")
DISK_GIB=$(( DISK_BYTES / 1024 / 1024 / 1024 ))
ZRAM_MIB=$(( RAM_MIB / 2 < 8192 ? RAM_MIB / 2 : 8192 ))

APP_LINES=(); line="Apps     :"
for f in "${FLATPAKS[@]}"; do
  n=$(app_name "$f")
  if (( ${#line} + ${#n} + 1 > BOX_W - 4 )); then APP_LINES+=("$line"); line="          "; fi
  line+=" $n"
done
APP_LINES+=("$line")

PLAN=(
  "Profile  : $MACHINE_LABEL"
  "Drive    : $DISK (~${DISK_GIB} GiB, ENTIRE DRIVE)"
  "  [1] EFI   1 GiB FAT32 -> /boot"
  "  [2] ROOT  ~$(( DISK_GIB - 1 )) GiB LUKS2 -> Btrfs"
  "            @ @home @log @pkg @snapshots"
  "Swap     : zram ~$(( ZRAM_MIB / 1024 )) GiB (compressed RAM)"
  "Hostname : $HOSTNAME"
  "Operator : $USERNAME (sudo) / root locked"
  "Desktop  : Hyprland / Waybar / 5 Themes (Dark + Light)"
  "Login    : greetd + tuigreet"
  "Firewall : ufw on (incoming blocked, outgoing allowed)"
  "Locale   : English UI / Swedish keyboard + formats"
  "Kernel   : $KERNEL_PARAMS"
  "${APP_LINES[@]}"
)
[[ "$MACHINE" == "desktop" ]] && PLAN+=("Windows  : $( [[ $ADD_WINDOWS == yes ]] && echo "in boot menu (read-only copy)" || echo "not in boot menu")")
echo
box "DEPLOYMENT PLAN" "${PLAN[@]}"

echo
printf '  %s!! ALL DATA ON %s WILL BE DESTROYED !!%s\n\n' "$RD" "$DISK" "$C0"
ask "Type ${RD}${CONFIRM_WORD}${C0} to arm the deployment: " CONFIRM
[[ "$CONFIRM" == "$CONFIRM_WORD" ]] || die "Aborted by operator. Nothing was changed."
ok "${RD}Deployment ARMED${C0}"

# =============================================================================
#  PHASE 3 — CREDENTIALS
# =============================================================================
section "PHASE 3" "CREDENTIALS"
note "Disk encryption key — typed at every boot ($KEYMAP layout)."
ask_password "Encryption key" LUKS_PASS
ok "Encryption key stored in memory"
echo
note "Login password for '$USERNAME' (also unlocks lock screen + keyring)."
ask_password "User password" USER_PASS
ok "Credentials locked"

echo
cursor_off
for i in 3 2 1; do
  printf '\r  %sDEPLOYING IN %s%s%s ...  %s(Ctrl+C to abort)%s' "$YL" "$WH" "$i" "$YL" "$DIM" "$C0"
  sleep 1
done
printf '\r\e[K'
cursor_on

if [[ "$DISK" =~ [0-9]$ ]]; then PART="${DISK}p"; else PART="$DISK"; fi
ESP="${PART}1"
CRYPT="${PART}2"

# =============================================================================
#  STEP FUNCTIONS
# =============================================================================
do_partition() {
  for p in $(lsblk -lnpo NAME "$DISK" | tail -n +2); do wipefs -af "$p" || true; done
  wipefs -af "$DISK"
  sgdisk --zap-all "$DISK"
  sgdisk -n1:0:+1G -t1:ef00 -c1:EFI \
         -n2:0:0   -t2:8309 -c2:cryptroot "$DISK"
  partprobe "$DISK"
  udevadm settle
}

do_esp() { mkfs.fat -F32 -n EFI "$ESP"; }

do_luks() {
  printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "$CRYPT"
  printf '%s' "$LUKS_PASS" | cryptsetup open --allow-discards --key-file=- "$CRYPT" cryptroot
}

do_btrfs() {
  mkfs.btrfs -f -L arch /dev/mapper/cryptroot
  mount /dev/mapper/cryptroot /mnt
  for sv in @ @home @log @pkg @snapshots; do btrfs subvolume create "/mnt/$sv"; done
  umount /mnt

  local o="noatime,compress=zstd"
  mount -o "$o,subvol=@" /dev/mapper/cryptroot /mnt
  mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,boot}
  mount -o "$o,subvol=@home"      /dev/mapper/cryptroot /mnt/home
  mount -o "$o,subvol=@log"       /dev/mapper/cryptroot /mnt/var/log
  mount -o "$o,subvol=@pkg"       /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
  mount -o "$o,subvol=@snapshots" /dev/mapper/cryptroot /mnt/.snapshots
  mount -o fmask=0077,dmask=0077 "$ESP" /mnt/boot
}

do_keyring() {
  sed -Ei 's/^#?ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
  pacman -Sy --noconfirm archlinux-keyring
}

do_pacstrap() {
  mkdir -p /mnt/etc
  printf 'KEYMAP=%s\nXKBLAYOUT=%s\n' "$KEYMAP" "$XKB_LAYOUT" > /mnt/etc/vconsole.conf
  pacstrap -K /mnt "${PKGS[@]}"
}

do_extras() {
  local p failed=0
  for p in "${EXTRA_PKGS[@]}"; do
    arch-chroot /mnt pacman -S --needed --noconfirm "$p" || { echo "SKIPPED: $p"; failed=1; }
  done
  return "$failed"
}

do_fstab() {
  genfstab -U /mnt >> /mnt/etc/fstab
  sed -Ei 's/,?subvolid=[0-9]+//' /mnt/etc/fstab
}

# -----------------------------------------------------------------------------
#  Desktop environment, 10 themes (5 Dark + 5 Light) & wallpapers
# -----------------------------------------------------------------------------
do_desktop() {
  local S=/mnt/etc/skel/.config
  mkdir -p "$S"/{hypr,waybar/themes,kitty/themes,fuzzel/themes,mako/themes,gtk-3.0,gtk-4.0,tile} \
           /mnt/usr/local/bin /mnt/usr/local/share/tile "/mnt$WALLPAPER_DIR"

  # ---- Multi-theme Wallpaper Generator (Dark + Light per family) ------------
  cat > /mnt/root/gen-wallpaper.py <<'PY'
#!/usr/bin/env python3
import math, struct, sys, zlib

W, H = 1920, 1080
mode = sys.argv[1] if len(sys.argv) > 1 else "tokyo-dark"
out  = sys.argv[2] if len(sys.argv) > 2 else "wallpaper.png"

THEMES = {
    "tokyo-dark": {
        "top": (11, 12, 22), "bottom": (26, 27, 38),
        "glows": [
            (0.18 * W, 0.92 * H, 0.75 * W, (122, 162, 247), 0.42),
            (0.88 * W, 0.08 * H, 0.60 * W, (187, 154, 247), 0.34),
            (0.55 * W, 0.55 * H, 0.35 * W, (125, 207, 255), 0.06),
        ],
        "dot": (122, 162, 247), "dotk": 0.18
    },
    "tokyo-light": {
        "top": (238, 240, 248), "bottom": (214, 219, 236),
        "glows": [
            (0.18 * W, 0.92 * H, 0.75 * W, (46, 125, 233), 0.20),
            (0.88 * W, 0.08 * H, 0.60 * W, (152, 84, 241), 0.16),
            (0.55 * W, 0.55 * H, 0.35 * W, (0, 113, 151), 0.03),
        ],
        "dot": (46, 125, 233), "dotk": 0.14
    },
    "matcha-dark": {
        "top": (20, 30, 24), "bottom": (32, 46, 37),
        "glows": [
            (0.20 * W, 0.85 * H, 0.75 * W, (163, 217, 165), 0.36),
            (0.85 * W, 0.15 * H, 0.65 * W, (216, 243, 220), 0.24),
            (0.50 * W, 0.50 * H, 0.40 * W, (233, 237, 201), 0.08),
        ],
        "dot": (163, 217, 165), "dotk": 0.18
    },
    "matcha-light": {
        "top": (241, 248, 243), "bottom": (222, 238, 227),
        "glows": [
            (0.20 * W, 0.85 * H, 0.75 * W, (82, 183, 136), 0.20),
            (0.85 * W, 0.15 * H, 0.65 * W, (116, 198, 157), 0.16),
            (0.50 * W, 0.50 * H, 0.40 * W, (64, 145, 108), 0.04),
        ],
        "dot": (64, 145, 108), "dotk": 0.14
    },
    "sunset-dark": {
        "top": (40, 16, 10), "bottom": (82, 33, 15),
        "glows": [
            (0.15 * W, 0.90 * H, 0.80 * W, (255, 138, 61), 0.45),
            (0.88 * W, 0.12 * H, 0.65 * W, (255, 183, 3), 0.32),
            (0.52 * W, 0.48 * H, 0.45 * W, (251, 86, 7), 0.12),
        ],
        "dot": (255, 183, 3), "dotk": 0.16
    },
    "sunset-light": {
        "top": (255, 246, 238), "bottom": (252, 230, 212),
        "glows": [
            (0.15 * W, 0.90 * H, 0.80 * W, (247, 127, 0), 0.22),
            (0.88 * W, 0.12 * H, 0.65 * W, (252, 163, 17), 0.18),
            (0.52 * W, 0.48 * H, 0.45 * W, (214, 40, 40), 0.04),
        ],
        "dot": (230, 92, 0), "dotk": 0.14
    },
    "nordic-dark": {
        "top": (24, 29, 38), "bottom": (36, 44, 56),
        "glows": [
            (0.20 * W, 0.88 * H, 0.75 * W, (136, 192, 208), 0.38),
            (0.85 * W, 0.12 * H, 0.60 * W, (129, 161, 193), 0.30),
            (0.50 * W, 0.50 * H, 0.35 * W, (143, 188, 187), 0.08),
        ],
        "dot": (136, 192, 208), "dotk": 0.16
    },
    "nordic-light": {
        "top": (236, 239, 244), "bottom": (216, 222, 233),
        "glows": [
            (0.20 * W, 0.88 * H, 0.75 * W, (94, 129, 172), 0.20),
            (0.85 * W, 0.12 * H, 0.60 * W, (129, 161, 193), 0.16),
            (0.50 * W, 0.50 * H, 0.35 * W, (136, 192, 208), 0.04),
        ],
        "dot": (94, 129, 172), "dotk": 0.14
    },
    "rose-dark": {
        "top": (32, 18, 28), "bottom": (52, 28, 44),
        "glows": [
            (0.18 * W, 0.90 * H, 0.75 * W, (244, 143, 177), 0.38),
            (0.86 * W, 0.10 * H, 0.62 * W, (206, 147, 216), 0.32),
            (0.52 * W, 0.52 * H, 0.38 * W, (255, 204, 188), 0.08),
        ],
        "dot": (244, 143, 177), "dotk": 0.17
    },
    "rose-light": {
        "top": (253, 242, 246), "bottom": (246, 224, 234),
        "glows": [
            (0.18 * W, 0.90 * H, 0.75 * W, (216, 27, 96), 0.18),
            (0.86 * W, 0.10 * H, 0.62 * W, (142, 36, 170), 0.14),
            (0.52 * W, 0.52 * H, 0.38 * W, (236, 64, 122), 0.04),
        ],
        "dot": (194, 24, 91), "dotk": 0.14
    },
}

cfg = THEMES.get(mode, THEMES["tokyo-dark"])
top, bottom = cfg["top"], cfg["bottom"]
glows = cfg["glows"]
GRID, DOT, DOTK = 44, cfg["dot"], cfg["dotk"]

rows = bytearray()
for y in range(H):
    t = y / (H - 1)
    br, bg, bb = (top[i] + (bottom[i] - top[i]) * t for i in range(3))
    rows.append(0)
    gy = (y % GRID) == GRID // 2
    for x in range(W):
        r, g, b = br, bg, bb
        for cx, cy, rad, (gr, gg, gb), s in glows:
            d = math.hypot(x - cx, y - cy) / rad
            if d < 1.0:
                k = s * (1.0 - d) ** 2.2
                r += (gr - r) * k; g += (gg - g) * k; b += (gb - b) * k
        if gy and (x % GRID) == GRID // 2:
            r += (DOT[0] - r) * DOTK; g += (DOT[1] - g) * DOTK; b += (DOT[2] - b) * DOTK
        n = ((x * 7 + y * 13) % 5 - 2) * 0.35
        rows += bytes((min(255, max(0, int(r + n))), min(255, max(0, int(g + n))), min(255, max(0, int(b + n)))))

def chunk(tag, data):
    c = tag + data
    return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)

png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)) \
      + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b"")
with open(out, "wb") as f:
    f.write(png)
PY

  for tname in tokyo-dark tokyo-light matcha-dark matcha-light sunset-dark sunset-light nordic-dark nordic-light rose-dark rose-light; do
    arch-chroot /mnt python3 /root/gen-wallpaper.py "$tname" "$WALLPAPER_DIR/$tname.png"
  done
  rm -f /mnt/root/gen-wallpaper.py

  # ---- Login screen: greetd + tuigreet ---------------------------------------
  mkdir -p /mnt/etc/greetd
  cat > /mnt/etc/greetd/config.toml <<'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --asterisks --greeting 'TILE // welcome back' --theme 'border=magenta;text=cyan;prompt=green;time=blue;action=blue;button=magenta;container=black;input=white' --cmd start-hyprland"
user = "greeter"
EOF
  if [[ -f /mnt/etc/pam.d/greetd ]] && ! grep -q pam_gnome_keyring /mnt/etc/pam.d/greetd; then
    cat >> /mnt/etc/pam.d/greetd <<'EOF'
auth       optional     pam_gnome_keyring.so
session    optional     pam_gnome_keyring.so auto_start
password   optional     pam_gnome_keyring.so
EOF
  fi

  # ---- Helper scripts --------------------------------------------------------
  cat > /mnt/usr/local/bin/tile-powermenu <<'EOF'
#!/bin/bash
choice=$(printf '%s\n' "Lock" "Logout" "Suspend" "Reboot" "Shutdown" \
  | fuzzel --dmenu --prompt "Power ❯ " --lines 5 --width 22)
case "$choice" in
  Lock)     loginctl lock-session ;;
  Logout)   hyprctl dispatch exit ;;
  Suspend)  systemctl suspend ;;
  Reboot)   systemctl reboot ;;
  Shutdown) systemctl poweroff ;;
esac
EOF

  cat > /mnt/usr/local/bin/tile-screenshot <<'EOF'
#!/bin/bash
dir="$(xdg-user-dir PICTURES 2>/dev/null || echo "$HOME/Pictures")/Screenshots"
mkdir -p "$dir"
file="$dir/$(date +%Y-%m-%d_%H-%M-%S).png"
if [[ "$1" == area ]]; then
  geo=$(slurp) || exit 0
  grim -g "$geo" "$file"
else
  grim "$file"
fi
wl-copy < "$file"
notify-send -i "$file" "Screenshot saved" "Copied to clipboard"
EOF

  cat > /mnt/usr/local/bin/tile-clipboard <<'EOF'
#!/bin/bash
command -v cliphist >/dev/null || { notify-send "Clipboard history" "cliphist is not installed"; exit 0; }
cliphist list | fuzzel --dmenu --prompt "Clipboard ❯ " --width 60 | cliphist decode | wl-copy
EOF

  cat > /mnt/usr/local/bin/tile-keybinds <<'EOF'
#!/bin/bash
fuzzel --dmenu --prompt "Shortcuts ❯ " --width 58 --lines 25 < /usr/local/share/tile/keybinds.txt >/dev/null
EOF

  cat > /mnt/usr/local/bin/tile-welcome <<'EOF'
#!/bin/bash
mark="${XDG_CONFIG_HOME:-$HOME/.config}/.tile-welcome-done"
[[ -f "$mark" ]] && exit 0
sleep 3
notify-send -t 15000 "Welcome to Tile" "Tap SUPER for apps  ·  SUPER + Enter for a terminal\nSUPER + T opens the theme menu  ·  SUPER + Shift + T toggles Dark/Light"
touch "$mark"
EOF

  cat > /mnt/usr/local/bin/tile-theme <<'EOF'
#!/bin/bash
# tile-theme [menu|toggle|init|icon|<theme-name>]
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE="$CFG/tile/theme"
cur=$(cat "$STATE" 2>/dev/null)
[[ -f "$CFG/waybar/themes/$cur.css" ]] || cur="tokyo-dark"

THEMES=(
  "tokyo-dark|Tokyo Night — Dark"
  "tokyo-light|Tokyo Night — Light"
  "matcha-dark|Matcha Pastel — Dark"
  "matcha-light|Matcha Pastel — Light"
  "sunset-dark|Sunset Ember — Dark"
  "sunset-light|Sunset Ember — Light"
  "nordic-dark|Nordic Frost — Dark"
  "nordic-light|Nordic Frost — Light"
  "rose-dark|Rose Quartz — Dark"
  "rose-light|Rose Quartz — Light"
)

border_colors() {
  case "$1" in
    tokyo-dark)   echo "rgba(7aa2f7ee) rgba(bb9af7ee) 45deg|rgba(414868aa)" ;;
    tokyo-light)  echo "rgba(2e7de9ee) rgba(9854f1ee) 45deg|rgba(a8aecbaa)" ;;
    matcha-dark)  echo "rgba(a3d9a5ee) rgba(d8f3dcee) 45deg|rgba(3d5245aa)" ;;
    matcha-light) echo "rgba(40916cee) rgba(74c69dee) 45deg|rgba(b7e4c7aa)" ;;
    sunset-dark)  echo "rgba(ff8a3dee) rgba(ffb703ee) 45deg|rgba(5c2c16aa)" ;;
    sunset-light) echo "rgba(e65c00ee) rgba(fca311ee) 45deg|rgba(f4a261aa)" ;;
    nordic-dark)  echo "rgba(88c0d0ee) rgba(81a1c1ee) 45deg|rgba(3b4252aa)" ;;
    nordic-light) echo "rgba(5e81acee) rgba(81a1c1ee) 45deg|rgba(d8dee9aa)" ;;
    rose-dark)    echo "rgba(f48fb1ee) rgba(ce93d8ee) 45deg|rgba(4a2c40aa)" ;;
    rose-light)   echo "rgba(d81b60ee) rgba(8e24aaee) 45deg|rgba(f8bbd0aa)" ;;
    *)            echo "rgba(7aa2f7ee) rgba(bb9af7ee) 45deg|rgba(414868aa)" ;;
  esac
}

case "${1:-menu}" in
  icon)
    [[ "$cur" == *-light ]] && echo "󰖙" || echo "󰏘"
    exit 0
    ;;
  menu)
    labels=""
    for entry in "${THEMES[@]}"; do
      id="${entry%%|*}"
      name="${entry#*|}"
      [[ "$id" == "$cur" ]] && labels+="● $name\n" || labels+="  $name\n"
    done
    picked=$(printf '%b' "$labels" | fuzzel --dmenu --prompt "Theme ❯ " --lines 10 --width 30)
    [[ -z "$picked" ]] && exit 0
    picked="${picked#● }"
    picked="${picked#  }"
    new=""
    for entry in "${THEMES[@]}"; do
      if [[ "${entry#*|}" == "$picked" ]]; then
        new="${entry%%|*}"
        break
      fi
    done
    [[ -z "$new" ]] && exit 0
    ;;
  toggle)
    family="${cur%-*}"
    if [[ "$cur" == *-dark ]]; then
      new="${family}-light"
    else
      new="${family}-dark"
    fi
    ;;
  init)
    new="$cur"
    ;;
  *)
    if [[ -f "$CFG/waybar/themes/$1.css" ]]; then
      new="$1"
    else
      echo "usage: tile-theme [menu|toggle|init|<family>-<dark|light>]"
      exit 1
    fi
    ;;
esac

mkdir -p "$CFG/tile"
echo "$new" > "$STATE"

ln -sfn "themes/$new.css"  "$CFG/waybar/style.css"
ln -sfn "themes/$new.conf" "$CFG/kitty/theme.conf"
ln -sfn "themes/$new.ini"  "$CFG/fuzzel/fuzzel.ini"
ln -sfn "themes/$new"      "$CFG/mako/config"

if [[ "$new" == *-light ]]; then
  scheme=prefer-light; gtk=Adwaita;      icons=Papirus-Light; preferdark=0
else
  scheme=prefer-dark;  gtk=Adwaita-dark; icons=Papirus-Dark;  preferdark=1
fi
gsettings set org.gnome.desktop.interface color-scheme "$scheme"
gsettings set org.gnome.desktop.interface gtk-theme "$gtk"
gsettings set org.gnome.desktop.interface icon-theme "$icons"
for v in 3.0 4.0; do
  f="$CFG/gtk-$v/settings.ini"
  [[ -f "$f" ]] && sed -i -e "s/^gtk-application-prefer-dark-theme=.*/gtk-application-prefer-dark-theme=$preferdark/" \
                          -e "s/^gtk-theme-name=.*/gtk-theme-name=$gtk/" \
                          -e "s/^gtk-icon-theme-name=.*/gtk-icon-theme-name=$icons/" "$f"
done

bcols=$(border_colors "$new")
active_col="${bcols%%|*}"
inactive_col="${bcols#*|}"
hyprctl keyword general:col.active_border "$active_col" >/dev/null 2>&1 || true
hyprctl keyword general:col.inactive_border "$inactive_col" >/dev/null 2>&1 || true

pkill -x swaybg
setsid -f swaybg -i "/usr/share/backgrounds/tile/$new.png" -m fill >/dev/null 2>&1

[[ "$1" == "init" ]] && exit 0

pkill -SIGUSR2 -x waybar
pkill -SIGUSR1 -x kitty
makoctl reload 2>/dev/null
if pgrep -x nm-applet >/dev/null; then
  pkill -x nm-applet; setsid -f nm-applet --indicator >/dev/null 2>&1
fi
if pgrep -f blueman-applet >/dev/null; then
  pkill -f blueman-applet; setsid -f blueman-applet >/dev/null 2>&1
fi
notify-send -t 2000 "Tile Theme" "Switched to $new"
EOF
  chmod 755 /mnt/usr/local/bin/tile-*

  cat > /mnt/usr/local/share/tile/keybinds.txt <<'EOF'
SUPER (tap)          App launcher
SUPER + Space        App launcher
SUPER + Enter        Terminal (kitty)
SUPER + B            Browser (Firefox)
SUPER + E            Files (Thunar)
SUPER + Q            Close window
SUPER + F            Fullscreen
SUPER + V            Float / unfloat window
SUPER + J            Flip split direction
SUPER + Arrows       Move focus
SUPER + Shift+Arrows Move window
SUPER + 1..0         Go to workspace 1-10
SUPER + Shift+1..0   Send window to workspace
SUPER + Scroll       Next / previous workspace
SUPER + Mouse drag   Move window (right button: resize)
SUPER + S            Scratchpad (hidden workspace)
SUPER + C            Clipboard history
SUPER + T            Theme selector menu
SUPER + Shift + T    Toggle Dark / Light for current theme
Ctrl + Shift + Esc   System monitor (Mission Center)
SUPER + L            Lock screen
SUPER + Escape       Power menu
Print                Screenshot of an area
Shift + Print        Screenshot of the whole screen
SUPER + Shift + S    Screenshot of an area
3-finger swipe       Switch workspace (touchpad)
SUPER + F1           This cheat sheet
EOF

  # ---- Hyprland (Lua config, Hyprland 0.57+) -------------------------------
  cat > "$S/hypr/hyprland.lua" <<'EOF'
-- ~/.config/hypr/hyprland.lua — Tile desktop

local terminal    = "kitty"
local fileManager = "thunar"
local browser     = "firefox"
local menu        = "pkill fuzzel || fuzzel"
local mainMod     = "SUPER"

local function read_theme()
    local ok, t = pcall(function()
        local f = io.open(os.getenv("HOME") .. "/.config/tile/theme", "r")
        if not f then return "tokyo-dark" end
        local v = f:read("*l")
        f:close()
        return v
    end)
    if ok and t then return t end
    return "tokyo-dark"
end

local palettes = {
    ["tokyo-dark"] = {
        active   = { colors = {"rgba(7aa2f7ee)", "rgba(bb9af7ee)"}, angle = 45 },
        inactive = "rgba(414868aa)",
        shadow   = 0xee0b0c12,
    },
    ["tokyo-light"] = {
        active   = { colors = {"rgba(2e7de9ee)", "rgba(9854f1ee)"}, angle = 45 },
        inactive = "rgba(a8aecbaa)",
        shadow   = 0x44000000,
    },
    ["matcha-dark"] = {
        active   = { colors = {"rgba(a3d9a5ee)", "rgba(d8f3dcee)"}, angle = 45 },
        inactive = "rgba(3d5245aa)",
        shadow   = 0xee0f1712,
    },
    ["matcha-light"] = {
        active   = { colors = {"rgba(40916cee)", "rgba(74c69dee)"}, angle = 45 },
        inactive = "rgba(b7e4c7aa)",
        shadow   = 0x44000000,
    },
    ["sunset-dark"] = {
        active   = { colors = {"rgba(ff8a3dee)", "rgba(ffb703ee)"}, angle = 45 },
        inactive = "rgba(5c2c16aa)",
        shadow   = 0xee1c0a04,
    },
    ["sunset-light"] = {
        active   = { colors = {"rgba(e65c00ee)", "rgba(fca311ee)"}, angle = 45 },
        inactive = "rgba(f4a261aa)",
        shadow   = 0x44000000,
    },
    ["nordic-dark"] = {
        active   = { colors = {"rgba(88c0d0ee)", "rgba(81a1c1ee)"}, angle = 45 },
        inactive = "rgba(3b4252aa)",
        shadow   = 0xee12161f,
    },
    ["nordic-light"] = {
        active   = { colors = {"rgba(5e81acee)", "rgba(81a1c1ee)"}, angle = 45 },
        inactive = "rgba(d8dee9aa)",
        shadow   = 0x44000000,
    },
    ["rose-dark"] = {
        active   = { colors = {"rgba(f48fb1ee)", "rgba(ce93d8ee)"}, angle = 45 },
        inactive = "rgba(4a2c40aa)",
        shadow   = 0xee170c14,
    },
    ["rose-light"] = {
        active   = { colors = {"rgba(d81b60ee)", "rgba(8e24aaee)"}, angle = 45 },
        inactive = "rgba(f8bbd0aa)",
        shadow   = 0x44000000,
    },
}

local theme = palettes[read_theme()] or palettes["tokyo-dark"]

hl.monitor({
    output   = "",
    mode     = "preferred",
    position = "auto",
    scale    = "1",
})

hl.env("XCURSOR_THEME", "Adwaita")
hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
hl.env("QT_QPA_PLATFORM", "wayland;xcb")
hl.env("ELECTRON_OZONE_PLATFORM_HINT", "auto")
hl.env("XDG_DATA_DIRS", (os.getenv("HOME") or "") .. "/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share")

hl.on("hyprland.start", function()
    hl.exec_cmd("tile-theme init")
    hl.exec_cmd("waybar")
    hl.exec_cmd("mako")
    hl.exec_cmd("hypridle")
    hl.exec_cmd("systemctl --user start hyprpolkitagent")
    hl.exec_cmd("nm-applet --indicator")
    hl.exec_cmd("blueman-applet")
    hl.exec_cmd("wl-paste --type text --watch cliphist store")
    hl.exec_cmd("wl-paste --type image --watch cliphist store")
    hl.exec_cmd("tile-welcome")
end)

hl.on("hyprland.reload", function()
    hl.exec_cmd("tile-theme init")
end)

hl.config({
    general = {
        gaps_in  = 5,
        gaps_out = 12,
        border_size = 2,
        col = {
            active_border   = theme.active,
            inactive_border = theme.inactive,
        },
        resize_on_border = true,
        allow_tearing    = false,
        layout = "dwindle",
    },

    decoration = {
        rounding       = 12,
        rounding_power = 2,
        active_opacity   = 1.0,
        inactive_opacity = 0.95,
        shadow = {
            enabled      = true,
            range        = 12,
            render_power = 3,
            color        = theme.shadow,
        },
        blur = {
            enabled  = true,
            size     = 6,
            passes   = 2,
            vibrancy = 0.1696,
        },
    },

    animations = {
        enabled = true,
    },

    dwindle = {
        preserve_split = true,
    },

    misc = {
        force_default_wallpaper  = 0,
        disable_hyprland_logo    = true,
        disable_splash_rendering = true,
    },

    input = {
        kb_layout = "se",
        numlock_by_default = true,
        follow_mouse = 1,
        sensitivity  = 0,
        touchpad = {
            natural_scroll = true,
        },
    },
})

hl.curve("easeOutQuint",   { type = "bezier", points = { {0.23, 1},    {0.32, 1}    } })
hl.curve("easeInOutCubic", { type = "bezier", points = { {0.65, 0.05}, {0.36, 1}    } })
hl.curve("linear",         { type = "bezier", points = { {0, 0},       {1, 1}       } })
hl.curve("almostLinear",   { type = "bezier", points = { {0.5, 0.5},   {0.75, 1}    } })
hl.curve("quick",          { type = "bezier", points = { {0.15, 0},    {0.1, 1}     } })
hl.curve("easy",           { type = "spring", mass = 1, stiffness = 238.1191, damping = 24.21279333 })

hl.animation({ leaf = "global",        enabled = true,  speed = 10,   bezier = "default" })
hl.animation({ leaf = "border",        enabled = true,  speed = 5.39, bezier = "easeOutQuint" })
hl.animation({ leaf = "windows",       enabled = true,  speed = 4.79, spring = "easy" })
hl.animation({ leaf = "windowsIn",     enabled = true,  speed = 4.1,  spring = "easy",         style = "popin 87%" })
hl.animation({ leaf = "windowsOut",    enabled = true,  speed = 1.49, bezier = "linear",       style = "popin 87%" })
hl.animation({ leaf = "fadeIn",        enabled = true,  speed = 1.73, bezier = "almostLinear" })
hl.animation({ leaf = "fadeOut",       enabled = true,  speed = 1.46, bezier = "almostLinear" })
hl.animation({ leaf = "fade",          enabled = true,  speed = 3.03, bezier = "quick" })
hl.animation({ leaf = "layers",        enabled = true,  speed = 3.81, bezier = "easeOutQuint" })
hl.animation({ leaf = "layersIn",      enabled = true,  speed = 4,    bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "layersOut",     enabled = true,  speed = 1.5,  bezier = "linear",       style = "fade" })
hl.animation({ leaf = "fadeLayersIn",  enabled = true,  speed = 1.79, bezier = "almostLinear" })
hl.animation({ leaf = "fadeLayersOut", enabled = true,  speed = 1.39, bezier = "almostLinear" })
hl.animation({ leaf = "workspaces",    enabled = true,  speed = 1.94, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "workspacesIn",  enabled = true,  speed = 1.21, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "workspacesOut", enabled = true,  speed = 1.94, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "zoomFactor",    enabled = true,  speed = 7,    bezier = "quick" })

hl.gesture({
    fingers   = 3,
    direction = "horizontal",
    action    = "workspace",
})

-- Apps
hl.bind("Super_L", hl.dsp.exec_cmd(menu), { release = true })
hl.bind(mainMod .. " + Space",     hl.dsp.exec_cmd(menu))
hl.bind(mainMod .. " + Return",    hl.dsp.exec_cmd(terminal))
hl.bind(mainMod .. " + B",         hl.dsp.exec_cmd(browser))
hl.bind(mainMod .. " + E",         hl.dsp.exec_cmd(fileManager))
hl.bind(mainMod .. " + C",         hl.dsp.exec_cmd("tile-clipboard"))
hl.bind(mainMod .. " + T",         hl.dsp.exec_cmd("tile-theme menu"))
hl.bind(mainMod .. " + SHIFT + T", hl.dsp.exec_cmd("tile-theme toggle"))
hl.bind("CTRL + SHIFT + Escape",   hl.dsp.exec_cmd("flatpak run io.missioncenter.MissionCenter"))
hl.bind(mainMod .. " + F1",        hl.dsp.exec_cmd("tile-keybinds"))
hl.bind(mainMod .. " + L",         hl.dsp.exec_cmd("loginctl lock-session"))
hl.bind(mainMod .. " + Escape",    hl.dsp.exec_cmd("tile-powermenu"))

-- Windows
hl.bind(mainMod .. " + Q", hl.dsp.window.close())
hl.bind(mainMod .. " + F", hl.dsp.window.fullscreen())
hl.bind(mainMod .. " + V", hl.dsp.window.float({ action = "toggle" }))
hl.bind(mainMod .. " + P", hl.dsp.window.pseudo())
hl.bind(mainMod .. " + J", hl.dsp.layout("togglesplit"))

-- Focus / move
for _, dir in ipairs({ "left", "right", "up", "down" }) do
    hl.bind(mainMod .. " + " .. dir,           hl.dsp.focus({ direction = dir }))
    hl.bind(mainMod .. " + SHIFT + " .. dir,   hl.dsp.window.move({ direction = dir }))
end

-- Workspaces 1-10
for i = 1, 10 do
    local key = i % 10
    hl.bind(mainMod .. " + " .. key,         hl.dsp.focus({ workspace = i }))
    hl.bind(mainMod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
end

-- Scratchpad
hl.bind(mainMod .. " + S",         hl.dsp.workspace.toggle_special("magic"))
hl.bind(mainMod .. " + SHIFT + S", hl.dsp.exec_cmd("tile-screenshot area"))

-- Mouse
hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }))
hl.bind(mainMod .. " + mouse:272",  hl.dsp.window.drag(),   { mouse = true })
hl.bind(mainMod .. " + mouse:273",  hl.dsp.window.resize(), { mouse = true })

-- Screenshots
hl.bind("Print",         hl.dsp.exec_cmd("tile-screenshot area"))
hl.bind("SHIFT + Print", hl.dsp.exec_cmd("tile-screenshot screen"))

-- Media & Hardware keys
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),      { locked = true, repeating = true })
hl.bind("XF86AudioMute",        hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),     { locked = true })
hl.bind("XF86AudioMicMute",     hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"),   { locked = true })
hl.bind("XF86MonBrightnessUp",  hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%+"),                  { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown",hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%-"),                  { locked = true, repeating = true })
hl.bind("XF86AudioNext",  hl.dsp.exec_cmd("playerctl next"),       { locked = true })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPlay",  hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPrev",  hl.dsp.exec_cmd("playerctl previous"),   { locked = true })

-- Window rules
hl.window_rule({
    name  = "suppress-maximize-events",
    match = { class = ".*" },
    suppress_event = "maximize",
})

hl.window_rule({
    name  = "fix-xwayland-drags",
    match = {
        class      = "^$",
        title      = "^$",
        xwayland   = true,
        float      = true,
        fullscreen = false,
        pin        = false,
    },
    no_focus = true,
})

hl.window_rule({
    name  = "float-settings-tools",
    match = { class = "^(org.pulseaudio.pavucontrol|pavucontrol|blueman-manager|nm-connection-editor)$" },
    float = true,
})
EOF

  # ---- Lock screen (hyprlock) ------------------------------------------------
  cat > "$S/hypr/hyprlock.conf" <<'EOF'
$font = JetBrainsMono Nerd Font

general {
    hide_cursor = true
}

animations {
    enabled = true
    bezier = linear, 1, 1, 0, 0
    animation = fadeIn, 1, 5, linear
    animation = fadeOut, 1, 5, linear
    animation = inputFieldDots, 1, 2, linear
}

background {
    monitor =
    path = screenshot
    blur_passes = 3
    brightness = 0.6
}

input-field {
    monitor =
    size = 20%, 5%
    outline_thickness = 3
    inner_color = rgba(26, 27, 38, 0.6)
    outer_color = rgba(7aa2f7ee) rgba(bb9af7ee) 45deg
    check_color = rgba(9ece6aee) rgba(7dcfffee) 120deg
    fail_color = rgba(f7768eee) rgba(ff007cee) 40deg
    font_color = rgb(192, 202, 245)
    fade_on_empty = false
    rounding = 15
    font_family = $font
    placeholder_text = Password...
    fail_text = $PAMFAIL
    dots_spacing = 0.3
    position = 0, -40
    halign = center
    valign = center
}

label {
    monitor =
    text = $TIME
    color = rgba(192, 202, 245, 1.0)
    font_size = 96
    font_family = $font
    position = 0, 160
    halign = center
    valign = center
}

label {
    monitor =
    text = cmd[update:60000] date +"%A %d %B"
    color = rgba(169, 177, 214, 1.0)
    font_size = 22
    font_family = $font
    position = 0, 70
    halign = center
    valign = center
}
EOF

  # ---- Idle (hypridle) -------------------------------------------------------
  {
    cat <<'EOF'
general {
    lock_cmd = pidof hyprlock || hyprlock
    before_sleep_cmd = loginctl lock-session
    after_sleep_cmd = hyprctl dispatch dpms on
}
EOF
    if [[ "$IS_LAPTOP" == "yes" ]]; then
      cat <<'EOF'

listener {
    timeout = 150
    on-timeout = brightnessctl -s set 10
    on-resume = brightnessctl -r
}
EOF
    fi
    cat <<'EOF'

listener {
    timeout = 300
    on-timeout = loginctl lock-session
}

listener {
    timeout = 330
    on-timeout = hyprctl dispatch dpms off
    on-resume = hyprctl dispatch dpms on
}
EOF
    if [[ "$IS_LAPTOP" == "yes" ]]; then
      cat <<'EOF'

listener {
    timeout = 1800
    on-timeout = systemctl suspend
}
EOF
    fi
  } > "$S/hypr/hypridle.conf"

  # ---- Top bar (Waybar with live network traffic) ----------------------------
  local right='"tray", "pulseaudio", "network", "custom/theme", "custom/power"'
  [[ "$IS_LAPTOP" == "yes" ]] && right='"tray", "power-profiles-daemon", "pulseaudio", "network", "battery", "custom/theme", "custom/power"'
  cat > "$S/waybar/config.jsonc" <<EOF
{
    "layer": "top",
    "position": "top",
    "height": 34,
    "margin-top": 8,
    "margin-left": 12,
    "margin-right": 12,
    "spacing": 8,

    "modules-left": ["custom/launcher", "hyprland/workspaces"],
    "modules-center": ["clock"],
    "modules-right": [$right],

    "custom/launcher": {
        "format": "",
        "on-click": "pkill fuzzel || fuzzel",
        "tooltip": false
    },
    "hyprland/workspaces": {
        "format": "{id}",
        "on-click": "activate",
        "persistent-workspaces": { "*": 5 }
    },
    "clock": {
        "format": "{:%H:%M}",
        "format-alt": "{:%A %d %B  %H:%M}",
        "tooltip-format": "<tt>{calendar}</tt>"
    },
    "pulseaudio": {
        "format": "{icon} {volume}%",
        "format-muted": "󰖁 muted",
        "format-icons": { "default": ["", "", ""] },
        "scroll-step": 5,
        "on-click": "pavucontrol",
        "on-click-right": "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
    },
    "network": {
        "interval": 2,
        "format-wifi": "  {essid}  ↓{bandwidthDownBytes} ↑{bandwidthUpBytes}",
        "format-ethernet": "󰈀 wired  ↓{bandwidthDownBytes} ↑{bandwidthUpBytes}",
        "format-disconnected": "󰖪 offline",
        "tooltip-format": "{ifname}  {ipaddr}\nDown: {bandwidthDownBits}  Up: {bandwidthUpBits}",
        "on-click": "nm-connection-editor"
    },
    "battery": {
        "states": { "warning": 25, "critical": 10 },
        "format": "{icon} {capacity}%",
        "format-charging": "󰂄 {capacity}%",
        "format-icons": ["󰁺", "󰁼", "󰁾", "󰂀", "󰁹"]
    },
    "power-profiles-daemon": {
        "format": "{icon}",
        "tooltip-format": "Power profile: {profile}",
        "format-icons": {
            "default": "󰗑",
            "performance": "󰓅",
            "balanced": "󰗑",
            "power-saver": "󰌪"
        }
    },
    "tray": { "spacing": 10, "icon-size": 16 },
    "custom/theme": {
        "exec": "tile-theme icon",
        "interval": 2,
        "on-click": "tile-theme menu",
        "on-click-right": "tile-theme toggle",
        "tooltip": true,
        "tooltip-format": "Left-click: Theme menu (SUPER+T)\nRight-click: Dark/Light (SUPER+Shift+T)"
    },
    "custom/power": {
        "format": "",
        "on-click": "tile-powermenu",
        "tooltip": false
    }
}
EOF

  # ---- 10 Complete Themes (5 Dark + 5 Light) ---------------------------------
  declare -A P_TOKYO_DARK=(   [bg]=1a1b26 [fg]=c0caf5 [muted]=565f89 [accent]=7aa2f7 [accent2]=bb9af7
                              [cyan]=7dcfff [green]=9ece6a [yellow]=e0af68 [red]=f7768e [sel]=33467c )
  declare -A P_TOKYO_LIGHT=(  [bg]=e1e2e7 [fg]=3760bf [muted]=8990b3 [accent]=2e7de9 [accent2]=9854f1
                              [cyan]=007197 [green]=587539 [yellow]=8c6c3e [red]=f52a65 [sel]=b7c1e3 )

  declare -A P_MATCHA_DARK=(  [bg]=1b2620 [fg]=e2f0e6 [muted]=6c8a76 [accent]=a3d9a5 [accent2]=d8f3dc
                              [cyan]=95d5b2 [green]=74c69d [yellow]=e9edc9 [red]=f28482 [sel]=2d4739 )
  declare -A P_MATCHA_LIGHT=( [bg]=f1f8f3 [fg]=1b4332 [muted]=74a88e [accent]=40916c [accent2]=52b788
                              [cyan]=2d6a4f [green]=2d6a4f [yellow]=8c6c3e [red]=d62828 [sel]=cde5d5 )

  declare -A P_SUNSET_DARK=(  [bg]=2b140d [fg]=ffedd8 [muted]=9c6644 [accent]=ff8a3d [accent2]=ffb703
                              [cyan]=ffd166 [green]=a7c957 [yellow]=ffb703 [red]=e63946 [sel]=5c2c16 )
  declare -A P_SUNSET_LIGHT=( [bg]=fff6ee [fg]=5c2c16 [muted]=b07d62 [accent]=e65c00 [accent2]=fca311
                              [cyan]=b54708 [green]=587539 [yellow]=b54708 [red]=d62828 [sel]=f9dcc4 )

  declare -A P_NORDIC_DARK=(  [bg]=1e242e [fg]=eceff4 [muted]=616e88 [accent]=88c0d0 [accent2]=81a1c1
                              [cyan]=8fbcbb [green]=a3be8c [yellow]=ebcb8b [red]=bf616a [sel]=3b4252 )
  declare -A P_NORDIC_LIGHT=( [bg]=eceff4 [fg]=2e3440 [muted]=7b88a1 [accent]=5e81ac [accent2]=81a1c1
                              [cyan]=4c566a [green]=6b8e4e [yellow]=b48ead [red]=bf616a [sel]=d8dee9 )

  declare -A P_ROSE_DARK=(    [bg]=24141f [fg]=fce4ec [muted]=8e627a [accent]=f48fb1 [accent2]=ce93d8
                              [cyan]=f8bbd0 [green]=a5d6a7 [yellow]=ffe082 [red]=ef5350 [sel]=4a2c40 )
  declare -A P_ROSE_LIGHT=(   [bg]=fdf2f6 [fg]=5c1a36 [muted]=a86480 [accent]=d81b60 [accent2]=8e24aa
                              [cyan]=ad1457 [green]=2e7d32 [yellow]=9c6f00 [red]=c62828 [sel]=f8bbd0 )

  write_theme() {
    local name="$1" icons="$3"
    local -n P="$2"

    cat > "$S/waybar/themes/$name.css" <<EOF
* {
    font-family: "JetBrainsMono Nerd Font Propo", "JetBrainsMono Nerd Font", "Noto Sans", sans-serif;
    font-size: 13px;
    border: none;
    min-height: 0;
}

window#waybar {
    background: transparent;
    color: #${P[fg]};
}

#custom-launcher, #workspaces, #clock, #tray, #pulseaudio, #network,
#battery, #power-profiles-daemon, #custom-theme, #custom-power {
    background: alpha(#${P[bg]}, 0.88);
    border: 1px solid alpha(#${P[accent]}, 0.32);
    border-radius: 12px;
    padding: 0 14px;
}

#custom-launcher { color: #${P[accent]}; font-size: 17px; padding: 0 15px 0 13px; }
#workspaces { padding: 0 6px; }
#workspaces button {
    color: #${P[muted]};
    padding: 0 8px;
    border-radius: 8px;
    background: transparent;
    box-shadow: none;
    text-shadow: none;
}
#workspaces button.active {
    color: #${P[bg]};
    background-image: linear-gradient(90deg, #${P[accent]}, #${P[accent2]});
}
#workspaces button:hover { background: alpha(#${P[accent]}, 0.22); color: #${P[fg]}; }
#clock { font-weight: bold; }
#network { color: #${P[cyan]}; }
#network.disconnected { color: #${P[red]}; }
#pulseaudio.muted { color: #${P[muted]}; }
#battery.charging { color: #${P[green]}; }
#battery.warning:not(.charging) { color: #${P[yellow]}; }
#battery.critical:not(.charging) { color: #${P[red]}; }

#power-profiles-daemon, #custom-theme, #custom-power { padding: 0 12px; min-width: 16px; }
#power-profiles-daemon.performance { color: #${P[red]}; }
#power-profiles-daemon.balanced    { color: #${P[accent]}; }
#power-profiles-daemon.power-saver { color: #${P[green]}; }
#custom-theme { color: #${P[accent2]}; }
#custom-power { color: #${P[red]}; }

tooltip {
    background: #${P[bg]};
    border: 1px solid #${P[accent]};
    border-radius: 10px;
}
tooltip label { color: #${P[fg]}; }
EOF

    cat > "$S/fuzzel/themes/$name.ini" <<EOF
[main]
font=JetBrainsMono Nerd Font:size=11
dpi-aware=no
icon-theme=$icons
terminal=kitty
prompt="❯ "
width=32
lines=10
horizontal-pad=16
vertical-pad=10
inner-pad=6
layer=overlay

[colors]
background=${P[bg]}f2
text=${P[fg]}ff
prompt=${P[accent]}ff
input=${P[fg]}ff
match=${P[accent2]}ff
selection=${P[sel]}ff
selection-text=${P[fg]}ff
selection-match=${P[cyan]}ff
border=${P[accent]}ff

[border]
width=2
radius=12
EOF

    cat > "$S/mako/themes/$name" <<EOF
font=JetBrainsMono Nerd Font 11
background-color=#${P[bg]}ee
text-color=#${P[fg]}
border-color=#${P[accent]}
border-size=2
border-radius=12
padding=12
margin=12
width=360
default-timeout=5000
icons=1
max-icon-size=48

[urgency=high]
border-color=#${P[red]}
default-timeout=0
EOF

    cat > "$S/kitty/themes/$name.conf" <<EOF
foreground #${P[fg]}
background #${P[bg]}
selection_foreground #${P[bg]}
selection_background #${P[accent]}
cursor #${P[fg]}
url_color #${P[cyan]}
color0  #${P[bg]}
color8  #${P[muted]}
color1  #${P[red]}
color9  #${P[red]}
color2  #${P[green]}
color10 #${P[green]}
color3  #${P[yellow]}
color11 #${P[yellow]}
color4  #${P[accent]}
color12 #${P[accent]}
color5  #${P[accent2]}
color13 #${P[accent2]}
color6  #${P[cyan]}
color14 #${P[cyan]}
color7  #${P[fg]}
color15 #${P[fg]}
EOF
  }

  write_theme tokyo-dark   P_TOKYO_DARK   Papirus-Dark
  write_theme tokyo-light  P_TOKYO_LIGHT  Papirus
  write_theme matcha-dark  P_MATCHA_DARK  Papirus-Dark
  write_theme matcha-light P_MATCHA_LIGHT Papirus
  write_theme sunset-dark  P_SUNSET_DARK  Papirus-Dark
  write_theme sunset-light P_SUNSET_LIGHT Papirus
  write_theme nordic-dark  P_NORDIC_DARK  Papirus-Dark
  write_theme nordic-light P_NORDIC_LIGHT Papirus
  write_theme rose-dark    P_ROSE_DARK    Papirus-Dark
  write_theme rose-light   P_ROSE_LIGHT   Papirus

  # ---- Terminal (kitty) ------------------------------------------------------
  cat > "$S/kitty/kitty.conf" <<'EOF'
font_family      JetBrainsMono Nerd Font
font_size        11.0
background_opacity 0.92
window_padding_width 12
confirm_os_window_close 0
enable_audio_bell no
cursor_shape beam

include theme.conf
EOF

  # Default active theme: tokyo-dark
  ln -sfn themes/tokyo-dark.css  "$S/waybar/style.css"
  ln -sfn themes/tokyo-dark.conf "$S/kitty/theme.conf"
  ln -sfn themes/tokyo-dark.ini  "$S/fuzzel/fuzzel.ini"
  ln -sfn themes/tokyo-dark      "$S/mako/config"
  echo "tokyo-dark" > "$S/tile/theme"

  # ---- Dark GTK theme + default apps -----------------------------------------
  for v in 3.0 4.0; do
    cat > "$S/gtk-$v/settings.ini" <<'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Papirus-Dark
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
gtk-font-name=Noto Sans 10
EOF
  done

  cat > "$S/mimeapps.list" <<'EOF'
[Default Applications]
x-scheme-handler/http=firefox.desktop
x-scheme-handler/https=firefox.desktop
text/html=firefox.desktop
application/pdf=firefox.desktop
inode/directory=thunar.desktop
EOF

  mkdir -p /mnt/etc/dconf/profile /mnt/etc/dconf/db/local.d
  printf 'user-db:user\nsystem-db:local\n' > /mnt/etc/dconf/profile/user
  cat > /mnt/etc/dconf/db/local.d/00-tile <<'EOF'
[org/gnome/desktop/interface]
color-scheme='prefer-dark'
gtk-theme='Adwaita-dark'
icon-theme='Papirus-Dark'
cursor-theme='Adwaita'
cursor-size=24
font-name='Noto Sans 10'
monospace-font-name='JetBrainsMono Nerd Font 11'
EOF
  arch-chroot /mnt dconf update
}

do_configure() {
  declare -p USERNAME FULLNAME HOSTNAME TIMEZONE LANG_LOCALE FORMAT_LOCALE \
             KERNEL_PARAMS CRYPT_UUID SERVICES BOOT_TIMEOUT MKINIT_HOOKS \
             > /mnt/root/install.env

  cat > /mnt/root/setup.sh <<'CHROOT'
set -euo pipefail
source /root/install.env

# Time & locale
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
for loc in "$LANG_LOCALE" "$FORMAT_LOCALE"; do
  sed -i "s/^#\(${loc} UTF-8\)/\1/" /etc/locale.gen
done
locale-gen
cat > /etc/locale.conf <<EOF
LANG=$LANG_LOCALE
LC_TIME=$FORMAT_LOCALE
LC_NUMERIC=$FORMAT_LOCALE
LC_MONETARY=$FORMAT_LOCALE
LC_PAPER=$FORMAT_LOCALE
LC_MEASUREMENT=$FORMAT_LOCALE
LC_ADDRESS=$FORMAT_LOCALE
LC_TELEPHONE=$FORMAT_LOCALE
LC_NAME=$FORMAT_LOCALE
EOF

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# Initramfs
sed -Ei "s/^HOOKS=.*/HOOKS=($MKINIT_HOOKS)/" /etc/mkinitcpio.conf
mkinitcpio -P

# systemd-boot
bootctl install
cat > /boot/loader/loader.conf <<EOF
default arch.conf
timeout $BOOT_TIMEOUT
console-mode max
editor no
EOF
OPTIONS="rd.luks.name=$CRYPT_UUID=cryptroot rd.luks.options=discard root=/dev/mapper/cryptroot rootflags=subvol=@ rw $KERNEL_PARAMS"
cat > /boot/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options $OPTIONS
EOF
if [[ -f /boot/initramfs-linux-fallback.img ]]; then
cat > /boot/loader/entries/arch-fallback.conf <<EOF
title   Arch Linux (fallback)
linux   /vmlinuz-linux
initrd  /initramfs-linux-fallback.img
options $OPTIONS
EOF
fi

# zram swap
cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
EOF

# User + sudo
useradd -m -G wheel,video,input -c "$FULLNAME" -s /bin/bash "$USERNAME"
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
passwd -l root

# Pacman tweaks + multilib
sed -Ei 's/^#?ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
pacman -Sy --noconfirm

# Firewall
sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/;
        s/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/' /etc/default/ufw
sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf

# Services
for s in "${SERVICES[@]}"; do
  systemctl enable "$s" || echo "WARNING: could not enable $s"
done
CHROOT

  arch-chroot /mnt bash /root/setup.sh
}

do_user() {
  printf '%s:%s\n' "$USERNAME" "$USER_PASS" | arch-chroot /mnt chpasswd
  rm -f /mnt/root/setup.sh /mnt/root/install.env
}

do_windows() {
  mount -o ro "$WIN_ESP" /tmp/winesp
  mkdir -p /mnt/boot/EFI
  cp -r /tmp/winesp/EFI/Microsoft /mnt/boot/EFI/
  umount /tmp/winesp
}

do_flatpaks() {
  arch-chroot /mnt flatpak remote-add --if-not-exists flathub "$FLATHUB" &&
  arch-chroot /mnt flatpak install -y --noninteractive --system flathub "${FLATPAKS[@]}"
}

do_finalize() {
  if [[ "$FLATPAK_OK" == "no" || "$NVIDIA" == "yes" ]]; then
    cat > /mnt/etc/systemd/system/flatpak-firstboot.service <<EOF
[Unit]
Description=Install Flatpak apps on first boot
Wants=network-online.target
After=network-online.target
ConditionPathExists=!/var/lib/flatpak-firstboot.done

[Service]
Type=oneshot
ExecStart=/usr/bin/flatpak remote-add --if-not-exists flathub $FLATHUB
ExecStart=/usr/bin/flatpak install -y --noninteractive --or-update --system flathub ${FLATPAKS[*]}
ExecStart=/usr/bin/flatpak update -y --noninteractive --system
ExecStartPost=/usr/bin/touch /var/lib/flatpak-firstboot.done
ExecStartPost=/usr/bin/systemctl disable flatpak-firstboot.service
Restart=on-failure
RestartSec=60
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
    arch-chroot /mnt systemctl enable flatpak-firstboot.service
  fi
  cp "$LOG" /mnt/var/log/arch-install.log || true
  sync
  umount -R /mnt
  cryptsetup close cryptroot
}

# =============================================================================
#  PHASE 4 — DEPLOYMENT
# =============================================================================
TOTAL=14
[[ "$ADD_WINDOWS" == "yes" ]] && TOTAL=15
DEPLOY_START=$SECONDS

section "PHASE 4" "DEPLOYMENT"

run "Wiping + partitioning"    do_partition
run "Formatting EFI"           do_esp
run "Encrypting drive (LUKS2)" do_luks
unset LUKS_PASS
CRYPT_UUID=$(blkid -s UUID -o value "$CRYPT")
run "Building Btrfs volumes"   do_btrfs
run "Syncing package keyring"  do_keyring
run "Installing base system"   do_pacstrap
try "Installing extras"        do_extras
[[ "$LAST_OK" == "yes" ]] || warn "Some extras were skipped — desktop remains functional."
run "Writing fstab"            do_fstab
run "Building Tile desktop"    do_desktop
run "Configuring system"       do_configure
run "Creating operator"        do_user
unset USER_PASS
if [[ "$ADD_WINDOWS" == "yes" ]]; then
  try "Linking Windows boot"   do_windows
  [[ "$LAST_OK" == "yes" ]] || warn "Couldn't add Windows — use your motherboard boot menu instead."
fi
try "Deploying Flatpak apps"   do_flatpaks
FLATPAK_OK="$LAST_OK"
run "Finalizing"               do_finalize

ELAPSED=$(fmt_time $(( SECONDS - DEPLOY_START )))

# =============================================================================
#  PHASE 5 — COMPLETE
# =============================================================================
done_banner
echo
SUMMARY=(
  "Profile  : $MACHINE_LABEL"
  "Hostname : $HOSTNAME"
  "Operator : $USERNAME"
  "Desktop  : Hyprland (Tile) / 10 Themes / 100% scale"
  "Duration : $ELAPSED"
  "Log      : /var/log/arch-install.log"
)
box "DEPLOYMENT COMPLETE" "${SUMMARY[@]}"

NEXT=(
  "1. Remove the USB stick when the screen goes black"
  "2. Type your encryption key at the boot prompt"
  "3. Log in as '$USERNAME' on the Tile login screen"
  "4. SUPER+T: Theme menu | SUPER+Shift+T: Dark/Light toggle"
  "5. Wi-Fi: click the network icon in the tray (top right)"
)
if [[ "$FLATPAK_OK" == "no" || "$NVIDIA" == "yes" ]]; then
  NEXT+=("6. Apps finish installing in the background once online"
         "   (watch: journalctl -fu flatpak-firstboot)")
fi
echo
box "NEXT" "${NEXT[@]}"

if [[ "$MACHINE" == "desktop" ]]; then
  echo
  box "DUAL BOOT" \
    "* BIOS: put 'Linux Boot Manager' first in the boot order" \
    "* Windows clock off? Run in Windows (admin terminal):" \
    "  reg add HKLM\\System\\CurrentControlSet\\Control\\" \
    "  TimeZoneInformation /v RealTimeIsUniversal /d 1" \
    "  /t REG_DWORD /f"
fi
if [[ "$NVIDIA" == "yes" ]]; then
  echo
  box "NVIDIA" \
    "* Check driver status: nvidia-smi" \
    "* Offload an app to the dGPU: prime-run <app>" \
    "* Steam games pick the dGPU automatically"
fi

echo
ask "Press ${GR}ENTER${C0} to reboot into your new system (Ctrl+C to stay): " _
printf '\n  %sSee you on the other side.%s\n\n' "$CY" "$C0"
sleep 1
reboot
