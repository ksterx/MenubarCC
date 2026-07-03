// native_launcher.m — macOS 26+ compatible launcher for MenubarCC
//
// Replaces py2app's apptemplate stub.  Creates NSStatusItem natively
// (visible on macOS 26 Liquid Glass), then loads Python exactly as
// py2app would — reading PyRuntimeLocations / PyResourcePackages
// from Info.plist.
//
// Exports menubarcc_set_icon / menubarcc_set_menu so the Python side
// can mirror rumps' state onto the visible native item via ctypes.

#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include <locale.h>
#include <mach-o/dyld.h>
#include <sys/stat.h>

#pragma mark - Python typedefs

typedef void     (*Py_SetProgramNameFunc)(const wchar_t *);
typedef void     (*Py_InitializeFunc)(void);
typedef int      (*PyRun_SimpleFileFunc)(FILE *, const char *);
typedef void     (*Py_FinalizeFunc)(void);
typedef int      (*PySys_SetArgvFunc)(int, wchar_t **);
typedef wchar_t *(*Py_DecodeLocaleFunc)(const char *, size_t *);

#pragma mark - Native status item

static NSStatusItem *gStatusItem = nil;

__attribute__((visibility("default")))
void *menubarcc_get_status_item(void) {
    return (__bridge void *)gStatusItem;
}

__attribute__((visibility("default")))
void menubarcc_set_icon(const char *path, double pt_w, double pt_h) {
    if (!gStatusItem) return;
    NSString *nsPath = [NSString stringWithUTF8String:path];
    dispatch_block_t block = ^{
        NSImage *img = [[NSImage alloc] initWithContentsOfFile:nsPath];
        if (img) {
            [img setSize:NSMakeSize(pt_w, pt_h)];
            gStatusItem.button.image = img;
            gStatusItem.button.title = @"";
        }
    };
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

__attribute__((visibility("default")))
void menubarcc_set_menu(void *nsMenu) {
    if (!gStatusItem || !nsMenu) return;
    dispatch_block_t block = ^{
        gStatusItem.menu = (__bridge NSMenu *)nsMenu;
    };
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

#pragma mark - Helpers

static NSString *resolvePyRuntimePath(NSString *loc, NSBundle *bundle) {
    NSString *prefix = @"@executable_path/";
    if ([loc hasPrefix:prefix]) {
        NSString *rest = [loc substringFromIndex:prefix.length];
        NSString *execDir = [[bundle executablePath]
                              stringByDeletingLastPathComponent];
        return [execDir stringByAppendingPathComponent:rest];
    }
    return [loc stringByExpandingTildeInPath];
}

#pragma mark - main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSBundle *bundle = [NSBundle mainBundle];
        NSString *resourcePath = [bundle resourcePath];
        NSFileManager *fm = [NSFileManager defaultManager];

        // ── 1. Create native status item ─────────────────────────────
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

        gStatusItem = [[NSStatusBar systemStatusBar]
                       statusItemWithLength:NSVariableStatusItemLength];
        gStatusItem.button.title = @"🦀";
        NSLog(@"[MenubarCC] Native status item created");

        // ── 2. Clean Python environment ─────────────────────────────
        const char *cleanVars[] = {
            "PYTHONOPTIMIZE", "PYTHONDEBUG", "PYTHONDUMPREFS",
            "PYTHONMALLOCSTATS", "PYTHONIOENCODING", NULL
        };
        for (int i = 0; cleanVars[i]; i++) {
            if (getenv(cleanVars[i])) unsetenv(cleanVars[i]);
        }
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1);
        setenv("PYTHONUNBUFFERED", "1", 1);
        setenv("_PY2APP_LAUNCHED_", "1", 1);

        // ── 3. Set paths ────────────────────────────────────────────
        char execPath[PATH_MAX];
        uint32_t bufsize = PATH_MAX;
        if (_NSGetExecutablePath(execPath, &bufsize) == 0)
            setenv("EXECUTABLEPATH", execPath, 1);
        setenv("RESOURCEPATH", [resourcePath UTF8String], 1);
        setenv("ARGVZERO", argv[0], 1);
        if (getenv("PYOBJC_BUNDLE_ADDRESS"))
            unsetenv("PYOBJC_BUNDLE_ADDRESS");

        // ── 4. PYTHONPATH from PyResourcePackages ───────────────────
        NSMutableArray *pyPaths =
            [NSMutableArray arrayWithObject:resourcePath];
        NSArray *resPkgs = [bundle objectForInfoDictionaryKey:
                            @"PyResourcePackages"];
        if (resPkgs) {
            for (NSString *pkg in resPkgs) {
                NSString *full = [pkg isAbsolutePath]
                    ? pkg
                    : [resourcePath stringByAppendingPathComponent:pkg];
                [pyPaths addObject:full];
            }
        }
        setenv("PYTHONPATH",
               [[pyPaths componentsJoinedByString:@":"] UTF8String], 1);

        // ── 5. Find Python runtime from Info.plist ──────────────────
        NSArray *locations = [bundle objectForInfoDictionaryKey:
                              @"PyRuntimeLocations"];
        NSString *pyLibPath = nil;
        if (locations) {
            for (NSString *loc in locations) {
                NSString *resolved = resolvePyRuntimePath(loc, bundle);
                if ([fm fileExistsAtPath:resolved]) {
                    pyLibPath = resolved;
                    break;
                }
            }
        }
        if (!pyLibPath) {
            NSLog(@"[MenubarCC] Cannot find Python runtime from "
                  @"PyRuntimeLocations in Info.plist");
            return 1;
        }

        void *pyLib = dlopen([pyLibPath UTF8String], RTLD_LAZY);
        if (!pyLib) {
            NSLog(@"[MenubarCC] dlopen(%@) failed: %s",
                  pyLibPath, dlerror());
            return 1;
        }

        // ── 6. PYTHONHOME ───────────────────────────────────────────
        NSString *pyExecName = [bundle objectForInfoDictionaryKey:
                                @"PyExecutableName"] ?: @"python";
        NSString *pyInterp = [[[bundle executablePath]
                               stringByDeletingLastPathComponent]
                              stringByAppendingPathComponent:pyExecName];
        struct stat sb;
        if (lstat([pyInterp UTF8String], &sb) == 0 && !S_ISLNK(sb.st_mode))
            setenv("PYTHONHOME", [resourcePath UTF8String], 1);

        // ── 7. Locale for Python 3 ──────────────────────────────────
        char *savedLocale = setlocale(LC_ALL, NULL);
        if (savedLocale) savedLocale = strdup(savedLocale);
        setlocale(LC_ALL, "en_US.UTF-8");
        int hadLcCtype = (getenv("LC_CTYPE") != NULL);
        if (!hadLcCtype) setenv("LC_CTYPE", "en_US.UTF-8", 1);

        // ── 8. Load Python symbols and initialize ───────────────────
        Py_SetProgramNameFunc pySetProgramName =
            dlsym(pyLib, "Py_SetProgramName");
        Py_InitializeFunc pyInitialize =
            dlsym(pyLib, "Py_Initialize");
        PyRun_SimpleFileFunc pyRunSimpleFile =
            dlsym(pyLib, "PyRun_SimpleFile");
        Py_FinalizeFunc pyFinalize =
            dlsym(pyLib, "Py_Finalize");
        PySys_SetArgvFunc pySysSetArgv =
            dlsym(pyLib, "PySys_SetArgv");
        Py_DecodeLocaleFunc pyDecodeLocale =
            dlsym(pyLib, "Py_DecodeLocale");

        if (!pyInitialize || !pyRunSimpleFile) {
            NSLog(@"[MenubarCC] Missing required Python symbols");
            return 1;
        }

        if (pySetProgramName && pyDecodeLocale) {
            wchar_t *wName = pyDecodeLocale([pyInterp UTF8String], NULL);
            if (wName) pySetProgramName(wName);
        }

        pyInitialize();

        if (!hadLcCtype) unsetenv("LC_CTYPE");
        if (savedLocale) {
            setlocale(LC_CTYPE, savedLocale);
            free(savedLocale);
        }

        // ── 9. Find boot script ─────────────────────────────────────
        NSString *mainScript = nil;
        NSArray *mainNames = [bundle objectForInfoDictionaryKey:
                              @"PyMainFileNames"]
                             ?: @[@"__boot__", @"__main__",
                                  @"__realmain__", @"Main"];
        NSArray *exts = @[@"py", @"pyc", @"pyo"];
        for (NSString *name in mainNames) {
            for (NSString *ext in exts) {
                NSString *p = [bundle pathForResource:name ofType:ext];
                if (p) { mainScript = p; goto found; }
            }
        }
    found:
        if (!mainScript) {
            NSLog(@"[MenubarCC] No boot script found in %@", resourcePath);
            pyFinalize();
            return 1;
        }

        // ── 10. Set sys.argv and run ────────────────────────────────
        if (pySysSetArgv && pyDecodeLocale) {
            wchar_t **wargv =
                (wchar_t **)alloca((argc + 1) * sizeof(wchar_t *));
            wargv[0] = pyDecodeLocale([mainScript UTF8String], NULL);
            for (int i = 1; i < argc; i++)
                wargv[i] = pyDecodeLocale(argv[i], NULL);
            wargv[argc] = NULL;
            pySysSetArgv(argc, wargv);
        }

        FILE *f = fopen([mainScript UTF8String], "r");
        if (!f) {
            NSLog(@"[MenubarCC] Cannot open %@", mainScript);
            pyFinalize();
            return 1;
        }

        NSLog(@"[MenubarCC] Running %@", mainScript);
        int rval = pyRunSimpleFile(f, [mainScript UTF8String]);
        fclose(f);

        if (rval)
            NSLog(@"[MenubarCC] Script exited with error %d", rval);

        pyFinalize();
        return rval;
    }
}
