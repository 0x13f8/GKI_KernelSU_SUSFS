// DexProtector / AppGuard / vGuard Bypass Toolkit
// Author: CSI · Hacktivate Co., Ltd. (https://hacktivate.tech/) · Confidentiality: Internal
// Minimal survival probe: proves the VM is attached and the process stays alive
// past DexProtector's ~1s kill window. If the kernel veto works, "still alive"
// keeps printing; before the veto it died within ~1s of create_script.
Java.perform(function () {
  console.log("[+] attached — VM alive");
  var n = 0;
  Java.enumerateLoadedClasses({
    onMatch: function () { n++; },
    onComplete: function () { console.log("[+] loaded classes:", n); }
  });
});
// heartbeat: print once every 10s (keeps real elapsed seconds, less log spam)
var t0 = Date.now();
setInterval(function () { console.log("[+] still alive " + Math.round((Date.now() - t0) / 1000) + "s"); }, 10000);
