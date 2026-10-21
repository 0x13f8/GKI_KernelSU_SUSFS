#!/system/bin/sh
# DexProtector / AppGuard / vGuard Bypass Toolkit
# Author: CSI · Hacktivate Co., Ltd. (https://hacktivate.tech/) · Confidentiality: Internal
# Flash-time guard: refuse to install if the kernel has no dexp_veto node.
if [ ! -d /sys/kernel/dexp_veto ]; then
	ui_print "! /sys/kernel/dexp_veto not found."
	ui_print "! Flash a kernel built with CONFIG_DEXP_VETO=y first (see dexp-kernel-veto)."
	abort "! aborting — no veto kernel"
fi
ui_print "- dexp_veto node present. Auto-arm will apply uids.txt at each boot."
ui_print "- Toggle this module off (+ reboot) to stop auto-arming."
set_perm_recursive "$MODPATH" 0 0 0755 0644
