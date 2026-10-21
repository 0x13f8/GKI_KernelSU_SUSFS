#!/usr/bin/env bash
# DexProtector / AppGuard / vGuard Bypass Toolkit
# Author: CSI · Hacktivate Co., Ltd. (https://hacktivate.tech/) · Confidentiality: Internal
# inject.sh — drop the dexp_veto in-tree driver into a freshly-synced GKI tree.
#
# The WildKernels CI (repo sync) lands the kernel at $GITHUB_WORKSPACE/kernel with
# the common tree at $GITHUB_WORKSPACE/kernel/common. Run this AFTER download-kernel
# and BEFORE build-kernel (see README "Fork integration"):
#
#   bash dexp-kernel-veto/fork-patch/inject.sh "$GITHUB_WORKSPACE/kernel"
#
# Idempotent. Phase 1 (driver + Kconfig/Makefile wiring + defconfig) is mandatory and
# fails loudly. Phase 2 (fs/proc frida-hiding: TracerPid in array.c, thread-name mask in
# proc_task_name, maps filter in task_mmu.c) is best-effort: if an anchor isn't found it
# warns and skips that piece, so the veto always builds.
set -euo pipefail

KROOT="${1:-${GITHUB_WORKSPACE:-}/kernel}"
COMMON="$KROOT/common"
SRC="$(cd "$(dirname "$0")/.." && pwd)/drivers/misc/dexp_veto"

[ -d "$COMMON/drivers/misc" ] || { echo "ERR: $COMMON/drivers/misc not found — is $KROOT the repo-synced kernel root?" >&2; exit 1; }
[ -f "$SRC/dexp_veto.c" ]     || { echo "ERR: driver source missing at $SRC" >&2; exit 1; }

echo "== dexp_veto inject: KROOT=$KROOT =="

# 1. driver files
install -d "$COMMON/drivers/misc/dexp_veto"
cp "$SRC/dexp_veto.c" "$SRC/Kconfig" "$SRC/Makefile" "$COMMON/drivers/misc/dexp_veto/"

# 2. wire into drivers/misc/{Kconfig,Makefile} (idempotent)
MK="$COMMON/drivers/misc/Makefile"
grep -q 'dexp_veto/' "$MK" || echo 'obj-$(CONFIG_DEXP_VETO) += dexp_veto/' >> "$MK"

KC="$COMMON/drivers/misc/Kconfig"
if ! grep -q 'drivers/misc/dexp_veto/Kconfig' "$KC"; then
	# insert the source line just before the closing endmenu
	awk '/^endmenu/ && !done { print "source \"drivers/misc/dexp_veto/Kconfig\""; done=1 } { print }' "$KC" > "$KC.tmp"
	mv "$KC.tmp" "$KC"
fi

# 3. defconfig: build it in
DEF="$COMMON/arch/arm64/configs/gki_defconfig"
[ -f "$DEF" ] || { echo "ERR: $DEF not found" >&2; exit 1; }
grep -q '^CONFIG_DEXP_VETO=y' "$DEF" || echo 'CONFIG_DEXP_VETO=y' >> "$DEF"

echo "== phase 1 done: driver + wiring + CONFIG_DEXP_VETO=y =="

# 4. phase 2 (best-effort): in fs/proc/array.c, (a) force TracerPid 0 for the hidden
#    uid, and (b) mask gum/frida thread names via proc_task_name (covers comm + the
#    status "Name:" + stat name in one place).
ARR="$COMMON/fs/proc/array.c"
if [ -f "$ARR" ] && ! grep -q 'dexp_veto_tracerpid_hidden' "$ARR"; then
	python3 - "$ARR" <<'PY' || echo "WARN: phase-2 array.c patch skipped (anchor not found); veto unaffected."
import sys
p = sys.argv[1]
s = open(p).read()
# forward-declare the accessors near the top includes
s = s.replace('#include <linux/proc_fs.h>',
              '#include <linux/proc_fs.h>\n'
              '#if IS_ENABLED(CONFIG_DEXP_VETO)\n'
              'bool dexp_veto_tracerpid_hidden(void);\n'
              'bool dexp_veto_hide_active(void);\n'
              'bool dexp_veto_match_hidden(const char *);\n'
              '#endif', 1)
# (a) zero tpid right before it is emitted  [REQUIRED anchor]
anchor = 'seq_put_decimal_ull(m, "\\nTracerPid:\\t", tpid);'
if anchor not in s:
    sys.exit(1)
s = s.replace(anchor,
              '#if IS_ENABLED(CONFIG_DEXP_VETO)\n'
              '\tif (dexp_veto_tracerpid_hidden())\n\t\ttpid = 0;\n'
              '#endif\n\t' + anchor, 1)
# (b) mask the thread name in proc_task_name  [OPTIONAL anchor]
for ca in ('__get_task_comm(tcomm, sizeof(tcomm), p);',
           'get_task_comm(tcomm, p);'):
    if ca in s:
        s = s.replace(ca, ca +
                      '\n#if IS_ENABLED(CONFIG_DEXP_VETO)\n'
                      '\tif (dexp_veto_hide_active() && dexp_veto_match_hidden(tcomm))\n'
                      '\t\tstrscpy(tcomm, "Thread", sizeof(tcomm));\n'
                      '#endif', 1)
        break
open(p, 'w').write(s)
PY
	grep -q 'dexp_veto_tracerpid_hidden' "$ARR" && echo "== phase 2 done: TracerPid + thread-name mask in fs/proc/array.c =="
else
	echo "== phase 2: already present or array.c absent — skipped =="
fi

# 5. phase 2b (best-effort): drop frida/gum/memfd VMAs from the hidden uid's own
#    /proc/<pid>/maps, so DexProtector's native maps scan can't find the agent.
#    ROBUST method: rewrite each `show_map_vma(m, X);` CALL into a guarded call. A call is
#    always a statement after all decls, so this never triggers -Werror=declaration-after-
#    statement, needs no new local declarations, and is independent of the function's
#    internal structure / kernel sublevel. Forward decls use _Bool (no <types.h> dep).
TMM="$COMMON/fs/proc/task_mmu.c"
if [ -f "$TMM" ] && ! grep -q 'dexp_veto_match_hidden' "$TMM"; then
	python3 - "$TMM" <<'PY' || echo "WARN: phase-2b maps patch skipped (anchor not found); veto unaffected."
import re, sys
p = sys.argv[1]
s = open(p).read()
# calls like `show_map_vma(m, vma);` (first arg literally m => a call, not the definition)
pat = re.compile(r'^([ \t]*)show_map_vma\s*\(\s*m\s*,\s*(\w+)\s*\)\s*;', re.M)
calls = list(pat.finditer(s))
if not calls:
    sys.exit(1)
inc = re.search(r'^#include[^\n]*\n', s, re.M)
if not inc:
    sys.exit(1)
def repl(ind, arg):
    c = '(struct vm_area_struct *)(%s)' % arg
    return ('#if IS_ENABLED(CONFIG_DEXP_VETO)\n'
            '%sif (!dexp_veto_hide_active() || !(%s) || !(%s)->vm_file ||\n'
            '%s    !dexp_veto_match_hidden((const char *)(%s)->vm_file->f_path.dentry->d_name.name))\n'
            '#endif\n'
            '%s\tshow_map_vma(m, %s);' % (ind, c, c, ind, c, ind, arg))
# right-to-left so earlier match offsets stay valid
for mt in reversed(calls):
    s = s[:mt.start()] + repl(mt.group(1), mt.group(2)) + s[mt.end():]
decl = ('#if IS_ENABLED(CONFIG_DEXP_VETO)\n'
        '_Bool dexp_veto_hide_active(void);\n'
        '_Bool dexp_veto_match_hidden(const char *);\n'
        '#endif\n')
s = s[:inc.end()] + decl + s[inc.end():]
open(p, 'w').write(s)
PY
	grep -q 'dexp_veto_match_hidden' "$TMM" && echo "== phase 2b done: maps frida-hide wired in fs/proc/task_mmu.c (show_map) =="
else
	echo "== phase 2b: already present or task_mmu.c absent — skipped =="
fi

echo "== dexp_veto inject complete =="
