// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

#import "ChromiumLauncher.h"
#import <Cocoa/Cocoa.h>
#import "Phi-Swift.h"
#import "PhiLogging.h"
#import <dlfcn.h>

@interface ChromiumLauncher ()
@property (nonatomic, assign) void *chromiumHandle;
@property (nonatomic, assign) BOOL isChromiumInitialized;
- (void)appendLaunchCommandLineArgc:(int)launchArgc argv:(const char **)launchArgv toArguments:(NSMutableArray<NSString *> *)arguments;
@end

@implementation ChromiumLauncher

+ (instancetype)sharedInstance {
    static ChromiumLauncher *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[ChromiumLauncher alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.isChromiumInitialized = NO;
        self.chromiumHandle = NULL;
    }
    return self;
}

- (void)appendLaunchCommandLineArgc:(int)launchArgc argv:(const char **)launchArgv toArguments:(NSMutableArray<NSString *> *)arguments {
    if (launchArgc <= 1) {
        return;
    }
    if (launchArgv == NULL) {
        AppLogWarn(@"Missing argv while launchArgc is %d", launchArgc);
        return;
    }
    for (int i = 1; i < launchArgc; i++) {
        const char *bytes = launchArgv[i];
        if (bytes == NULL) {
            continue;
        }
        NSString *arg = [NSString stringWithUTF8String:bytes];
        if (arg == nil || ![arg hasPrefix:@"--"]) {
            AppLogWarn(@"Skipping argv[%d]: not valid", i);
            continue;
        }
        if ([arg hasPrefix:@"--remote-debugging-port"] ||
            [arg hasPrefix:@"--remote-debugging-pipe"]) {
            // A TCP/pipe DevTools endpoint would supplant the FD-injection
            // transport and silently break agent CDP access (see
            // AgentCDPListener); the app socket is the only supported CDP
            // surface.
            AppLogWarn(@"Dropping unsupported argument: %@", arg);
            continue;
        }
        if ([arg hasPrefix:@"--enable-automation"] ||
            [arg hasPrefix:@"--headless"]) {
            // Both switch Blink's AutomationControlled feature on, which makes
            // navigator.webdriver report true to every page the user visits —
            // a bot signal on their signed-in sessions that they never asked
            // for. Phi drives pages over the app socket and needs neither.
            AppLogWarn(@"Dropping automation argument: %@", arg);
            continue;
        }
        [arguments addObject:arg];
    }
}

- (BOOL)initializeChromiumWithLaunchArgc:(int)launchArgc launchArgv:(const char **)launchArgv {
    if (self.isChromiumInitialized) {
        AppLogWarn(@"Chromium is already initialized");
        return YES;
    }
    self.isChromiumInitialized = YES;
    @try {
        // Resolve the embedded Chromium framework from the app bundle.
        NSBundle *mainBundle = [NSBundle mainBundle];
        NSString *frameworksPath = [mainBundle pathForResource:@"Phi Framework" ofType:@"framework"];
        
        if (!frameworksPath) {
            // Fall back to the standard Frameworks directory layout.
            NSString *bundleFrameworksPath = [[mainBundle bundlePath] stringByAppendingPathComponent:@"Contents/Frameworks/Phi Framework.framework"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:bundleFrameworksPath]) {
                frameworksPath = bundleFrameworksPath;
                AppLogDebug(@"Found Phi framework in bundle Frameworks: %@", frameworksPath);
            } else {
                AppLogError(@"Could not find Phi framework in bundle");
                AppLogError(@"Expected path: %@", bundleFrameworksPath);
                return NO;
            }
        } else {
                AppLogError(@"Found Phi framework at: %@", frameworksPath);
        }
        
        // Load the framework dynamically so the app can fail gracefully when it is missing.
        NSString *chromiumLibPath = [frameworksPath stringByAppendingPathComponent:@"Phi Framework"];
        self.chromiumHandle = dlopen([chromiumLibPath UTF8String], RTLD_LAZY | RTLD_LOCAL);
        
        if (!self.chromiumHandle) {
            AppLogError(@"Failed to load Phi framework: %s", dlerror());
            return NO;
        }
        
        AppLogDebug(@"Phi framework loaded successfully");
        
        // Resolve and invoke `ChromeMain` from the embedded framework.
        typedef int (*ChromeMainFunc)(int argc, const char* argv[]);
        ChromeMainFunc chromeMain = (ChromeMainFunc)dlsym(self.chromiumHandle, "ChromeMain");
        
        if (chromeMain) {
            AppLogDebug(@"Found ChromeMain function, initializing on main thread");
            
            if ([NSThread isMainThread]) {
                AppLogDebug(@"Starting ChromeMain on main thread");
                NSString *applicationSupportDir = FileSystemUtils.applicationSupportDirctory;
                NSError *error = nil;
                [[NSFileManager defaultManager] createDirectoryAtPath:applicationSupportDir
                                          withIntermediateDirectories:YES
                                                           attributes:nil
                                                                error:&error];
                if (error) {
                    AppLogError(@"Failed to create user data dir: %@", error.localizedDescription);
                    return NO;
                }
                
                AppLogDebug(@"Created user data directory at: %@", applicationSupportDir);

                // Build the minimal Chromium argv for the embedded launch.
                NSMutableArray<NSString *> *arguments = [NSMutableArray array];
                [arguments addObject:@"Phi"];

#if DEBUG || NIGHTLY_BUILD
                [arguments addObject:@"--phi-ai-debug"];
                [arguments addObject:@"--phi-no-embed-extensions"];
#endif
#if DEBUG
                [arguments addObject:@"--no-sandbox"];
#endif

                // The retired PhiRemoteDebuggingPort default used to feed
                // --remote-debugging-port here, silently disabling the agent
                // CDP transport on every launch until the user deleted it.
                // The switch is no longer supported (launch arguments are
                // stripped too); purge stale copies of the default.
                [[NSUserDefaults standardUserDefaults]
                    removeObjectForKey:@"PhiRemoteDebuggingPort"];

                // Builds from that era also left a DevToolsActivePort file in
                // the profile. The FD-injection transport binds no port and
                // never rewrites it, so a leftover copy misdirects any tool
                // that looks there — it reports a port nothing listens on
                // instead of "Phi is not running". Purge stale copies.
                [[NSFileManager defaultManager]
                    removeItemAtPath:[applicationSupportDir
                        stringByAppendingPathComponent:@"DevToolsActivePort"]
                               error:nil];

                [self appendLaunchCommandLineArgc:launchArgc argv:launchArgv toArguments:arguments];

                int argc = (int)arguments.count;
                const char **argv = (const char **)malloc(sizeof(char *) * argc);
                for (int i = 0; i < argc; i++) {
                    argv[i] = [[arguments objectAtIndex:i] UTF8String];
                }
                AppLogDebug(@"Starting ChromeMain with %d arguments", argc);
                int result = chromeMain(argc, argv);
                AppLogDebug(@"ChromeMain exited with code: %d", result);
                
                self.isChromiumInitialized = YES;
                AppLogDebug(@"Chromium initialization started successfully");
                return YES;
            } else {
                AppLogDebug(@"Must call launchChromiumWithArgc from main thread");
                self.isChromiumInitialized = NO;
                return NO;
            }
        } else {
            AppLogDebug(@"ChromeMain function not found, framework loaded but cannot initialize");
            self.isChromiumInitialized = NO;
            return NO;
        }
        
    } @catch (NSException *exception) {
        AppLogError(@"Failed to initialize Phi framework: %@", exception.reason);
        if (self.chromiumHandle) {
            dlclose(self.chromiumHandle);
            self.chromiumHandle = NULL;
        }
        self.isChromiumInitialized = NO;
        return NO;
    }
}

- (void)launchChromiumWithArgc:(int)argc argv:(const char **)argv {
    self.bridge = [NSClassFromString(@"PhiChromiumBridge") sharedInstance];
    if ([self.bridge conformsToProtocol:@protocol(PhiChromiumBridgeProtocol)]) {
        self.bridge.delegate = [PhiChromiumCoordinator shared];
    }
    [self initializeChromiumWithLaunchArgc:argc launchArgv:argv];

}

@end
