#!/system/bin/sh
# DexProtector / AppGuard / vGuard Bypass Toolkit
# Author: CSI · Hacktivate Co., Ltd. (https://hacktivate.tech/) · Confidentiality: Internal
# Runs at late_start as root. Arms the dexp_veto node for each uid in uids.txt.
# Disable this module in the manager (+ reboot) to stop auto-arming.
MODDIR=${0%/*}
NODE=/sys/kernel/dexp_veto

# node only exists on a CONFIG_DEXP_VETO=y kernel; bail quietly otherwise
[ -d "$NODE" ] || exit 0

# give sysfs a moment in case we're very early
for i in 1 2 3 4 5; do [ -w "$NODE/uid" ] && break; sleep 1; done

echo 1 > "$NODE/verbose" 2>/dev/null

# NOTE: the driver holds ONE target uid — the LAST non-comment line in uids.txt wins.
# Multi-uid would need a driver change; for a single target this is all you need.
while IFS= read -r line; do
	case "$line" in ''|\#*) continue;; esac
	echo "$line" > "$NODE/uid" 2>/dev/null && log -t dexp_veto "auto-armed uid=$line"
done < "$MODDIR/uids.txt"
