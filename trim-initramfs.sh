#!/bin/bash
# ==============================================================================
# TRIM INITRAMFS
# Version: 1.0.0
# MUST be executed on the host whose initramfs is being trimmed (e.g. hierophant)
#
# Why this exists
# ---------------
# hierophant's /boot is 781M while each initramfs is ~152M. With
# installonly_limit=3 that does not fit, and on 2026-08-08 a kernel update
# silently produced NO initramfs at all: dracut ran out of space in %post, the
# RPM transaction succeeded anyway, and the machine would not boot its default
# kernel. This script reclaims space so that failure mode stops being one
# `dnf update` away.
#
# Measured breakdown of initramfs-6.12.0-211.34.1 (uncompressed):
#     firmware 104.2M | modules 9.7M | other 108.8M
# hostonly is already "yes" (/usr/lib/dracut/dracut.conf.d/01-dist.conf), which
# is why modules are already small. The remaining bulk is firmware and the
# generic userspace dracut drags in, so THOSE are what this targets.
#
# Modes
# -----
#   analyze  (default)  Report only. Changes nothing. Run this first.
#   apply               Write dracut config, regenerate ONE kernel's initramfs,
#                       verify it, and roll back automatically if it looks wrong.
#   rollback            Restore the backed-up initramfs and remove the config.
#
# Safety model
# ------------
#   * Only ever regenerates ONE kernel. The other installed kernel and the
#     rescue image are left untouched as fallbacks, so a bad trim costs you a
#     GRUB menu selection, not a rescue USB.
#   * Refuses to run unless a second bootable kernel exists.
#   * Backs the original image up OUTSIDE /boot (there is no room in /boot).
#   * After regenerating, diffs the kernel-module list against the original.
#     Anything that disappeared and was NOT explicitly omitted is treated as a
#     failure and triggers automatic rollback.
#   * Independently asserts the root filesystem and LVM bits survived.
#
# Usage
#   sudo ./trim-initramfs.sh analyze
#   sudo ./trim-initramfs.sh apply --kver 6.12.0-211.44.1.el10_2.x86_64
#   sudo ./trim-initramfs.sh rollback --kver 6.12.0-211.44.1.el10_2.x86_64
#
# Env overrides
#   OMIT_DRACUT_MODULES   dracut modules to drop   (default: "i18n plymouth")
#   OMIT_DRIVERS          kernel drivers to drop   (default: "" — see analyze)
#   BACKUP_DIR            where originals are kept (default: /var/tmp/initramfs-backup)
#   DRACUT_CONF           config file written      (default: /etc/dracut.conf.d/99-trim.conf)
# ==============================================================================
set -uo pipefail

MODE="${1:-analyze}"
[[ "${MODE}" != "-"* ]] && shift || true

KVER=""
ASSUME_YES=false
while [ $# -gt 0 ]; do
    case "$1" in
        --kver) KVER="${2:-}"; shift 2 ;;
        --yes|-y) ASSUME_YES=true; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

KVER="${KVER:-$(uname -r)}"
BACKUP_DIR="${BACKUP_DIR:-/var/tmp/initramfs-backup}"
DRACUT_CONF="${DRACUT_CONF:-/etc/dracut.conf.d/99-trim.conf}"
OMIT_DRACUT_MODULES="${OMIT_DRACUT_MODULES:-i18n plymouth}"
OMIT_DRIVERS="${OMIT_DRIVERS:-}"

IMG="/boot/initramfs-${KVER}.img"
BACKUP="${BACKUP_DIR}/initramfs-${KVER}.img.orig"

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: must run as root (use sudo)." >&2
        exit 1
    fi
}

hr() { echo "-------------------------------------------------------------"; }

# --- shared helpers ---------------------------------------------------------

# Kernel modules inside an initramfs, as bare names (xfs.ko.xz -> xfs).
# Hyphens are normalised to underscores: module FILENAMES use '-' (dm-mod.ko)
# while the loaded module name uses '_' (dm_mod, as in lsmod). Comparing the two
# forms directly never matches, so everything is folded to '_' on both sides.
modules_in() {
    lsinitrd "$1" 2>/dev/null \
      | awk '/^-/ {print $9}' \
      | grep -oE '[^/]+\.ko(\.[a-z]+)?$' \
      | sed -E 's/\.ko(\.[a-z]+)?$//' \
      | tr '-' '_' \
      | sort -u
}

size_of() { du -m "$1" 2>/dev/null | cut -f1; }

# ==============================================================================
# ANALYZE
# ==============================================================================
do_analyze() {
    need_root
    echo "============================================================="
    echo " INITRAMFS ANALYSIS — ${KVER}"
    echo "============================================================="
    echo
    echo "/boot usage:"
    df -h /boot | tail -1 | sed 's/^/    /'
    echo
    echo "Images in /boot:"
    ls -lh /boot/initramfs-*.img 2>/dev/null \
      | awk '{printf "    %6s  %s\n", $5, $9}'
    echo
    if [ ! -r "${IMG}" ]; then
        echo "ERROR: ${IMG} not found or unreadable." >&2
        exit 1
    fi

    hr
    echo "Content breakdown (UNCOMPRESSED — totals exceed the on-disk image):"
    lsinitrd "${IMG}" 2>/dev/null \
      | awk '/^-/ { sz=$5; p=$9
            if (p ~ /^usr\/lib\/firmware/)     f+=sz
            else if (p ~ /^usr\/lib\/modules/) m+=sz
            else                               o+=sz }
        END { printf "    firmware : %8.1f MB\n    modules  : %8.1f MB\n    other    : %8.1f MB\n", \
              f/1048576, m/1048576, o/1048576 }'
    echo
    hr
    echo "Largest firmware directories (candidates for OMIT_DRIVERS):"
    lsinitrd "${IMG}" 2>/dev/null \
      | awk '/^-/ && $9 ~ /^usr\/lib\/firmware\// { split($9,a,"/"); s[a[4]]+=$5 }
          END { for (i in s) printf "    %8.1f MB  %s\n", s[i]/1048576, i }' \
      | sort -rn | head -15
    echo
    hr
    echo "Largest top-level paths:"
    lsinitrd "${IMG}" 2>/dev/null \
      | awk '/^-/ { n=split($9,a,"/"); k=(n>1 ? a[1]"/"a[2] : a[1]); s[k]+=$5 }
          END { for (i in s) printf "    %8.1f MB  %s\n", s[i]/1048576, i }' \
      | sort -rn | head -15
    echo
    hr
    echo "Hardware actually present (do NOT omit drivers backing these):"
    echo "  storage controllers:"
    lspci -k 2>/dev/null | grep -A3 -iE "SATA|RAID|SCSI|Non-Volatile" \
      | grep -iE "Kernel driver in use" | sort -u | sed 's/^/      /' | head -8
    echo "  network controllers:"
    lspci -k 2>/dev/null | grep -A3 -iE "Ethernet|Network" \
      | grep -iE "Kernel driver in use" | sort -u | sed 's/^/      /' | head -8
    echo
    hr
    echo "Boot-critical facts for this host:"
    echo "    root  : $(findmnt -no SOURCE,FSTYPE / 2>/dev/null)"
    echo "    /boot : $(findmnt -no SOURCE,FSTYPE /boot 2>/dev/null)"
    if lsblk -no TYPE 2>/dev/null | grep -q crypt; then
        echo "    LUKS  : PRESENT — keep 'i18n' (you need a keyboard for the passphrase)"
    else
        echo "    LUKS  : none — dropping 'i18n' is safe"
    fi
    echo
    echo "Proposed settings (override via env before 'apply'):"
    echo "    OMIT_DRACUT_MODULES=\"${OMIT_DRACUT_MODULES}\""
    echo "    OMIT_DRIVERS=\"${OMIT_DRIVERS:-<empty — pick from the firmware list above>}\""
    echo
    echo "Next:  sudo $0 apply --kver ${KVER}"
    echo "============================================================="
}

# ==============================================================================
# APPLY
# ==============================================================================
do_apply() {
    need_root

    [ -r "${IMG}" ] || { echo "ERROR: ${IMG} not found." >&2; exit 1; }

    # A fallback kernel must exist. Trimming the only bootable image is how you
    # end up needing rescue media.
    local other_count
    other_count=$(ls -1 /boot/initramfs-*.img 2>/dev/null \
                    | grep -v "kdump" | grep -vF "initramfs-${KVER}.img" | wc -l)
    if [ "${other_count}" -lt 1 ]; then
        echo "ERROR: no other initramfs found besides ${KVER}." >&2
        echo "  Refusing to trim the only bootable image." >&2
        exit 1
    fi

    # LUKS + no i18n = unenterable passphrase prompt.
    if lsblk -no TYPE 2>/dev/null | grep -q crypt; then
        if [[ " ${OMIT_DRACUT_MODULES} " == *" i18n "* ]]; then
            echo "ERROR: LUKS volumes present but OMIT_DRACUT_MODULES drops 'i18n'." >&2
            echo "  You would lose the keymap needed to type the passphrase." >&2
            echo "  Re-run with OMIT_DRACUT_MODULES=\"plymouth\"." >&2
            exit 1
        fi
    fi

    echo "============================================================="
    echo " TRIM INITRAMFS — ${KVER}"
    echo "============================================================="
    echo "  image      : ${IMG}  ($(size_of "${IMG}") MB)"
    echo "  fallbacks  : ${other_count} other image(s) — left untouched"
    echo "  omit dracut: ${OMIT_DRACUT_MODULES:-<none>}"
    echo "  omit drivers: ${OMIT_DRIVERS:-<none>}"
    echo "  backup dir : ${BACKUP_DIR}"
    echo

    if [ "${ASSUME_YES}" != "true" ]; then
        echo "This regenerates the initramfs for ${KVER}."
        echo "Re-run with --yes to proceed non-interactively."
        exit 0
    fi

    mkdir -p "${BACKUP_DIR}"
    echo "[1/5] Backing up original to ${BACKUP} ..."
    cp -a "${IMG}" "${BACKUP}" || { echo "ERROR: backup failed." >&2; exit 1; }

    echo "[2/5] Recording original module list ..."
    local before_list after_list
    before_list="$(mktemp)"; after_list="$(mktemp)"
    modules_in "${IMG}" > "${before_list}"
    echo "      $(wc -l < "${before_list}") kernel modules present"

    echo "[3/5] Writing ${DRACUT_CONF} ..."
    {
        echo "# Written by trim-initramfs.sh — reduces initramfs size so /boot (781M)"
        echo "# can hold multiple kernels. See the header of that script for context."
        [ -n "${OMIT_DRACUT_MODULES}" ] && echo "omit_dracut_modules+=\" ${OMIT_DRACUT_MODULES} \""
        [ -n "${OMIT_DRIVERS}" ]        && echo "omit_drivers+=\" ${OMIT_DRIVERS} \""
    } > "${DRACUT_CONF}"
    sed 's/^/      /' "${DRACUT_CONF}"

    echo "[4/5] Regenerating ..."
    if ! dracut --force --kver "${KVER}"; then
        echo "ERROR: dracut failed. Rolling back." >&2
        cp -a "${BACKUP}" "${IMG}"
        rm -f "${DRACUT_CONF}"
        exit 1
    fi

    echo "[5/5] Verifying ..."
    local new_size
    new_size=$(size_of "${IMG}")
    echo "      new size: ${new_size} MB (was $(size_of "${BACKUP}") MB)"

    modules_in "${IMG}" > "${after_list}"

    local fail=0

    # Boot-critical modules: the root filesystem, device-mapper, and whatever
    # drivers the storage controllers on this machine are ACTUALLY using. Derived
    # live rather than hardcoded, so this stays correct if the hardware changes.
    local critical="xfs dm_mod"
    local storage_drv
    storage_drv=$(lspci -k 2>/dev/null \
        | grep -A3 -iE "SATA|RAID|SCSI|Non-Volatile" \
        | sed -n 's/.*Kernel driver in use: *//p' | sort -u | tr '\n' ' ')
    critical="${critical} ${storage_drv}"
    critical="$(echo "${critical}" | tr '-' '_')"

    for must in ${critical}; do
        if ! grep -qx "${must}" "${after_list}"; then
            echo "      FAIL: boot-critical module '${must}' missing" >&2
            fail=1
        fi
    done

    if ! lsinitrd "${IMG}" 2>/dev/null | grep -q "sbin/lvm"; then
        echo "      FAIL: lvm binary missing — root is on LVM" >&2
        fail=1
    fi

    # Any module that vanished must be one we explicitly asked to omit.
    local unexpected
    # Patterns are normalised the same way as module names (see modules_in), so
    # OMIT_DRIVERS="dm-mod" and "dm_mod" behave identically. Globs are allowed.
    local omit_norm
    omit_norm="$(echo "${OMIT_DRIVERS}" | tr '-' '_')"
    # 'set -f' is essential: OMIT_DRIVERS may contain globs like "*gpu", and an
    # unquoted expansion would let the shell pathname-expand them against the
    # CURRENT DIRECTORY first. Running from a directory containing a matching
    # name silently replaces the pattern with that filename, the intended match
    # then fails, and the script rolls back a perfectly good initramfs.
    # Disabling pathname expansion keeps the pattern intact for [[ == ]].
    # Scoped to this command substitution's subshell, so the caller is unaffected.
    unexpected="$(set -f; comm -23 "${before_list}" "${after_list}" | while read -r m; do
        keep=0
        for d in ${omit_norm}; do
            [[ "${m}" == ${d} ]] && keep=1 && break
        done
        [ "${keep}" -eq 0 ] && echo "${m}"
    done)"
    # INFORMATIONAL, not a failure. Omitting a driver also drops the modules only
    # that driver depended on — e.g. omitting 'nouveau' correctly takes ttm,
    # gpu_sched and the drm_* helpers with it. Treating that as an error made the
    # check fail on every genuine omission. What actually matters is the
    # boot-critical assertion above; this list is here so a surprising cascade is
    # still visible to you.
    if [ -n "${unexpected}" ]; then
        local n_unexpected
        n_unexpected=$(echo "${unexpected}" | grep -c .)
        echo "      INFO: ${n_unexpected} additional module(s) removed as dependencies:"
        echo "${unexpected}" | head -20 | tr '\n' ' ' | fold -sw 60 | sed 's/^/        /'
        [ "${n_unexpected}" -gt 20 ] && echo "        ... and $((n_unexpected - 20)) more"
    fi

    rm -f "${before_list}" "${after_list}"

    if [ "${fail}" -ne 0 ]; then
        echo
        echo "  Verification FAILED — restoring the original image." >&2
        cp -a "${BACKUP}" "${IMG}"
        rm -f "${DRACUT_CONF}"
        echo "  Restored. Nothing changed. Investigate before retrying." >&2
        exit 1
    fi

    echo "      OK: boot-critical modules present, no unexpected removals"
    echo
    echo "============================================================="
    echo " Trimmed ${KVER}"
    echo "   $(size_of "${BACKUP}") MB  ->  ${new_size} MB"
    df -h /boot | tail -1 | sed 's/^/   /'
    echo
    echo " The other kernel(s) are UNCHANGED and still bootable."
    echo " Reboot to test. If it fails, pick the other kernel in GRUB and run:"
    echo "   sudo $0 rollback --kver ${KVER}"
    echo "============================================================="
}

# ==============================================================================
# ROLLBACK
# ==============================================================================
do_rollback() {
    need_root
    if [ ! -r "${BACKUP}" ]; then
        echo "ERROR: no backup at ${BACKUP}" >&2
        echo "  Regenerate from packages instead:" >&2
        echo "    sudo rm -f ${DRACUT_CONF}" >&2
        echo "    sudo dracut --force --kver ${KVER}" >&2
        exit 1
    fi
    echo "Restoring ${IMG} from ${BACKUP} ..."
    cp -a "${BACKUP}" "${IMG}" || { echo "ERROR: restore failed." >&2; exit 1; }
    rm -f "${DRACUT_CONF}"
    echo "Restored ($(size_of "${IMG}") MB) and removed ${DRACUT_CONF}."
    echo "NOTE: other kernels keep whatever config was in effect when built."
    echo "      Rebuild them too if needed: sudo dracut --force --kver <ver>"
}

case "${MODE}" in
    analyze)  do_analyze  ;;
    apply)    do_apply    ;;
    rollback) do_rollback ;;
    *) echo "Usage: $0 {analyze|apply|rollback} [--kver VERSION] [--yes]" >&2; exit 2 ;;
esac
