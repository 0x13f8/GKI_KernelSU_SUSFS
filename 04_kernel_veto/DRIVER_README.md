# Module 04 · Driver — Building & Flashing the In-Tree `dexp_veto` SIGKILL Veto (Tier 4)

> **Confidentiality:** Internal · **Author:** CSI · **Company:** [Hacktivate Co., Ltd.](https://hacktivate.tech/)
> **Module:** `04_kernel_veto/` · **Scope:** build-prep only — nothing here touches your device or GitHub.

## Overview

A **built-in (not loadable) GKI kernel driver** that **vetoes SIGKILL to one app uid from any
sender**, defeating DexProtector's *external* anti-Frida watchdog. This is the kernel answer
to the dead end the lower tiers hit: `killnop` NOPs all in-process kill syscalls (4/4 on
playnet) but the app still dies → the killer is external/TEE-mediated, and only a veto at the
LSM hook `security_task_kill` stops it.

In-tree + `obj-y` via `CONFIG_DEXP_VETO=y` means **no loadable module → no
MODVERSIONS / CRC / vermagic problem** (the hurdle that blocked the earlier loadable-`.ko`
path, archived as `../Unused/dexp-signal-veto-lkm/`).

> **You run CI + flash.** This folder is build-prep only. The host-side runner/control surface
> is [`README.md`](README.md).

**Reference target:** `com.playnet.androidtv.ads` (uid **10293**). **Device:** Nothing Phone,
arm64, kernel `6.1.134-android14-11-...`, KernelSU-Next + SUSFS. Confirmed capable:
`KPROBES/KRETPROBES=y`, `KALLSYMS=y`, `MODULE_SIG_FORCE` off, `security_task_kill` in kallsyms,
`FUNCTION_ERROR_INJECTION` off (so we rewrite the kretprobe *return* value, not use kprobe
override).

---

## Files

```text
04_kernel_veto/
├── drivers/misc/dexp_veto/
│   ├── dexp_veto.c     # veto (kretprobe → -EPERM) + sysfs + phase-2 accessor
│   ├── Kconfig         # config DEXP_VETO (bool, depends on KRETPROBES && KALLSYMS)
│   └── Makefile        # obj-$(CONFIG_DEXP_VETO) += dexp_veto.o
├── fork-patch/
│   ├── inject.sh       # drops the driver into the CI-synced kernel/common tree
│   └── test_inject.sh  # smoke-test the tree surgery (idempotent)
├── README.md           # host runner + control surface
└── DRIVER_README.md    # this file
```

---

## How it works

- **Phase 1 (veto):** kretprobe on `security_task_kill(p, info, sig, cred)`. The entry handler
  flags the call when `sig == protect_sig (9)` and `uid(p) == target_uid`; the return handler
  forces the hook to return `-EPERM`, so the kernel denies the kill.
- **Control (sysfs):** `/sys/kernel/dexp_veto/`
  - `uid` — target app uid; `-1` disables (**default → inert until armed**).
  - `verbose` — `1` logs each vetoed kill (sender→target) to dmesg, `0` quiet.
  - `hide_uid` — phase-2 `/proc` frida-hider toggle (default `-1` off).
  - `hide_names` — comma-separated substrings to scrub (default `frida,gum,linjector`; add
    your patched agent's maps name, e.g. `frida,gum,linjector,sysmon`).
- **Phase 2 (`/proc` frida-hider):** when `hide_uid` is set, for that uid's own `/proc` reads
  the kernel hides the Frida footprint the native scanners look for:
  - `/proc/<pid>/status` **TracerPid → 0** (defeats the ptrace-attach tell)
  - `/proc/<pid>/maps` — **drops VMAs** whose file path matches any `hide_names` needle (the
    agent's memfd / `gum` region)
  - thread names (`/proc/<pid>/comm`, status `Name:`, stat) — **gum threads masked** to
    `Thread` via `proc_task_name`

  These are guarded source patches `inject.sh` adds to `fs/proc/{array.c,task_mmu.c}`. Because
  DexProtector scans `/proc` with **direct syscalls**, a userspace hook misses it but this
  kernel-side filter catches it anyway. Needed when the target reacts to Frida with a
  decrypt-refusal/crash (not just a kill) — the veto handles the kill, this blinds the detector.

> **Deliberately not scrubbed:** `/proc/<pid>/fd` (frida sockets) and `smaps`. Add them like
> the maps patch if a target proves to read them; and if a scanner fingerprints gum by
> byte-scanning its *own* memory (not `/proc`), hiding won't cover it — escalate to
> dumping+patching the native detector ([Module 05](../05_appguard_vguard_win/) shows how).
> <!-- ponytail: phase-2 = TracerPid + maps + thread-comm; fd/smaps deferred until a target needs them -->

---

## Fork integration (android14-6.1, Kleaf/Bazel)

The WildKernels CI does **not** build from a committed `common` tree — it `repo sync`s a fresh
GKI tree at build time into `$GITHUB_WORKSPACE/kernel/common`, then builds with
`tools/bazel build //common:kernel_aarch64/Image`. So the driver is **injected into the synced
tree during the run**, not committed into `common`.

**1. Commit this folder into your fork** of `WildKernels/GKI_KernelSU_SUSFS`, at repo root,
keeping the path so `fork-patch/inject.sh` exists in the repo.

**2. Add one step to `.github/workflows/build.yml`**, immediately **after** the
`Download Kernel Repository` step (the one with `uses: ./.github/actions/download-kernel`) and
before `Spoof /proc/config.gz With Stock Config`:

```yaml
      - name: Inject dexp_veto driver
        run: bash 04_kernel_veto/fork-patch/inject.sh "$GITHUB_WORKSPACE/kernel"
```

`inject.sh` is idempotent and:

- copies the driver to `kernel/common/drivers/misc/dexp_veto/`,
- appends `obj-$(CONFIG_DEXP_VETO) += dexp_veto/` to `drivers/misc/Makefile`,
- sources the Kconfig into `drivers/misc/Kconfig`,
- appends `CONFIG_DEXP_VETO=y` to `arch/arm64/configs/gki_defconfig`,
- best-effort adds the phase-2 TracerPid guard to `fs/proc/array.c` (skips with a warning if
  the anchor isn't found — **the veto still builds**).

No `BUILD.bazel` edit is needed: `//common:kernel_aarch64` already descends `drivers/misc/`,
and the build-kernel action sets `check_defconfig = "disabled"`, so the extra config line won't
trip the defconfig check.

---

## Build (CI)

Trigger the build on your fork (web **Actions → Build Kernels → Run workflow**, or CLI):

```bash
gh workflow run build.yml \
  -R YOUR_USER/GKI_KernelSU_SUSFS --ref main \
  -f kernel_build_version=6.1.x-android14 \
  -f os_patch_level=2025-05 \
  -f release_type=Action -f commit_mode=verified \
  -f root_flavor=KernelSU -f use_cache=false
```

Keep **SUSFS** and **NoMount** enabled (disabling them fails a later metadata step). Download
the `*-AnyKernel3` artifact when the run is green:

```bash
gh run download -R YOUR_USER/GKI_KernelSU_SUSFS <RUN_ID> -p '*-AnyKernel3' -D ./out
```

Sanity-check the config landed: the build log's generated `.config` should show
`CONFIG_DEXP_VETO=y`, and the inject-step log should print `phase 1 done`.

---

## Flash

Flash the AnyKernel3 zip the way you already flash KernelSU-Next kernels (adb-sideload in
recovery, or the KernelSU/APatch flash-from-app path). **Keep your current working AnyKernel3
zip for rollback** (see below). A green build does not guarantee boot — have a tested recovery
path ready.

---

## Use (arm → verify → disarm)

```bash
# confirm the app's uid (expect 10293)
adb shell su -c 'stat -c %u /data/data/com.playnet.androidtv.ads'

# ARM the veto
adb shell su -c 'echo 10293 > /sys/kernel/dexp_veto/uid'

# (optional) arm phase-2 /proc frida-hider for that uid (TracerPid + maps + thread names)
adb shell su -c 'echo 10293 > /sys/kernel/dexp_veto/hide_uid'
# if your frida agent is renamed in maps, add its name to the needle list:
adb shell su -c 'echo frida,gum,linjector,sysmon > /sys/kernel/dexp_veto/hide_names'

# launch playnet + attach frida as usual (killnop pre-NOP still recommended)...

# VERIFY the veto fired (sender→target lines)
adb shell su -c 'dmesg | grep dexp_veto'
#   dexp_veto: armed probe on security_task_kill; disarmed (uid=-1)...
#   dexp_veto: target_uid=10293 (armed)
#   dexp_veto: DENY sig 9 -> uid 10293 (comm '...' pid N) from pid M ('...')

# DISARM (runtime, reversible — no reflash)
adb shell su -c 'echo -1 > /sys/kernel/dexp_veto/uid'
adb shell su -c 'echo -1 > /sys/kernel/dexp_veto/hide_uid'
```

The `from pid M ('comm')` line finally **names the external killer** — the thing the
guardian-identification pass couldn't see without a kernel vantage point.

---

## Rollback

The veto is off by default and disarmed at runtime with `echo -1` above — no reflash needed to
neutralize it. To remove the driver entirely, **reflash your current `6.1.134-android14 /
2025-05` KernelSU-Next AnyKernel3 zip** (the one you saved before flashing this build). That
restores the stock-for-you kernel; `/sys/kernel/dexp_veto/` disappears.

---

## Limits (honest)

- Blunt by design: while armed, **nothing** can SIGKILL that uid via the LSM path — including
  you. Disarm when done.
- Covers signal-syscall kills (what the watchdog uses). Kernel-internal kills that skip the LSM
  hook (e.g. OOM reaper direct path) are not covered.
- SUSFS is complementary (hides detection surface); it is not a signal veto. This driver does
  not touch SUSFS and builds alongside it.
- Not built: the ptrace/anti-debug *attach* add-on. Only add it if, after flashing + arming,
  Frida still can't attach (i.e. the failure is attach-refusal, not a kill).

## See also

- [`README.md`](README.md) — the host runner (`run-with-kernel-veto.sh`) and auto-arm module.
- [`WALKTHROUGH.md`](WALKTHROUGH.md) — targeting a new app and triage.
- [Module 05 — Stacked RASP win](../05_appguard_vguard_win/) — uses this driver as the SIGKILL floor.
