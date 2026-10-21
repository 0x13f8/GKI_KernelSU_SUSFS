#!/usr/bin/env bash
# DexProtector / AppGuard / vGuard Bypass Toolkit
# Author: CSI · Hacktivate Co., Ltd. (https://hacktivate.tech/) · Confidentiality: Internal
# run-with-kernel-veto.sh — friendly name for ./veto.sh (same subcommands & arguments).
#
# What it does: drive a DexProtector app under the in-kernel SIGKILL veto so Frida
# attaches and the app stays alive (stops external/system kills the lower rungs can't).
#
#   ./run-with-kernel-veto.sh run    <pkg> <script.js> [--killnop]
#   ./run-with-kernel-veto.sh arm    <pkg>
#   ./run-with-kernel-veto.sh disarm
#   ./run-with-kernel-veto.sh status
#   ./run-with-kernel-veto.sh log    [N]
#
# This is only a rename — the real logic lives in veto.sh, unchanged.
# ── toolkit banner (cosmetic) ──
if [ -t 1 ]; then _bc=$'\033[1;36m'; _dc=$'\033[2m'; _rc=$'\033[0m'; else _bc=''; _dc=''; _rc=''; fi
printf '%s\n' "${_bc}══════════════════════════════════════════════════${_rc}"
printf '%s\n' "${_bc}  DEXpro + AINU + VKey + AppGuard — Bypass Toolkit${_rc}"
printf '%s\n' "${_dc}  by CSI · Hacktivate · https://hacktivate.tech${_rc}"
printf '%s\n' "${_bc}══════════════════════════════════════════════════${_rc}"
unset _bc _dc _rc

exec "$(cd "$(dirname "$0")" && pwd)/veto.sh" "$@"
