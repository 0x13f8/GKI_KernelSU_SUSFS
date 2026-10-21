#!/usr/bin/env bash
# DexProtector / AppGuard / vGuard Bypass Toolkit
# Author: CSI · Hacktivate Co., Ltd. (https://hacktivate.tech/) · Confidentiality: Internal
# Zip the module into a flashable dexp_veto_autoarm.zip (install in KSU manager).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../dexp_veto_autoarm.zip"
cd "$HERE"
rm -f "$OUT"
zip -r "$OUT" module.prop service.sh customize.sh uids.txt webroot >/dev/null
echo "[+] built $OUT"
unzip -l "$OUT"
