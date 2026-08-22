#!/bin/bash
set -e

# ==============================================================================
# APPLY INFERENCE NODE CONFIG — new-setup-external-gpu
#
# Applies Talos configuration to the external GPU inference node.
# The node is a PHYSICAL MACHINE (not a libvirt VM) on the flat LAN.
#
# Usage:
#   ./40-apply-inference-config.sh --list-disks    # inventory only, applies nothing
#   ./40-apply-inference-config.sh --check         # resolve + guard only, no apply
#   ./40-apply-inference-config.sh                 # guard, then apply
#
# Prerequisites:
#   1. GPU node is booted from Talos USB installer and in maintenance mode.
#   2. GPU node received a DHCP lease (192.168.0.x) from the LAN router. The
#      apply targets that maintenance IP; after reboot it comes up static at
#      192.168.5.31. Find the maintenance IP via the console display or the
#      ARP lookup in 45-enroll-external-node.sh (INFERENCE_MAINT_IP).
#   3. The TALOS_CONFIG directory has been populated by 15-apply-cp-config.sh.
#   4. machine.install.diskSelector in configs/patch-inference-0.yaml names the
#      internal SSD. Run --list-disks to get the exact block to paste.
#
# INSTALL DISK SAFETY (added 2026-08-22)
# --------------------------------------
# The patch used to hardcode 'disk: /dev/sda'. On a physical machine booted from
# the Talos USB, the stick is a USB-attached SCSI device and takes the FIRST sd*
# name -- /dev/sda -- so that named the boot medium, not the internal drive. With
# 'wipe: true' the installer targeted the stick it was running from.
#
# Two changes prevent a recurrence:
#   * the patch now selects the disk by stable hardware attribute (diskSelector,
#     which per the Talos v1.12 reference "Always has priority over disk"), and
#   * this script resolves that selector against the node's live disk inventory
#     BEFORE applying, and refuses to proceed if it resolves to the boot medium,
#     a CD-ROM, a read-only device, nothing at all, or more than one disk.
#
# Escape hatches:
#   INFERENCE_INSTALL_DISK_SERIAL=<serial>   select without editing the YAML
#   INFERENCE_INSTALL_DISK_WWID=<wwid>       ditto, by WWID
#   ALLOW_UNSAFE_INSTALL_DISK=true           downgrade the guard to a warning
#
# NOTE: 50-inference-gpu-setup.sh (PCI passthrough) does NOT apply here.
#       The GPU is natively attached to the physical node.
#       The GPU Operator is owned by complete-build, not this repo:
#       complete-build/infrastructure/nvidia-operator.sh (Step 1.9 of setup-complete.sh).
# ==============================================================================

LIST_ONLY=false
CHECK_ONLY=false
while [ $# -gt 0 ]; do
    case "$1" in
        -l|--list-disks)
            LIST_ONLY=true
            ;;
        -c|--check)
            # Resolve the configured selector against the live node and run the
            # full guard, but stop before applying. Use this to confirm the
            # target immediately before a destructive apply.
            CHECK_ONLY=true
            ;;
        -h|--help)
            sed -n '4,45p' "$0"
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument '$1'. Use --list-disks, --check or --help." >&2
            exit 1
            ;;
    esac
    shift
done

if [ -z "${SETUP_ROOT}" ]; then
    export SETUP_ROOT="/mnt/hegemon-share/share/code/kubernetes-setup"
fi

source "${SETUP_ROOT}/new-setup-external-gpu/config-env.sh"
source "${SETUP_ROOT}/new-setup-external-gpu/config-endpoints.sh"

PATCH_FILE="${SETUP_ROOT}/new-setup-external-gpu/configs/patch-inference-0.yaml"

if [ ! -f "${PATCH_FILE}" ]; then
    echo "ERROR: Patch file not found: ${PATCH_FILE}" >&2
    exit 1
fi

if [ -z "${INFERENCE_IP_0}" ]; then
    echo "ERROR: INFERENCE_IP_0 is not set. Check config-endpoints.sh." >&2
    exit 1
fi

# The node is in maintenance mode at a temporary router DHCP address
# (192.168.0.x), NOT yet at its final static 192.168.5.31. Apply to the
# maintenance IP; the patch then assigns the static address on reboot.
# INFERENCE_MAINT_IP is normally exported by 45-enroll-external-node.sh
# (ARP-discovered). Falls back to INFERENCE_IP_0 if the two are equal
# (e.g. a router DHCP reservation was set up for the node's MAC).
MAINT_IP="${INFERENCE_MAINT_IP:-${INFERENCE_IP_0}}"

# ---------------------------------------------------------------------------
# Fetch the node's live block-device inventory
# ---------------------------------------------------------------------------
# NOT run under sudo. talosctl authenticates with the talosconfig client
# certificate, not local root: it needs no local privilege to talk to a node.
# The  wrappers this repo used were both unnecessary and actively
# harmful -- junie has no passwordless sudo on hierophant, so over a batch SSH
# session sudo prompts for a password, fails, and the caller sees only a
# generic timeout. Verified 2026-08-22: every talosctl call in this flow
# succeeds as junie without sudo. (15-apply-cp-config.sh and
# 35-apply-worker-config.sh still wrap talosctl in ; they are unchanged
# here because they were not exercised this session.)
TALOSCTL="${TALOS_ROOT}/talosctl"

DISKS_JSON="$(mktemp /tmp/inference-disks.XXXXXX.json)"
VOLS_JSON="$(mktemp /tmp/inference-vols.XXXXXX.json)"
RESOLVED_OUT="$(mktemp /tmp/inference-resolved.XXXXXX.txt)"
trap 'rm -f "${DISKS_JSON}" "${VOLS_JSON}" "${RESOLVED_OUT}"' EXIT

echo "Querying block devices on the inference node in maintenance mode..."
echo "  Maintenance IP : ${MAINT_IP}"
echo ""

if ! "${TALOSCTL}" --talosconfig "${TALOSCONFIG}" \
        get disks --insecure \
        --nodes "${MAINT_IP}" --endpoints "${MAINT_IP}" \
        -o json > "${DISKS_JSON}" 2>/dev/null; then
    echo "ERROR: Could not read the disk inventory from ${MAINT_IP}." >&2
    echo "  Check that the node is powered on, booted from the Talos USB, and" >&2
    echo "  in maintenance mode with a DHCP lease. Verify with:" >&2
    echo "    ${TALOSCTL} get disks --insecure -n ${MAINT_IP} -e ${MAINT_IP}" >&2
    exit 1
fi

# Volume discovery positively identifies the Talos boot medium (an iso9660
# filesystem labelled TALOS_*). Non-fatal if it fails: the transport==usb
# check below still catches the common case.
"${TALOSCTL}" --talosconfig "${TALOSCONFIG}" \
    get discoveredvolumes --insecure \
    --nodes "${MAINT_IP}" --endpoints "${MAINT_IP}" \
    -o json > "${VOLS_JSON}" 2>/dev/null || echo "" > "${VOLS_JSON}"

# ---------------------------------------------------------------------------
# Inventory, selector resolution and install-disk guard
# ---------------------------------------------------------------------------
MODE="apply"
[ "${LIST_ONLY}" = "true" ] && MODE="list"

set +e
python3 - "${DISKS_JSON}" "${VOLS_JSON}" "${PATCH_FILE}" "${MODE}" "${RESOLVED_OUT}" <<'PYEOF'
import fnmatch
import json
import os
import re
import sys

disks_path, vols_path, patch_path, mode, resolved_out = sys.argv[1:6]

# --- concatenated-JSON reader ------------------------------------------------
# 'talosctl get -o json' emits a stream of pretty-printed objects, not a list
# and not JSONL, so neither json.load nor a line loop works.
def read_stream(path):
    try:
        text = open(path).read()
    except OSError:
        return []
    out, dec, idx = [], json.JSONDecoder(), 0
    n = len(text)
    while idx < n:
        while idx < n and text[idx] in " \t\r\n":
            idx += 1
        if idx >= n:
            break
        try:
            obj, end = dec.raw_decode(text, idx)
        except ValueError:
            break
        out.append(obj)
        idx = end
    return out

disks = [{"id": r.get("metadata", {}).get("id", "?"), **r.get("spec", {})}
         for r in read_stream(disks_path)]
vols = [{"id": r.get("metadata", {}).get("id", "?"), **r.get("spec", {})}
        for r in read_stream(vols_path)]

if not disks:
    print("ERROR: the node reported no disks at all.", file=sys.stderr)
    sys.exit(1)

# --- classify ----------------------------------------------------------------
VIRTUAL = re.compile(r"^(loop|ram|zram|md|dm-)\d")
OPTICAL = re.compile(r"^sr\d")

# Disks carrying a Talos install medium (iso9660 labelled TALOS*).
boot_disks = set()
for v in vols:
    label = (v.get("label") or "")
    if v.get("name") == "iso9660" and label.upper().startswith("TALOS"):
        boot_disks.add(v.get("parent") or v.get("id"))

def dtype(d):
    t = (d.get("transport") or "").lower()
    if t == "nvme":
        return "nvme"
    if t in ("mmc", "sd"):
        return "sd"
    return "hdd" if d.get("rotational") else "ssd"

def why_unusable(d):
    """Return a reason string if this disk must never be an install target."""
    if d.get("cdrom"):
        return "CD-ROM"
    if OPTICAL.match(d["id"]):
        return "optical drive"
    if VIRTUAL.match(d["id"]):
        return "virtual device"
    if d.get("readonly"):
        return "read-only"
    if d["id"] in boot_disks:
        return "TALOS BOOT MEDIUM (this is the stick you booted from)"
    if (d.get("transport") or "").lower() == "usb":
        return "USB device"
    return None

for d in disks:
    d["_bad"] = why_unusable(d)
    d["_type"] = dtype(d)

# Talos will never install to a loop/ram/dm device, so exclude them from the
# universe the selector is resolved against. USB sticks, CD-ROMs and read-only
# devices deliberately STAY in, so a selector that hits one gets a specific
# refusal rather than a vague "matched nothing".
universe = [d for d in disks if not VIRTUAL.match(d["id"])]
candidates = [d for d in disks if not d["_bad"]]

# --- inventory table ---------------------------------------------------------
def cell(v):
    return "-" if v in (None, "") else str(v)

rows = [("DEV", "SIZE", "TRANSPORT", "TYPE", "MODEL", "SERIAL", "STATUS")]
for d in sorted(disks, key=lambda x: x["id"]):
    if VIRTUAL.match(d["id"]) and not d.get("model"):
        continue  # suppress loop0..N noise
    rows.append((
        cell(d.get("dev_path", "/dev/" + d["id"])),
        cell(d.get("pretty_size")),
        cell(d.get("transport")),
        d["_type"],
        cell(d.get("model")),
        cell(d.get("serial")),
        d["_bad"] and ("EXCLUDED: " + d["_bad"]) or "candidate",
    ))
w = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
print("=== BLOCK DEVICES ON THE INFERENCE NODE ===")
for i, r in enumerate(rows):
    print("  " + "  ".join(r[j].ljust(w[j]) for j in range(len(r))).rstrip())
    if i == 0:
        print("  " + "  ".join("-" * w[j] for j in range(len(r))))
print("")

if boot_disks:
    print("Talos boot medium identified: " + ", ".join(sorted(boot_disks)))
else:
    print("NOTE: no iso9660/TALOS_* volume found, so the boot medium could not be")
    print("      positively identified. USB-transport disks are still excluded.")
print("")

# --- selector suggestion -----------------------------------------------------
def suggest(d):
    if d.get("serial"):
        return '    diskSelector:\n      serial: "%s"' % d["serial"]
    if d.get("wwid"):
        return '    diskSelector:\n      wwid: "%s"' % d["wwid"]
    if d.get("model"):
        return ('    diskSelector:\n      model: "%s"\n      size: "%s"'
                % (d["model"], d.get("size")))
    return '    diskSelector:\n      busPath: "%s"' % d.get("bus_path", "")

if mode == "list":
    if not candidates:
        print("NO INSTALLABLE DISK FOUND. Every device is a boot medium, CD-ROM,")
        print("read-only or virtual. Check that the internal drive is connected")
        print("and visible to the BIOS (AHCI mode, not RAID/Intel RST).")
        sys.exit(1)
    print("=== PASTE INTO configs/patch-inference-0.yaml UNDER machine.install ===")
    for d in candidates:
        print("")
        print("  # %s  %s  %s" % (d.get("dev_path"), d.get("pretty_size"),
                                  d.get("model") or "(no model)"))
        print(suggest(d))
    print("")
    if len(candidates) > 1:
        print("%d candidates found -- pick the internal SSD deliberately."
              % len(candidates))
    print("Then run ./40-apply-inference-config.sh with no arguments.")
    sys.exit(0)

# --- resolve the configured selector ----------------------------------------
import yaml
with open(patch_path) as fh:
    patch = yaml.safe_load(fh) or {}
install = ((patch.get("machine") or {}).get("install") or {})

sel = dict(install.get("diskSelector") or {})
src = "configs/patch-inference-0.yaml (machine.install.diskSelector)"

env_serial = os.environ.get("INFERENCE_INSTALL_DISK_SERIAL", "").strip()
env_wwid = os.environ.get("INFERENCE_INSTALL_DISK_WWID", "").strip()
if env_serial:
    sel, src = {"serial": env_serial}, "INFERENCE_INSTALL_DISK_SERIAL"
elif env_wwid:
    sel, src = {"wwid": env_wwid}, "INFERENCE_INSTALL_DISK_WWID"

legacy_disk = install.get("disk")

def fail(msg, *extra):
    sys.stdout.flush()
    print("")
    print("ERROR: " + msg, file=sys.stderr)
    for line in extra:
        print("  " + line, file=sys.stderr)
    print("", file=sys.stderr)
    print("  Run './40-apply-inference-config.sh --list-disks' to see the", file=sys.stderr)
    print("  inventory above with a ready-to-paste diskSelector block.", file=sys.stderr)
    sys.exit(1)

if not sel and not legacy_disk:
    fail("no install disk configured.",
         "machine.install has neither diskSelector nor disk.")

if not sel:
    # Someone put a bare device name back. Honour it, but still guard it --
    # this is exactly the path that wiped the boot stick.
    src = "configs/patch-inference-0.yaml (machine.install.disk)"
    print("WARNING: machine.install.disk is set to '%s' with no diskSelector."
          % legacy_disk)
    print("         Device names are not stable on this node -- see the comment")
    print("         block in the patch file. Prefer diskSelector.")
    print("")
    matched = [d for d in universe
               if d.get("dev_path") == legacy_disk or d["id"] == str(legacy_disk).replace("/dev/", "")]
else:
    if any("REPLACE_ME" in str(v) for v in sel.values()):
        fail("the diskSelector placeholder has not been filled in.",
             "configs/patch-inference-0.yaml still contains REPLACE_ME.")

    SIZE_UNITS = {"B": 1, "KB": 10**3, "MB": 10**6, "GB": 10**9, "TB": 10**12,
                  "KIB": 2**10, "MIB": 2**20, "GIB": 2**30, "TIB": 2**40}

    def size_match(expr, actual):
        m = re.match(r"^\s*(>=|<=|==|=|>|<)?\s*([0-9.]+)\s*([A-Za-z]*)\s*$", str(expr))
        if not m:
            return None
        op, num, unit = m.group(1) or "==", float(m.group(2)), (m.group(3) or "B").upper()
        if unit not in SIZE_UNITS:
            return None
        want = num * SIZE_UNITS[unit]
        return {">=": actual >= want, "<=": actual <= want, ">": actual > want,
                "<": actual < want, "==": actual == want, "=": actual == want}[op]

    FIELD = {"serial": "serial", "wwid": "wwid", "model": "model", "name": "name",
             "modalias": "modalias", "uuid": "uuid", "buspath": "bus_path"}

    def matches(d):
        for key, want in sel.items():
            k = key.lower()
            if k == "type":
                if d["_type"] != str(want).lower():
                    return False
            elif k == "size":
                r = size_match(want, d.get("size") or 0)
                if r is not True:
                    return False
            elif k in FIELD:
                have = d.get(FIELD[k])
                if have is None or not fnmatch.fnmatchcase(str(have), str(want)):
                    return False
            else:
                fail("diskSelector uses an unsupported matcher '%s'." % key,
                     "Supported: serial, wwid, model, name, modalias, uuid,",
                     "type, busPath, size.")
        return True

    matched = [d for d in universe if matches(d)]

# --- guard -------------------------------------------------------------------
allow_unsafe = os.environ.get("ALLOW_UNSAFE_INSTALL_DISK", "").lower() == "true"

def verdict(msg, *extra):
    if allow_unsafe:
        print("")
        print("!!! GUARD OVERRIDDEN (ALLOW_UNSAFE_INSTALL_DISK=true) !!!")
        print("!!! " + msg)
        for line in extra:
            print("!!! " + line)
        print("")
        return
    fail(msg, *extra)

if sel:
    print("Install disk selector : %s" % json.dumps(sel))
else:
    print("Install disk (legacy) : %s" % legacy_disk)
print("Selector source       : %s" % src)
sys.stdout.flush()

if not matched:
    verdict("the install disk selector matches NO disk on this node.",
            "Talos would fail the install rather than pick a fallback.")
elif len(matched) > 1:
    verdict("the install disk selector matches %d disks: %s"
            % (len(matched), ", ".join(d.get("dev_path", d["id"]) for d in matched)),
            "Add a unique matcher (serial or wwid) so exactly one disk matches.")
else:
    target = matched[0]
    if target["_bad"]:
        verdict("the install disk resolves to %s -- %s."
                % (target.get("dev_path", target["id"]), target["_bad"]),
                "This is the failure mode that wiped the boot stick. Refusing.")
    else:
        print("Resolved install disk : %s  (%s, %s, serial %s)"
              % (target.get("dev_path"), target.get("pretty_size"),
                 target.get("transport") or "?", target.get("serial") or "-"))
        print("[OK] Install target is a local, writable, non-boot device.")
        with open(resolved_out, "w") as fh:
            fh.write(target.get("dev_path", "") + "\n")
PYEOF
GUARD_RC=$?
set -e

if [ ${GUARD_RC} -ne 0 ]; then
    exit ${GUARD_RC}
fi

if [ "${LIST_ONLY}" = "true" ]; then
    exit 0
fi

if [ "${CHECK_ONLY}" = "true" ]; then
    echo ""
    echo "--check specified — guard passed, nothing applied."
    echo "Re-run without --check to apply and install."
    exit 0
fi

# ---------------------------------------------------------------------------
# Build the effective patch (env override support) and apply
# ---------------------------------------------------------------------------
RESOLVED_DEV="$(cat "${RESOLVED_OUT}" 2>/dev/null || true)"

# configs/machine-patches.yaml sets 'disk: /dev/vda' for the libvirt VMs, and
# that value is baked into worker.yaml. diskSelector overrides it (the Talos
# v1.12 reference: "Always has priority over disk"), so it is inert here -- but
# leaving a wrong device name in the applied config is exactly the footgun this
# change exists to remove. Now that the guard has resolved the selector against
# the live inventory, pin 'disk' to the SAME device so the two cannot disagree,
# and drop it entirely if the guard was overridden without producing a result.
EFFECTIVE_PATCH="${PATCH_FILE}"
if [ -n "${RESOLVED_DEV}" ] || [ -n "${INFERENCE_INSTALL_DISK_SERIAL}" ] \
   || [ -n "${INFERENCE_INSTALL_DISK_WWID}" ]; then
    # Generated state goes to /tmp, never the shared mount.
    EFFECTIVE_PATCH="/tmp/patch-inference-0.effective.yaml"
    python3 - "${PATCH_FILE}" "${EFFECTIVE_PATCH}" "${RESOLVED_DEV}" <<'PYEOF'
import os, sys, yaml
src, dst, resolved_dev = sys.argv[1], sys.argv[2], sys.argv[3].strip()
doc = yaml.safe_load(open(src)) or {}
install = doc.setdefault("machine", {}).setdefault("install", {})

serial = os.environ.get("INFERENCE_INSTALL_DISK_SERIAL", "").strip()
wwid = os.environ.get("INFERENCE_INSTALL_DISK_WWID", "").strip()
if serial:
    install["diskSelector"] = {"serial": serial}
elif wwid:
    install["diskSelector"] = {"wwid": wwid}

if resolved_dev:
    install["disk"] = resolved_dev
else:
    install.pop("disk", None)

with open(dst, "w") as fh:
    yaml.safe_dump(doc, fh, default_flow_style=False, sort_keys=False)
PYEOF
    echo ""
    echo "Generated effective patch: ${EFFECTIVE_PATCH}"
    if [ -n "${INFERENCE_INSTALL_DISK_SERIAL}" ] || [ -n "${INFERENCE_INSTALL_DISK_WWID}" ]; then
        echo "  (environment selector override in effect)"
    fi
    echo "  machine.install.disk pinned to ${RESOLVED_DEV:-<removed>} to match the selector."
fi

echo ""
echo "Applying Talos configuration to external GPU inference node..."
echo "  Maintenance IP : ${MAINT_IP}"
echo "  Final IP       : ${INFERENCE_IP_0} (after reboot)"
echo "  Patch file     : $(basename ${EFFECTIVE_PATCH})"
echo "  Install disk   : ${RESOLVED_DEV:-<guard overridden>}"
echo "  Config dir     : ${TALOS_CONFIG}"
echo ""

${TALOS_ROOT}/talosctl apply-config --insecure \
    --talosconfig "${TALOSCONFIG}" \
    --nodes "${MAINT_IP}" \
    --endpoints "${MAINT_IP}" \
    --file "${TALOS_CONFIG}/worker.yaml" \
    --config-patch "@${EFFECTIVE_PATCH}"

echo ""
echo "=== INFERENCE CONFIG APPLIED ==="
echo "The node will now reboot and install Talos to ${RESOLVED_DEV:-its selected disk}."
echo "After reboot it will come up as 'inference-0' at ${INFERENCE_IP_0}."
echo ""
echo "REMOVE THE TALOS USB STICK NOW (or change the BIOS boot order)."
echo "  If the machine boots the stick again it lands back in maintenance mode,"
echo "  which looks exactly like the install having failed."
echo ""
echo "Next steps:"
echo "  1. Wait for the node to join the cluster (check: kubectl get nodes)"
echo "  2. Apply the GPU post-boot patch and reboot (loads the NVIDIA kernel"
echo "     modules — the GPU operator cannot validate without them):"
echo "       talosctl --nodes ${INFERENCE_IP_0} --endpoints ${CP_VIP} \\"
echo "         patch machineconfig --mode=reboot \\"
echo "         --patch @configs/post-inference-talos.yaml"
echo "  3. GPU Operator: owned by complete-build, not this repo. It runs as"
echo "     Step 1.9 of setup-complete.sh, or standalone with:"
echo "       bash complete-build/infrastructure/nvidia-operator.sh"
echo ""
echo "NOTE: 45-enroll-external-node.sh performs steps 1-2 automatically."
echo "      This script is normally invoked by it, not run standalone."
