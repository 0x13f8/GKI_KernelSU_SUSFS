#!/usr/bin/env bash
# DexProtector / AppGuard / vGuard Bypass Toolkit
# Author: CSI · Hacktivate Co., Ltd. (https://hacktivate.tech/) · Confidentiality: Internal
# Smoke test for inject.sh: fabricate a minimal GKI tree, inject, assert wiring.
# Run: bash dexp-kernel-veto/fork-patch/test_inject.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
C="$T/kernel/common"
mkdir -p "$C/drivers/misc" "$C/arch/arm64/configs" "$C/fs/proc"

printf 'menu "Misc devices"\nconfig FOO\n\tbool "foo"\nendmenu\n' > "$C/drivers/misc/Kconfig"
printf 'obj-$(CONFIG_FOO) += foo.o\n' > "$C/drivers/misc/Makefile"
printf 'CONFIG_KPROBES=y\nCONFIG_KALLSYMS=y\n' > "$C/arch/arm64/configs/gki_defconfig"
# array.c: TracerPid emit anchor + proc_task_name with comm fetch anchor
cat > "$C/fs/proc/array.c" <<'EOF'
#include <linux/proc_fs.h>
static void task_state(struct seq_file *m)
{
	int tpid = 42;
	seq_put_decimal_ull(m, "\nTracerPid:\t", tpid);
}
void proc_task_name(struct seq_file *m, struct task_struct *p, bool escape)
{
	char tcomm[64];
	__get_task_comm(tcomm, sizeof(tcomm), p);
	seq_puts(m, tcomm);
}
EOF
# task_mmu.c: realistic structure — show_map_vma (HAS local decls, must NOT be touched)
# and its caller show_map (no local decls; the guard goes here). Two-line signatures and
# no <linux/mm.h> include, to regress all three bugs hit on the real tree.
cat > "$C/fs/proc/task_mmu.c" <<'EOF'
#include <linux/pagewalk.h>
static void
show_map_vma(struct seq_file *m, struct vm_area_struct *vma)
{
	struct mm_struct *mm = vma->vm_mm;
	int x = 0;
	seq_printf(m, "%d", x);
}
static int show_map(struct seq_file *m, void *v)
{
	struct vm_area_struct *pad_vma = get_pad_vma(v);
	struct vm_area_struct *vma = v;
	if (pad_vma)
		show_map_vma(m, pad_vma);
	show_map_vma(m, vma);
	return 0;
}
EOF

bash "$HERE/inject.sh" "$T/kernel"   # run twice to prove idempotency
bash "$HERE/inject.sh" "$T/kernel"

fail=0
chk(){ if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi; }
chk "driver copied"       "[ -f '$C/drivers/misc/dexp_veto/dexp_veto.c' ]"
chk "Makefile wired once"  "[ \$(grep -c 'dexp_veto/' '$C/drivers/misc/Makefile') -eq 1 ]"
chk "Kconfig sourced once"  "[ \$(grep -c 'dexp_veto/Kconfig' '$C/drivers/misc/Kconfig') -eq 1 ]"
chk "Kconfig inside menu"  "grep -B1 '^endmenu' '$C/drivers/misc/Kconfig' | grep -q dexp_veto"
chk "defconfig set once"   "[ \$(grep -c '^CONFIG_DEXP_VETO=y' '$C/arch/arm64/configs/gki_defconfig') -eq 1 ]"
# array.c: TracerPid (decl + call = 2), thread-name mask, hide_active (decl + call = 2)
chk "tracerpid refs == 2"  "[ \$(grep -c 'dexp_veto_tracerpid_hidden' '$C/fs/proc/array.c') -eq 2 ]"
chk "tpid guard before emit" "awk '/tpid = 0;/{g=NR} /TracerPid/{e=NR} END{exit !(g&&e&&g<e)}' '$C/fs/proc/array.c'"
chk "comm mask once"       "[ \$(grep -c 'strscpy(tcomm, \"Thread\"' '$C/fs/proc/array.c') -eq 1 ]"
chk "hide_active refs == 2" "[ \$(grep -c 'dexp_veto_hide_active' '$C/fs/proc/array.c') -eq 2 ]"
# task_mmu.c: each show_map_vma(m, X) CALL rewritten into a guarded call. No new local
# decls, no body insertion → immune to decl-after-statement / blank-line placement.
chk "maps _Bool decls == 2"   "[ \$(grep -c '_Bool dexp_veto' '$C/fs/proc/task_mmu.c') -eq 2 ]"
chk "both calls preserved"     "[ \$(grep -c 'show_map_vma(m,' '$C/fs/proc/task_mmu.c') -eq 2 ]"
chk "hide_active refs == 3"    "[ \$(grep -c 'dexp_veto_hide_active' '$C/fs/proc/task_mmu.c') -eq 3 ]"
chk "match in 2 guards"        "[ \$(grep -c 'f_path.dentry->d_name.name' '$C/fs/proc/task_mmu.c') -eq 2 ]"
chk "no body-inserted decls"   "[ \$(grep -cE 'extern bool|_dxv' '$C/fs/proc/task_mmu.c') -eq 0 ]"
# show_map_vma DEFINITION must be untouched; two-line signature intact
chk "show_map_vma untouched"  "! awk '/show_map_vma\\(struct/{inv=1} /^}/{inv=0} inv && /dexp_veto/{bad=1} END{exit bad?0:1}' '$C/fs/proc/task_mmu.c'"
chk "static void unbroken"    "awk 'prev ~ /static void\$/ && /show_map_vma/{ok=1} {prev=\$0} END{exit !ok}' '$C/fs/proc/task_mmu.c'"
exit $fail
