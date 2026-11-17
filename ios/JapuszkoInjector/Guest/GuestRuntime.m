// Guest launcher for "Run inside".
//
// 1. Point HOME/CFFIXED_USER_HOME/TMPDIR at the guest's private data folder.
// 2. Make +[NSBundle mainBundle] return the guest bundle and
//    +[NSUserDefaults standardUserDefaults] a per-guest suite.
// 3. dlopen the guest executable (the core turned it into a dylib and signed
//    it with our own team cert, so library validation accepts it).
// 4. Find its LC_MAIN entry point and call it like dyld would.

#import "GuestRuntime.h"

#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <crt_externs.h>
#import <dlfcn.h>
#import <limits.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

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
        for (NSString *sub in @[ @"Documents", @"Library/Preferences", @"Library/Caches",
                                 @"Library/Application Support", @"tmp" ]) {
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
    void *handle = dlopen(exec, RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        const char *why = dlerror();
        NSString *detail = [NSString stringWithFormat:@"%s", why ?: "unknown"];
        NSString *hint = @"";
        if (detail && ([detail containsString:@"signature"] || [detail containsString:@"code sign"]))
            hint = @" Re-sign the app in Settings → Signing → Re-sign Apps Inside This App.";
        else if (detail && [detail containsString:@"not a mach-o"])
            hint = @" The app wasn't converted to a loadable library. Try removing and re-adding it.";
        return jg_fail(err, errLen, -2,
                       [NSString stringWithFormat:@"Can't load: %@.%@", detail, hint]);
    }
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
