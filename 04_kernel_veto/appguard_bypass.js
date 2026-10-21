// DexProtector / AppGuard / vGuard Bypass Toolkit
// Author: CSI · Hacktivate Co., Ltd. (https://hacktivate.tech/) · Confidentiality: Internal
// AppGuard frida-reaction bypass — Java-side ATTEMPTS (kept for the record; INSUFFICIENT).
//
// Timeline of what we learned:
//  - v1 (block MainThreadStallMonitor + wrap LibApplication): froze at loading (over-broad).
//  - v2 (swallow the uncaught NoSuchMethodError, below): app LOADS the first page, but
//    swallowing the throw on the MAIN thread aborts the main-page navigation mid-callback.
//  - v3 (stub LibApplication.a to a benign return): FROZE — because a() is NOT a detection
//    method. It is DexProtector's native CALL-HIDING DISPATCHER (hundreds of overloads of
//    every type); the whole facial-liveness module is routed through a(int id, ...args).
//    Stubbing it stubs the entire module.
//
// CONCLUSION: the frida detection is inside the NATIVE dispatcher (one specific a(id,...)
// path throws when frida is present). It cannot be cleanly neutralised from Java. This
// target needs STEP 3 — RE AppGuard's facial-liveness native .so and patch/pass the
// detection (or hide frida from whatever vector that native code uses). See docs/HANDOFF
// and docs/FIELD_LOG. For the app's CODE/VALUES, the static dump (run.py) already succeeded.
//
// v2 is left active below only because it at least reaches the first screen under frida.

Java.perform(function () {
  var Thread = Java.use("java.lang.Thread");
  var orig = null;
  try { orig = Thread.getDefaultUncaughtExceptionHandler(); } catch (e) {}
  var EH = Java.registerClass({
    name: "csi.SwallowEH",
    implements: [Java.use("java.lang.Thread$UncaughtExceptionHandler")],
    methods: {
      uncaughtException: function (t, e) {
        var tn = "" + t.getName(), msg = "" + e;
        if (tn !== "main" && (tn.indexOf("SDKHealth") >= 0 || msg.indexOf("NoSuchMethodError") >= 0)) {
          console.log("[+] swallowed watchdog throw on '" + tn + "'"); return;
        }
        if (orig !== null) { try { orig.uncaughtException(t, e); } catch (x) {} }
      }
    }
  });
  Thread.setDefaultUncaughtExceptionHandler(EH.$new());
  console.log("[+] v2 swallower (watchdog threads only) — reaches first screen; main-page nav still gated by native check");
});
// heartbeat: print once every 10s (keeps real elapsed seconds, less log spam)
var t0 = Date.now();
setInterval(function () { console.log("[+] still alive " + Math.round((Date.now() - t0) / 1000) + "s"); }, 10000);
