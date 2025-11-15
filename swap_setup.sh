#!/usr/bin/env bash
set -euo pipefail

# Interactive, safe swap setup script (file-based).
# Works on most Linux distros; handles btrfs/ZFS caveats, fallbacks & persistence.

# -------- Helpers --------
require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Please run as root (e.g., sudo bash $0)" >&2
    exit 1
  fi
}

pause() { read -rp "Press Enter to continue..."; }

yesno() {
  # usage: yesno "Question?" default_yes|default_no
  local q="$1" def="$2" ans prompt="[y/N]"
  [[ "$def" == "default_yes" ]] && prompt="[Y/n]"
  while true; do
    read -rp "$q $prompt " ans || true
    ans="${ans,,}"
    if [[ -z "$ans" ]]; then
      [[ "$def" == "default_yes" ]] && return 0 || return 1
    fi
    case "$ans" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
    esac
    echo "Please answer yes or no."
  done
}

detect_fs() {
  local path="$1"
  df -T "$path" 2>/dev/null | awk 'NR==2{print $2}'
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

bytes_from_human() {
  # Convert sizes like 2G, 2048M, 512K, 1T to bytes (integer).
  local s="${1^^}"
  if [[ "$s" =~ ^([0-9]+)([KMGT]?)B?$ ]]; then
    local num="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
    case "$unit" in
      K) echo $((num * 1024)) ;;
      M) echo $((num * 1024 * 1024)) ;;
      G) echo $((num * 1024 * 1024 * 1024)) ;;
      T) echo $((num * 1024 * 1024 * 1024 * 1024)) ;;
      "") echo "$num" ;;
    esac
  else
    echo "INVALID"
  fi
}

ensure_line_in_file() {
  # usage: ensure_line_in_file "line" "/path/file"
  local line="$1" file="$2"
  touch "$file"
  chmod 644 "$file" || true
  grep -Fqx "$line" "$file" || echo "$line" >> "$file"
}

is_container() {
  # best-effort detection (covers docker/systemd-nspawn/lxc)
  if grep -qaE 'container=' /proc/1/environ 2>/dev/null; then return 0; fi
  if [[ -f /.dockerenv ]] || [[ -d /run/systemd/container ]]; then return 0; fi
  return 0 2>/dev/null || return 1
}

# -------- Main steps --------
require_root

echo "=== Swap Setup Wizard ==="
echo "This will create/enable swap space and make it persistent."
echo

if is_container; then
  echo "Note: It looks like you're inside a container or unprivileged environment."
  echo "      Enabling a swap FILE may not be permitted. Proceed only if you know it works here."
  echo
fi

# Ask: action type
if yesno "Do you want to (re)create/enable swap?" default_yes; then
  ACTION="create"
else
  if yesno "Do you want to UNINSTALL/disable existing swap and remove its file?" default_no; then
    ACTION="uninstall"
  else
    echo "No changes made."
    exit 0
  fi
fi

# Uninstall path early-exit
if [[ "$ACTION" == "uninstall" ]]; then
  echo
  echo "Current active swap (if any):"
  swapon --show || true

  read -rp "Enter swap file path to remove (default: /swapfile): " SWAPFILE
  SWAPFILE="${SWAPFILE:-/swapfile}"

  if swapon --show=NAME 2>/dev/null | grep -Fxq "$SWAPFILE"; then
    echo "Disabling swap: $SWAPFILE"
    swapoff "$SWAPFILE"
  else
    echo "Swap $SWAPFILE is not active (ok)."
  fi

  if [[ -f /etc/fstab ]]; then
    echo "Removing $SWAPFILE entry from /etc/fstab (if present)..."
    cp /etc/fstab /etc/fstab.bak.$(date +%s)
    sed -i "\|^$SWAPFILE[[:space:]]\+none[[:space:]]\+swap[[:space:]]|d" /etc/fstab
  fi

  if [[ -f "$SWAPFILE" ]]; then
    echo "Deleting file $SWAPFILE"
    rm -f "$SWAPFILE"
  else
    echo "File $SWAPFILE not found (ok)."
  fi

  if [[ -f /etc/sysctl.conf ]]; then
    sed -i '/^vm.swappiness=/d' /etc/sysctl.conf || true
    sysctl -p >/dev/null 2>&1 || true
  fi

  echo "Uninstall complete."
  exit 0
fi

# CREATE / ENABLE path
echo
echo "Current active swap (if any):"
swapon --show || true
echo

# Prompt for size
read -rp "Desired swap size (e.g., 2G, 2048M, 512M) [default: 2G]: " SIZE_HUMAN
SIZE_HUMAN="${SIZE_HUMAN:-2G}"
BYTES=$(bytes_from_human "$SIZE_HUMAN")
if [[ "$BYTES" == "INVALID" ]]; then
  echo "Invalid size format. Examples: 1G, 2048M, 512M, 262144K, 1T" >&2
  exit 1
fi

# Enforce minimum 1 MiB and round up to whole MiB for dd
MI_B=$((1024*1024))
if (( BYTES < MI_B )); then
  echo "Swap size must be at least 1MiB." >&2
  exit 1
fi
# round up to MiB
if (( BYTES % MI_B != 0 )); then
  BYTES=$(( ((BYTES + MI_B - 1) / MI_B) * MI_B ))
fi
COUNT_MB=$(( BYTES / MI_B ))

# Prompt for path
read -rp "Swap file path [default: /swapfile]: " SWAPFILE
SWAPFILE="${SWAPFILE:-/swapfile}"

# Prompt for swappiness
read -rp "Swappiness (0-100) [default: 10]: " SWAPPINESS
SWAPPINESS="${SWAPPINESS:-10}"
if ! [[ "$SWAPPINESS" =~ ^[0-9]+$ ]] || (( SWAPPINESS < 0 || SWAPPINESS > 100 )); then
  echo "Invalid swappiness value. Must be 0-100." >&2
  exit 1
fi

# Filesystem checks
PARENT_DIR="$(dirname "$SWAPFILE")"
mkdir -p "$PARENT_DIR"
FS_TYPE=$(detect_fs "$PARENT_DIR")
echo
echo "Summary:"
echo " - Swap size:     $SIZE_HUMAN (rounded: $((BYTES/MI_B)) MiB)"
echo " - Swap file:     $SWAPFILE"
echo " - Swappiness:    $SWAPPINESS"
echo " - Filesystem:    ${FS_TYPE:-unknown}"
if [[ "$FS_TYPE" == "zfs" ]]; then
  echo "   [Warn] ZFS detected. A ZVOL is recommended for swap instead of a file."
fi
if [[ "$FS_TYPE" == "btrfs" ]]; then
  echo "   [Info] btrfs detected. Will set NOCOW (+C) on the directory BEFORE creating the file."
fi
echo
if ! yesno "Proceed?" default_yes; then
  echo "Aborted."
  exit 0
fi

# If active swap at same path, disable for recreation
if swapon --show=NAME 2>/dev/null | grep -Fxq "$SWAPFILE"; then
  echo "Disabling currently active swap at $SWAPFILE ..."
  swapoff "$SWAPFILE"
fi

# If file exists and is swap, confirm reuse or recreate
RECREATE=false
if [[ -f "$SWAPFILE" ]]; then
  if file -s "$SWAPFILE" | grep -qi "swap file"; then
    echo "Existing swap file detected at $SWAPFILE."
    if yesno "Reuse it (skip recreation)?" default_yes; then
      RECREATE=false
    else
      RECREATE=true
    fi
  else
    echo "File $SWAPFILE exists (not a swap file). Will recreate."
    RECREATE=true
  fi
else
  RECREATE=true
fi

if $RECREATE; then
  echo "Creating swap file..."
  rm -f "$SWAPFILE" || true

  # Handle btrfs NOCOW *before* file creation
  if [[ "$FS_TYPE" == "btrfs" ]]; then
    echo "Setting NOCOW (+C) on $PARENT_DIR (may require root on btrfs)..."
    if have_cmd chattr; then
      chattr +C "$PARENT_DIR" 2>/dev/null || true
    fi
    # verify directory attr (best-effort)
    if have_cmd lsattr; then
      if ! lsattr -d "$PARENT_DIR" 2>/dev/null | grep -q ' C '; then
        echo "Warning: Could not verify +C on the directory. We'll still try to create a non-sparse file via dd."
      fi
    fi
  fi

  # Prefer fallocate when not btrfs; on btrfs use dd to avoid holes
  CREATE_WITH_DD=false
  if [[ "$FS_TYPE" == "btrfs" ]]; then
    CREATE_WITH_DD=true
  elif have_cmd fallocate; then
    if ! fallocate -l "$BYTES" "$SWAPFILE" 2>/dev/null; then
      echo "fallocate failed; falling back to dd..."
      CREATE_WITH_DD=true
    fi
  else
    CREATE_WITH_DD=true
  fi

  if $CREATE_WITH_DD; then
    dd if=/dev/zero of="$SWAPFILE" bs=1M count="$COUNT_MB" status=progress
    sync
  fi

  # On btrfs, verify no holes (requires filefrag)
  if [[ "$FS_TYPE" == "btrfs" ]] && have_cmd filefrag; then
    # "extent count" should be >0 and "holes" absent
    if filefrag -v "$SWAPFILE" 2>/dev/null | grep -q 'hole'; then
      echo "ERROR: btrfs swapfile appears to contain holes (not allowed). Aborting."
      rm -f "$SWAPFILE" || true
      exit 1
    fi
  fi
fi

# Secure permissions
chmod 600 "$SWAPFILE"

# Mark as swap
echo "Marking file as swap..."
if ! mkswap "$SWAPFILE" >/dev/null; then
  echo "mkswap failed. If on ZFS, consider creating a ZVOL; if on btrfs, ensure NOCOW and no holes." >&2
  exit 1
fi

# Enable swap now
echo "Enabling swap..."
if ! swapon "$SWAPFILE"; then
  echo "swapon failed. Check dmesg/journalctl for details." >&2
  exit 1
fi

echo
echo "Swap now active:"
swapon --show

# Persist in /etc/fstab
echo
echo "Ensuring persistence in /etc/fstab..."
FSTAB_LINE="$SWAPFILE none swap sw 0 0"
if [[ -f /etc/fstab ]]; then
  cp /etc/fstab /etc/fstab.bak.$(date +%s)
fi
sed -i "\|^$SWAPFILE[[:space:]]\+none[[:space:]]\+swap[[:space:]]|d" /etc/fstab 2>/dev/null || true
ensure_line_in_file "$FSTAB_LINE" "/etc/fstab"

# Set swappiness (runtime + persistent)
echo
echo "Setting swappiness to $SWAPPINESS ..."
sysctl vm.swappiness="$SWAPPINESS" >/dev/null || true
sed -i '/^vm\.swappiness=/d' /etc/sysctl.conf 2>/dev/null || true
ensure_line_in_file "vm.swappiness=$SWAPPINESS" "/etc/sysctl.conf"

echo
echo "All set!"
echo " - Swap file: $SWAPFILE"
echo " - Size:      $((BYTES/MI_B)) MiB"
echo " - Swappiness:$SWAPPINESS"
echo " - Persistent across reboots via /etc/fstab and /etc/sysctl.conf"
echo
if yesno "Do you want to print a quick verification (free -h)?" default_yes; then
  free -h
fi
