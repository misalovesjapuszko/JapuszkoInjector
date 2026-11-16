#pragma once

/// Runs a guest app (already patched + signed by the core) inside this
/// process, before UIApplicationMain. Never returns on success: the guest's
/// own main() takes over and its return value ends the process.
/// On failure returns < 0, writes a message into `err`, and undoes every
/// change so the injector can start normally.
int jg_run_guest(const char *bundlePath,
                 const char *execName,
                 const char *dataPath,
                 const char *bundleId,
                 char *err,
                 int errLen);

/// 1 when this process has JIT (a debugger attached at some point, so the
/// kernel set CS_DEBUGGED and allows writable+executable memory).
int jg_jit_enabled(void);

/// Polls jg_jit_enabled() for up to `seconds`. Returns 1 once JIT is on.
int jg_wait_for_jit(double seconds);
