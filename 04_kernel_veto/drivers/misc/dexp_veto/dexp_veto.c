// SPDX-License-Identifier: GPL-2.0
/*
 * dexp_veto — in-tree (built-in) driver that VETOES SIGKILL to a chosen app uid,
 * regardless of who sends it. Tier-4 answer to DexProtector's anti-frida watchdog.
 *
 * Unlike an in-process seccomp filter (which only blocks kills made BY the
 * target's own threads), this stops an EXTERNAL guardian process SIGKILLing the
 * app, and it is live kernel-wide from early boot so it also covers
 * Application.onCreate time.
 *
 * Core mechanism (phase 1): a kretprobe on the LSM hook security_task_kill().
 * The entry handler records whether sig==target signal and the target task's uid
 * == target_uid; the return handler then forces the hook's return to -EPERM for
 * those calls, so the kernel denies delivery. We rewrite the RETURN value (not
 * use kprobe override) because this GKI build has CONFIG_FUNCTION_ERROR_INJECTION
 * off, so a plain kprobe cannot change the result. Logic is lifted from the
 * reference loadable module (dexp-signal-veto-lkm/dexp_veto.c).
 *
 * Control (phase 1): sysfs at /sys/kernel/dexp_veto/ — write `uid` to arm
 * (-1 = disabled, the default, so the driver is inert until armed), `verbose`
 * to toggle logging. Runtime-reversible, no module to load (built in with obj-y
 * via CONFIG_DEXP_VETO=y → no MODVERSIONS/CRC concerns).
 *
 * Phase 2 (optional, sysfs `hide_uid`): hides the single highest-value anti-debug
 * artifact — TracerPid in /proc/<pid>/status — by forcing it to 0 when the READER
 * is hide_uid. Implemented as a tiny guarded call from fs/proc/array.c task_state()
 * (see fork-patch/0001-proc-tracerpid-hide.patch); the accessor lives here so all
 * tunables stay in one place. See README "Phase 2" for what is deliberately NOT
 * scrubbed (maps/comm/fd/socket) and why.
 *
 * HONESTY: while armed, nothing (not even you) can SIGKILL that uid via the normal
 * LSM path. Disarm with `echo -1 > /sys/kernel/dexp_veto/uid` or reflash stock.
 * Kernel-internal kills that bypass the LSM hook (e.g. OOM reaper direct path) are
 * not covered, but the watchdog uses ordinary signal syscalls, which DO pass
 * through security_task_kill.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/kprobes.h>
#include <linux/sched.h>
#include <linux/cred.h>
#include <linux/uidgid.h>
#include <linux/ptrace.h>
#include <linux/err.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>
#include <linux/string.h>

/* -1 = disabled. Armed at runtime via sysfs; inert until then. */
static int target_uid = -1;
static int protect_sig = 9;   /* SIGKILL */
static int verbose = 1;
static int hide_uid = -1;     /* phase 2: -1 = off */

/* phase 2b: comma-separated substrings to scrub from the hidden uid's own /proc
 * reads (maps file paths + thread comm). Set via sysfs. Defaults = common frida
 * tells; add your patched agent's maps name (e.g. "sysmon") if you renamed it. */
#define HIDE_NAMES_MAX 256
static char hide_names[HIDE_NAMES_MAX] = "frida,gum,linjector";

/* ---- phase 2 accessors, called from the guarded fs/proc patches ----
 * hide_active(): the CURRENT reader is the hidden uid (app reading its own /proc).
 * match_hidden(): does s contain any comma-separated needle from hide_names. */
bool dexp_veto_hide_active(void)
{
	return hide_uid >= 0 && (int)__kuid_val(current_uid()) == hide_uid;
}
EXPORT_SYMBOL(dexp_veto_hide_active);

bool dexp_veto_match_hidden(const char *s)
{
	const char *p = hide_names;
	char needle[64];

	if (!s || !*s)
		return false;
	while (*p) {
		int i = 0;

		while (*p && *p != ',' && i < (int)sizeof(needle) - 1)
			needle[i++] = *p++;
		needle[i] = '\0';
		while (*p && *p != ',')   /* skip tail of an over-long needle */
			p++;
		if (*p == ',')
			p++;
		if (i > 0 && strstr(s, needle))
			return true;
	}
	return false;
}
EXPORT_SYMBOL(dexp_veto_match_hidden);

/* TracerPid spoof (fs/proc/array.c) reuses the same gate. */
bool dexp_veto_tracerpid_hidden(void)
{
	return dexp_veto_hide_active();
}
EXPORT_SYMBOL(dexp_veto_tracerpid_hidden);

/* ---- phase 1: SIGKILL veto via kretprobe on security_task_kill ---- */
struct veto_data { int deny; };

/* security_task_kill(struct task_struct *p, struct kernel_siginfo *info,
 *                    int sig, const struct cred *cred)
 * arm64 arg regs: x0=p, x2=sig. */
static int veto_entry(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct veto_data *d = (struct veto_data *)ri->data;
	struct task_struct *p =
		(struct task_struct *)regs_get_kernel_argument(regs, 0);
	int sig = (int)regs_get_kernel_argument(regs, 2);

	d->deny = 0;
	if (target_uid >= 0 && sig == protect_sig && p) {
		kuid_t uid;

		rcu_read_lock();
		uid = task_uid(p);
		rcu_read_unlock();
		if ((int)__kuid_val(uid) == target_uid) {
			d->deny = 1;
			if (verbose)
				pr_info("dexp_veto: DENY sig %d -> uid %d (comm '%s' pid %d) from pid %d ('%s')\n",
					sig, target_uid, p->comm, p->pid,
					current->pid, current->comm);
		}
	}
	return 0;
}

static int veto_ret(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct veto_data *d = (struct veto_data *)ri->data;

	if (d->deny)
		regs_set_return_value(regs, (unsigned long)(-EPERM));
	return 0;
}

static struct kretprobe krp = {
	.handler	= veto_ret,
	.entry_handler	= veto_entry,
	.data_size	= sizeof(struct veto_data),
	.maxactive	= 64,
	.kp.symbol_name	= "security_task_kill",
};

/* ---- sysfs: /sys/kernel/dexp_veto/{uid,verbose,hide_uid} ---- */
static ssize_t uid_show(struct kobject *k, struct kobj_attribute *a, char *buf)
{ return sysfs_emit(buf, "%d\n", target_uid); }
static ssize_t uid_store(struct kobject *k, struct kobj_attribute *a,
			 const char *buf, size_t n)
{
	int v;
	if (kstrtoint(buf, 10, &v))
		return -EINVAL;
	target_uid = v;
	pr_info("dexp_veto: target_uid=%d (%s)\n", v, v < 0 ? "disarmed" : "armed");
	return n;
}
static ssize_t verbose_show(struct kobject *k, struct kobj_attribute *a, char *buf)
{ return sysfs_emit(buf, "%d\n", verbose); }
static ssize_t verbose_store(struct kobject *k, struct kobj_attribute *a,
			     const char *buf, size_t n)
{
	int v;
	if (kstrtoint(buf, 10, &v))
		return -EINVAL;
	verbose = !!v;
	return n;
}
static ssize_t hide_uid_show(struct kobject *k, struct kobj_attribute *a, char *buf)
{ return sysfs_emit(buf, "%d\n", hide_uid); }
static ssize_t hide_uid_store(struct kobject *k, struct kobj_attribute *a,
			      const char *buf, size_t n)
{
	int v;
	if (kstrtoint(buf, 10, &v))
		return -EINVAL;
	hide_uid = v;
	pr_info("dexp_veto: hide_uid=%d (/proc frida-hide %s)\n",
		v, v < 0 ? "off" : "on");
	return n;
}
static ssize_t hide_names_show(struct kobject *k, struct kobj_attribute *a, char *buf)
{ return sysfs_emit(buf, "%s\n", hide_names); }
static ssize_t hide_names_store(struct kobject *k, struct kobj_attribute *a,
				const char *buf, size_t n)
{
	size_t len = n;

	if (len >= HIDE_NAMES_MAX)
		len = HIDE_NAMES_MAX - 1;
	memcpy(hide_names, buf, len);
	if (len > 0 && hide_names[len - 1] == '\n')   /* strip trailing newline */
		len--;
	hide_names[len] = '\0';
	return n;   /* ponytail: no lock — config set once by admin; a torn read at most misses one pass */
}

static struct kobj_attribute uid_attr       = __ATTR(uid, 0644, uid_show, uid_store);
static struct kobj_attribute verbose_attr   = __ATTR(verbose, 0644, verbose_show, verbose_store);
static struct kobj_attribute hide_uid_attr  = __ATTR(hide_uid, 0644, hide_uid_show, hide_uid_store);
static struct kobj_attribute hide_names_attr = __ATTR(hide_names, 0644, hide_names_show, hide_names_store);

static struct attribute *dexp_attrs[] = {
	&uid_attr.attr, &verbose_attr.attr, &hide_uid_attr.attr,
	&hide_names_attr.attr, NULL,
};
static const struct attribute_group dexp_group = { .attrs = dexp_attrs };
static struct kobject *dexp_kobj;

static int __init dexp_veto_init(void)
{
	int ret = register_kretprobe(&krp);
	if (ret < 0) {
		pr_err("dexp_veto: register_kretprobe(security_task_kill) failed: %d\n", ret);
		return ret;
	}

	dexp_kobj = kobject_create_and_add("dexp_veto", kernel_kobj);
	if (!dexp_kobj) {
		unregister_kretprobe(&krp);
		return -ENOMEM;
	}
	ret = sysfs_create_group(dexp_kobj, &dexp_group);
	if (ret) {
		kobject_put(dexp_kobj);
		unregister_kretprobe(&krp);
		return ret;
	}

	pr_info("dexp_veto: Hacktivate-CSI build — armed probe on %s; disarmed (uid=-1). Set /sys/kernel/dexp_veto/uid to arm.\n",
		krp.kp.symbol_name);
	return 0;
}

/* Built-in; no module_exit path normally runs. Kept for completeness. */
device_initcall(dexp_veto_init);
