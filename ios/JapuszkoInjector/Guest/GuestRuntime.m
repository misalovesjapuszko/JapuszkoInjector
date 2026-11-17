// Guest launcher for "Run inside".
//
// Based on LiveContainer's guest runtime approach:
// 1. Point HOME/CFFIXED_USER_HOME/TMPDIR at the guest's private data folder.
// 2. Overwrite NSBundle.mainBundle, CFBundleGetMainBundle, _CFGetProcessPath,
//    NSProcessInfo identity, and NSUserDefaults to point at the guest.
// 3. Bypass dyld library validation (when JIT is available) so dlopen
//    accepts the patched binary regardless of CMS signature format.
// 4. dlopen the guest executable (patched to a dylib by the Rust core).
// 5. Load the bundle so NIBs/storyboards/Info.plist are registered.
// 6. Find its LC_MAIN entry point and call it like dyld would.

#import "GuestRuntime.h"

#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <crt_externs.h>
#import <dlfcn.h>
#import <limits.h>
#import <mach-o/dyld.h>
#import <mach-o/dyld_images.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>
#import <unistd.h>

// Private CoreFoundation symbols for process identity overrides.
// _CFProcessPath returns a pointer to the internal storage that
// CoreFoundation reads when it needs the executable path.
// LiveContainer overwrites these via ARM64 instruction emulation of
// the ADRP+ADD/LDR sequence that _CFGetProcessPath uses internally;
// we take a simpler (less complete) approach and set the progname
// via __progname, which many system frameworks also respect.
extern const char *__progname;

// Not in the public SDK headers, but exported by libsystem.
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define JG_CS_OPS_STATUS 0
#define JG_CS_DEBUGGED 0x10000000

int jg_jit_enabled(void) {
    uint32_t flags = 0;
    if (csops(getpid(), JG_CS_OPS_STATUS, &flags, sizeof(flags)) != 0) return 0;
    return (flags & JG_CS_DEBUGGED) ? 1 : 0;
}

int jg_wait_for_jit(double seconds) {
    const useconds_t step = 100 * 1000;
    int tries = (int)(seconds * 10.0);
    for (int i = 0; i <= tries; i++) {
        if (jg_jit_enabled()) return 1;
        usleep(step);
    }
    return jg_jit_enabled();
}

// ---------------------------------------------------------------------------
// dyld library validation bypass (ported from LiveContainer).
//
// When JIT is active (CS_DEBUGGED), dyld validates every dlopen'd library via
// two fcntl commands:
//   - F_ADDFILESIGS_RETURN: register the code signature with the kernel
//   - F_CHECK_LV:           verify library validation (same team as host)
//
// We hook dyld's internal fcntl and mmap so that:
//   - F_ADDFILESIGS_RETURN always reports "covers everything"
//   - F_CHECK_LV always succeeds
//   - mmap with PROT_EXEC falls back to anonymous mapping + memcpy when
//     the kernel rejects the signed pages
//
// This requires JIT (writable + executable pages). Without JIT, we rely on
// the Rust core's CMS-based signing and give a clear error if it fails.
// On iOS 26+ the dyld bypass is not supported; JITLess signing is required.
// ---------------------------------------------------------------------------

#ifndef F_ADDFILESIGS_RETURN
#define F_ADDFILESIGS_RETURN 97
#endif
#ifndef F_CHECK_LV
#define F_CHECK_LV 98
#endif

typedef struct {
    off_t   fs_file_start;
    void   *fs_blob_start;
    size_t  fs_blob_size;
} jg_fsignatures_t;

// Raw mach_vm_protect kernel trap -- bypasses the userspace wrapper so we can
// change dyld page protection even when the pages are locked.
__attribute__((naked))
static kern_return_t jg_vm_protect(vm_map_t task __unused, vm_address_t addr __unused,
                                   vm_size_t size __unused, boolean_t set_max __unused,
                                   vm_prot_t prot __unused)
{
    __asm__(
        "mov x16, #-0xe\n"   // mach_vm_protect trap
        "svc #0x80\n"
        "ret\n"
    );
}

// Syscall instruction signatures found inside dyld's internal fcntl / mmap
// wrappers.  These are the ARM64 encoding of:
//   MOV X16, #<syscall_number>; SVC #0x80
static const uint8_t jg_fcntl_sig[] = {0x90, 0x0B, 0x80, 0xD2, 0x01, 0x10, 0x00, 0xD4};
static const uint8_t jg_mmap_sig[]  = {0xB0, 0x18, 0x80, 0xD2, 0x01, 0x10, 0x00, 0xD4};

// Private libc wrappers for the actual syscalls.
extern void *__mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset);
extern int   __fcntl(int fildes, int cmd, void *param);

static int (*jg_orig_fcntl)(int, int, void *);

/// Hook for dyld's internal fcntl: makes library validation always pass.
static int jg_hooked_fcntl(int fildes, int cmd, void *param) {
    if (cmd == F_ADDFILESIGS_RETURN) {
        // Let the kernel register what it can, then claim full coverage.
        jg_orig_fcntl(fildes, cmd, param);
        jg_fsignatures_t *fsig = (jg_fsignatures_t *)param;
        fsig->fs_file_start = 0xFFFFFFFF;
        return 0;
    }
    if (cmd == F_CHECK_LV) {
        // Skip library validation entirely.
        return 0;
    }
    return jg_orig_fcntl(fildes, cmd, param);
}

/// Hook for dyld's internal mmap: when the kernel rejects PROT_EXEC (code
/// signature invalid), fall back to mapping the file into anonymous memory
/// and flipping protection after the copy.
static void *jg_hooked_mmap(void *addr, size_t len, int prot, int flags,
                             int fd, off_t offset) {
    void *map = __mmap(addr, len, prot, flags, fd, offset);
    if (fd && (prot & PROT_EXEC) && map == MAP_FAILED) {
        // Map anonymously as R/W, copy from file, then set requested prot.
        map = __mmap(addr, len, PROT_READ | PROT_WRITE,
                     (flags | MAP_PRIVATE | MAP_ANON) & ~MAP_FIXED, 0, 0);
        if (map == MAP_FAILED) return map;
        void *file_map = __mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, offset);
        if (file_map == MAP_FAILED) { munmap(map, len); return MAP_FAILED; }
        memcpy(map, file_map, len);
        munmap(file_map, len);
        mprotect(map, len, prot);
    }
    return map;
}

/// Get dyld's image base address via task_info.
static void *jg_dyld_base(void) {
    struct task_dyld_info info;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    if (task_info(mach_task_self_, TASK_DYLD_INFO,
                  (task_info_t)&info, &count) != KERN_SUCCESS) {
        return NULL;
    }
    struct dyld_all_image_infos *all = (void *)(uintptr_t)info.all_image_info_addr;
    return (void *)all->dyldImageLoadAddress;
}

/// Search for a byte pattern inside the first 512 KB of a region.
static void *jg_search(const void *base, const uint8_t *sig, size_t siglen) {
    const uint8_t *p = (const uint8_t *)base;
    for (size_t i = 0; i < 0x80000; i += 4) {
        if (p[i] == sig[0] && memcmp(p + i, sig, siglen) == 0) {
            return (void *)(p + i);
        }
    }
    return NULL;
}

/// Write an ARM64 trampoline at `target` that branches to `hook`.
/// Overwrites 16 bytes: LDR X16, +8; BR X16; .quad hook_address
static bool jg_patch(void *target, void *hook) {
    uintptr_t page = (uintptr_t)target & ~(uintptr_t)0x3FFF; // 16 KB pages
    kern_return_t kr;

    // Make the page writable (use the raw trap — regular vm_protect may
    // fail on dyld pages even with CS_DEBUGGED).
    kr = jg_vm_protect(mach_task_self(), (vm_address_t)page, 0x4000,
                       false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[JGGuest] vm_protect(RW) failed on %p: %d", target, kr);
        return false;
    }

    uint32_t *code = (uint32_t *)target;
    code[0] = 0x58000050;              // LDR X16, [PC, #8]
    code[1] = 0xD61F0200;              // BR X16
    *(void **)(code + 2) = hook;       // 64-bit hook address

    // Flush instruction cache.
    __builtin___clear_cache(target, (char *)target + 16);

    // Restore executable permission.
    kr = jg_vm_protect(mach_task_self(), (vm_address_t)page, 0x4000,
                       false, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[JGGuest] vm_protect(RX) failed on %p: %d", target, kr);
        return false;
    }
    return true;
}

static bool jg_bypass_active = false;

/// Set up the dyld library validation bypass. Must be called with JIT active.
static void jg_bypass_dyld_validation(void) {
    if (jg_bypass_active) return;

    // Not supported on iOS 26+ (dyld 4 changed its internals; LiveContainer
    // also skips this path and requires JITLess signing).
    if (@available(iOS 26.0, *)) {
        NSLog(@"[JGGuest] dyld bypass skipped on iOS 26+ (requires JITLess signing)");
        return;
    }

    void *dyld = jg_dyld_base();
    if (!dyld) {
        NSLog(@"[JGGuest] could not find dyld base address");
        return;
    }
    NSLog(@"[JGGuest] dyld at %p, setting up library validation bypass", dyld);

    jg_orig_fcntl = __fcntl;

    void *fcntl_site = jg_search(dyld, jg_fcntl_sig, sizeof(jg_fcntl_sig));
    void *mmap_site  = jg_search(dyld, jg_mmap_sig,  sizeof(jg_mmap_sig));

    if (!fcntl_site || !mmap_site) {
        NSLog(@"[JGGuest] could not locate dyld fcntl/mmap (%p / %p)",
              fcntl_site, mmap_site);
        return;
    }

    bool ok = jg_patch(fcntl_site, jg_hooked_fcntl)
           && jg_patch(mmap_site,  jg_hooked_mmap);
    if (ok) {
        jg_bypass_active = true;
        NSLog(@"[JGGuest] dyld library validation bypass active");
    } else {
        NSLog(@"[JGGuest] dyld bypass patching failed");
    }
}

// ---------------------------------------------------------------------------

static NSBundle *jg_bundle;
static NSUserDefaults *jg_defaults;
static NSString *jg_data;
static NSString *jg_bundleId;

@interface NSBundle (JGGuest)
+ (NSBundle *)jg_mainBundle;
@end
@implementation NSBundle (JGGuest)
+ (NSBundle *)jg_mainBundle {
    // After the swap, calling jg_mainBundle reaches the original.
    return jg_bundle ?: [self jg_mainBundle];
}
@end

@interface NSUserDefaults (JGGuest)
+ (NSUserDefaults *)jg_standardUserDefaults;
@end
@implementation NSUserDefaults (JGGuest)
+ (NSUserDefaults *)jg_standardUserDefaults {
    return jg_defaults ?: [self jg_standardUserDefaults];
}
@end

@interface NSBundle (JGGuestId)
- (NSString *)jg_bundleIdentifier;
@end
@implementation NSBundle (JGGuestId)
- (NSString *)jg_bundleIdentifier {
    if (jg_bundleId && self == jg_bundle) return jg_bundleId;
    return [self jg_bundleIdentifier];
}
@end

@interface NSFileManager (JGGuest)
- (NSURL *)jg_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier;
@end
@implementation NSFileManager (JGGuest)
- (NSURL *)jg_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    if (!jg_data) { return [self jg_containerURLForSecurityApplicationGroupIdentifier:groupIdentifier]; }
    // Guests have no app groups of their own; give them a private folder so
    // code that expects one doesn't crash on nil.
    NSString *path = [[jg_data stringByAppendingPathComponent:@"AppGroups"] stringByAppendingPathComponent:groupIdentifier];
    [self createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return [NSURL fileURLWithPath:path isDirectory:YES];
}
@end

static void jg_swap_class(Class cls, SEL a, SEL b) {
    Method ma = class_getClassMethod(cls, a);
    Method mb = class_getClassMethod(cls, b);
    if (ma && mb) method_exchangeImplementations(ma, mb);
}

static void jg_swap_instance(Class cls, SEL a, SEL b) {
    Method ma = class_getInstanceMethod(cls, a);
    Method mb = class_getInstanceMethod(cls, b);
    if (ma && mb) method_exchangeImplementations(ma, mb);
}

static void jg_swap_all(void) {
    jg_swap_class([NSBundle class], @selector(mainBundle), @selector(jg_mainBundle));
    jg_swap_class([NSUserDefaults class], @selector(standardUserDefaults), @selector(jg_standardUserDefaults));
    jg_swap_instance([NSBundle class], @selector(bundleIdentifier), @selector(jg_bundleIdentifier));
    jg_swap_instance([NSFileManager class], @selector(containerURLForSecurityApplicationGroupIdentifier:),
                     @selector(jg_containerURLForSecurityApplicationGroupIdentifier:));
}

static char *jg_saved_home, *jg_saved_fixed, *jg_saved_tmp;

static char *jg_dup_env(const char *k) {
    const char *v = getenv(k);
    return v ? strdup(v) : NULL;
}

static void jg_restore_env(const char *k, char *v) {
    if (v) { setenv(k, v, 1); free(v); } else { unsetenv(k); }
}

static int jg_fail(char *err, int errLen, int code, NSString *msg) {
    if (err && errLen > 0) { snprintf(err, (size_t)errLen, "%s", msg.UTF8String ?: "unknown error"); }
    jg_swap_all();
    jg_bundle = nil;
    jg_defaults = nil;
    jg_data = nil;
    jg_bundleId = nil;
    jg_restore_env("HOME", jg_saved_home);
    jg_restore_env("CFFIXED_USER_HOME", jg_saved_fixed);
    jg_restore_env("TMPDIR", jg_saved_tmp);
    jg_saved_home = jg_saved_fixed = jg_saved_tmp = NULL;
    return code;
}

static const struct mach_header_64 *jg_find_image(const char *path) {
    char want[PATH_MAX];
    int have_real = (realpath(path, want) != NULL);
    if (!have_real) strlcpy(want, path, sizeof(want));

    const char *basename_want = strrchr(want, '/');
    basename_want = basename_want ? basename_want + 1 : want;

    const struct mach_header_64 *basename_match = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (strcmp(name, path) == 0) {
            return (const struct mach_header_64 *)_dyld_get_image_header(i);
        }
        char got[PATH_MAX];
        if (have_real && realpath(name, got) && strcmp(got, want) == 0) {
            return (const struct mach_header_64 *)_dyld_get_image_header(i);
        }
        if (!basename_match) {
            const char *bn = strrchr(name, '/');
            bn = bn ? bn + 1 : name;
            if (strcmp(bn, basename_want) == 0) {
                basename_match = (const struct mach_header_64 *)_dyld_get_image_header(i);
            }
        }
    }
    return basename_match;
}

static uint64_t jg_entry_offset(const struct mach_header_64 *mh) {
    const uint8_t *p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_MAIN) {
            return ((const struct entry_point_command *)lc)->entryoff;
        }
        p += lc->cmdsize;
    }
    return 0;
}

int jg_run_guest(const char *bundlePath, const char *execName, const char *dataPath,
                 const char *bundleId, char *err, int errLen) {
    NSString *execPath = nil;
    @autoreleasepool {
        NSString *data = @(dataPath);
        NSFileManager *fm = [NSFileManager defaultManager];
        // Create standard directory structure (matches LiveContainer).
        for (NSString *sub in @[ @"Documents", @"Library/Preferences", @"Library/Caches",
                                 @"Library/Cookies", @"Library/Application Support",
                                 @"SystemData", @"tmp" ]) {
            [fm createDirectoryAtPath:[data stringByAppendingPathComponent:sub]
          withIntermediateDirectories:YES attributes:nil error:nil];
        }

        jg_saved_home = jg_dup_env("HOME");
        jg_saved_fixed = jg_dup_env("CFFIXED_USER_HOME");
        jg_saved_tmp = jg_dup_env("TMPDIR");
        setenv("HOME", dataPath, 1);
        setenv("CFFIXED_USER_HOME", dataPath, 1);
        setenv("TMPDIR", [[data stringByAppendingPathComponent:@"tmp"] stringByAppendingString:@"/"].UTF8String, 1);

        jg_data = data;
        jg_bundleId = @(bundleId);
        jg_bundle = [NSBundle bundleWithPath:@(bundlePath)];
        jg_defaults = [[NSUserDefaults alloc] initWithSuiteName:@(bundleId)];
        jg_swap_all();
        if (!jg_bundle) {
            return jg_fail(err, errLen, -1, @"The guest bundle is missing. Re-add it.");
        }
        execPath = [@(bundlePath) stringByAppendingPathComponent:@(execName)];
    }

    const char *exec = strdup(execPath.UTF8String);
    if (access(exec, F_OK) != 0) {
        return jg_fail(err, errLen, -2,
                       [NSString stringWithFormat:@"Guest executable not found at %s. Try removing and re-adding the app.", exec]);
    }

    // --- Process identity overrides (like LiveContainer) ---
    // Set __progname so frameworks that read it (CFBundle internals, etc.)
    // see the guest's executable name instead of the host's.
    __progname = execName;

    // Override NSProcessInfo identity so the guest's Info.plist lookups,
    // process name queries, and argv[0] all reflect the guest app.
    NSProcessInfo.processInfo.processName =
        jg_bundle.infoDictionary[@"CFBundleExecutable"] ?: @(execName);
    @try {
        NSMutableArray *objcArgv = NSProcessInfo.processInfo.arguments.mutableCopy;
        if (objcArgv.count > 0) objcArgv[0] = @(exec);
        [NSProcessInfo.processInfo setValue:objcArgv forKey:@"arguments"];
    } @catch (NSException *e) {
        // Not fatal -- some iOS versions lock down KVC on NSProcessInfo.
    }

    // With JIT active, bypass dyld's library validation so dlopen accepts
    // our patched binary regardless of CMS signature format.  Without JIT,
    // we rely on the Rust core's certificate-based signing.
    if (jg_jit_enabled()) {
        jg_bypass_dyld_validation();
    }

    // Use RTLD_LAZY (like LiveContainer) so weakly-linked symbols resolve on
    // demand instead of failing at load time. RTLD_FIRST prevents the guest's
    // symbols from colliding with the host injector's symbols.
    void *handle = dlopen(exec, RTLD_LAZY | RTLD_GLOBAL | RTLD_FIRST);
    if (!handle) {
        const char *why = dlerror();
        NSString *detail = [NSString stringWithFormat:@"%s", why ?: "unknown"];
        NSString *hint = @"";
        if (detail && ([detail containsString:@"signature"] || [detail containsString:@"code sign"])) {
            if (jg_jit_enabled()) {
                hint = @" The dyld bypass could not intercept validation."
                        " Try removing and re-adding the app.";
            } else {
                hint = @" JIT is not active, so the library validation bypass"
                        " is unavailable.  Enable JIT (e.g. via StikDebug) or"
                        " re-sign in Settings → Signing → Re-sign Apps Inside"
                        " This App.";
            }
        } else if (detail && [detail containsString:@"not a mach-o"]) {
            hint = @" The app wasn't converted to a loadable library."
                    " Try removing and re-adding it.";
        }
        return jg_fail(err, errLen, -2,
                       [NSString stringWithFormat:@"Can't load: %@.%@", detail, hint]);
    }

    // Load the bundle so its NIBs, storyboards, and Info.plist entries are
    // registered with the system (LiveContainer does this after dlopen).
    NSError *loadError = nil;
    if (![jg_bundle loadAndReturnError:&loadError]) {
        // Not fatal -- some bundles (games, etc.) work fine without it.
        NSLog(@"[JGGuest] Bundle -load failed (continuing): %@", loadError.localizedDescription);
    }

    // Re-initialize NSUserDefaults so dynamic properties pick up the guest's
    // preferences domain (matches LiveContainer's post-load step).
    @try {
        [NSUserDefaults performSelector:@selector(initialize)];
    } @catch (NSException *e) { /* Not fatal. */ }

    const struct mach_header_64 *mh = jg_find_image(exec);
    if (!mh) return jg_fail(err, errLen, -3, @"Loaded, but couldn't find the image afterwards.");
    uint64_t entryoff = jg_entry_offset(mh);
    if (!entryoff) return jg_fail(err, errLen, -4, @"The guest has no entry point.");

    typedef int (*guest_main_t)(int, char **, char **, char **);
    guest_main_t guest_main = (guest_main_t)(uintptr_t)((const uint8_t *)mh + entryoff);

    int argc = *_NSGetArgc();
    char **argv = *_NSGetArgv();
    if (argc > 0) argv[0] = (char *)exec;
    int rc = guest_main(argc, argv, *_NSGetEnviron(), NULL);
    exit(rc);
}
