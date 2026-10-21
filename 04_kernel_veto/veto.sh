#!/usr/bin/env bash
# DexProtector / AppGuard / vGuard Bypass Toolkit
# Author: CSI · Hacktivate Co., Ltd. (https://hacktivate.tech/) · Confidentiality: Internal
# veto.sh — drive any DexProtector app under the in-kernel dexp_veto SIGKILL-veto.
# The veto neutralises DP's anti-frida watchdog kill (in-process AND external), so
# frida attaches and the app stays alive. This is the kit.sh of the kernel-veto path.
#
# Prereqs: a kernel with CONFIG_DEXP_VETO=y flashed (node /sys/kernel/dexp_veto),
# and a (footprint-patched) frida-server on the device.
#
# Usage:
#   ./veto.sh run    <pkg> <script.js> [--killnop]   # arm -> launch -> frida-server -> attach
#   ./veto.sh arm    <pkg>                            # just arm the veto for <pkg>'s uid
#   ./veto.sh disarm                                  # echo -1
#   ./veto.sh status                                  # show uid/verbose
#   ./veto.sh log    [N]                              # dmesg DENY lines (who's killing)
#
# Env (override as needed):
#   SER=<serial>          adb device serial (default: adb's only device)
#   SRV=<path>            device frida-server (default /data/local/tmp/.sysd2)
#   PORT=<port>           frida-server port (default 27042)
#   PYENV_VERSION=<env>   host frida client env to match the server (e.g. frida17)
#   KILLNOP=<path>        killnop binary for --killnop (default ../../killnop-toolkit/bin/killnop.arm64)
set -euo pipefail

NODE=/sys/kernel/dexp_veto
SRV="${SRV:-/data/local/tmp/.sysd2}"
PORT="${PORT:-27042}"
SER="${SER:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
KILLNOP="${KILLNOP:-$HERE/../02_watchdog_killnop/bin/killnop.arm64}"

adbx(){ if [ -n "$SER" ]; then adb -s "$SER" "$@"; else adb "$@"; fi; }
# Run ONE command string as full root. `su 0 -c "..."` is the context that can write
# the sysfs node on this device — plain `su -c` fails the redirect. $1 must not contain ".
dsu(){ adbx shell "su 0 -c \"$1\""; }
trim(){ tr -d '\r' | head -1; }

need_node(){ dsu "test -d $NODE && echo ok" | trim | grep -q ok || {
	echo "[x] $NODE not found — is the CONFIG_DEXP_VETO kernel flashed?"; exit 1; }; }

uid_of(){ dsu "stat -c %u /data/data/$1" | trim; }

cmd_arm(){
	local pkg="${1:?need <pkg>}" uid
	need_node
	uid="$(uid_of "$pkg")"
	[ -n "$uid" ] && [ "$uid" != "" ] || { echo "[x] no uid for $pkg (installed?)"; exit 1; }
	dsu "echo $uid > $NODE/uid; echo 1 > $NODE/verbose" >/dev/null
	echo "[+] armed uid=$uid ($pkg), verbose on"
}
cmd_disarm(){ need_node; dsu "echo -1 > $NODE/uid" >/dev/null; echo "[+] disarmed (uid=-1)"; }
cmd_status(){ need_node; echo "uid=$(dsu "cat $NODE/uid" | trim)  verbose=$(dsu "cat $NODE/verbose" | trim)  hide_uid=$(dsu "cat $NODE/hide_uid" | trim)"; }
cmd_log(){ dsu "dmesg | grep dexp_veto | tail -${1:-20}"; }

start_server(){
	local name; name="$(basename "$SRV")"
	if [ -z "$(dsu "pidof $name" | trim)" ]; then
		echo "[*] starting frida-server: $SRV -l 127.0.0.1:$PORT"
		dsu "setsid $SRV -l 127.0.0.1:$PORT </dev/null >/data/local/tmp/srv.log 2>&1 &" >/dev/null || true
		for _ in 1 2 3 4 5; do sleep 1; [ -n "$(dsu "pidof $name" | trim)" ] && break; done
	fi
	[ -n "$(dsu "pidof $name" | trim)" ] || { echo "[x] frida-server not up — check: adb shell su 0 -c 'cat /data/local/tmp/srv.log'"; exit 1; }
	echo "[+] frida-server up (pid=$(dsu "pidof $name" | trim))"
}

# Resolve the MAIN app pid. pidof prints every process pid on ONE space-separated line;
# a DP app often runs several (main + :sub + isolated). Prefer the process whose
# /proc/<pid>/cmdline == the package (the main process that hosts the app classes);
# fall back to the first pid. Honour a PID=<n> env override. Prints one pid.
resolve_pid(){
	local pkg="$1" pids p cmd
	[ -n "${PID:-}" ] && { echo "$PID"; return 0; }
	pids="$(dsu "pidof $pkg" | tr -d '\r')"
	[ -n "$pids" ] || return 1
	for p in $pids; do
		cmd="$(dsu "cat /proc/$p/cmdline" | tr -d '\000\r')"
		[ "$cmd" = "$pkg" ] && { echo "$p"; return 0; }
	done
	echo "${pids%% *}"   # fallback: first pid (strip at first space)
}

do_killnop(){
	local pid="$1"
	[ -x "$KILLNOP" ] || { echo "[!] --killnop: binary not found at $KILLNOP (skipping)"; return 0; }
	echo "[*] killnop: pushing + NOPing in-proc kill sites on pid $pid"
	adbx push "$KILLNOP" /data/local/tmp/killnop >/dev/null
	dsu "chmod 755 /data/local/tmp/killnop" >/dev/null
	dsu "/data/local/tmp/killnop $pid" || echo "[!] killnop found no sites yet (payload timing) — veto still covers the kill"
}

cmd_run(){
	local pkg="${1:?need <pkg>}" script="${2:?need <script.js>}" kn="${3:-}"
	[ -f "$script" ] || { echo "[x] script not found: $script"; exit 1; }
	cmd_arm "$pkg"
	echo "[*] launching $pkg"
	dsu "monkey -p $pkg -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1" >/dev/null || true
	sleep 1
	local allpids pid; allpids="$(dsu "pidof $pkg" | tr -d '\r')"
	[ -n "$allpids" ] || { echo "[x] $pkg did not start (root/tamper gate? launch it manually, then: ./veto.sh run again)"; exit 1; }
	pid="$(resolve_pid "$pkg")"
	[ "$allpids" != "$pid" ] && echo "[i] processes: $allpids — attaching main pid $pid (override with PID=<n>)"
	echo "[+] pid=$pid"
	[ "$kn" = "--killnop" ] && do_killnop "$pid"
	start_server
	[ -n "${PYENV_VERSION:-}" ] && export PYENV_VERSION
	echo "[*] attaching frida (Ctrl-C to detach). If it SURVIVES past ~2s, the veto works."
	exec frida -U -p "$pid" -l "$script"
}

case "${1:-}" in
	run)    shift; cmd_run "$@";;
	arm)    shift; cmd_arm "$@";;
	disarm) cmd_disarm;;
	status) cmd_status;;
	log)    shift; cmd_log "${1:-20}";;
	*) sed -n '2,22p' "$0"; exit 2;;
esac
