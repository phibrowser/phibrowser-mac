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

- (BOOL)initializeChromium {
    if (self.isChromiumInitialized) {
        AppLogWarn(@"Chromium is already initialized");
        return YES;
    }
    self.isChromiumInitialized = YES;
    @try {
        // Resolve the embedded Chromium framework from the app bundle.
        NSBundle *mainBundle = [NSBundle mainBundle];
        NSString *frameworksPath = [mainBundle pathForResource:@"Phi framework" ofType:@"framework"];
        
        if (!frameworksPath) {
            // Fall back to the standard Frameworks directory layout.
            NSString *bundleFrameworksPath = [[mainBundle bundlePath] stringByAppendingPathComponent:@"Contents/Frameworks/Phi framework.framework"];
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
        NSString *chromiumLibPath = [frameworksPath stringByAppendingPathComponent:@"Phi framework"];
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
#endif
#if DEBUG
                [arguments addObject:@"--no-sandbox"];
#endif

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
                AppLogDebug(@"Must call initializeChromium from main thread");
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

- (void)launchChromium {
    self.bridge = [NSClassFromString(@"PhiChromiumBridge") sharedInstance];
    if ([self.bridge conformsToProtocol:@protocol(PhiChromiumBridgeProtocol)]) {
        self.bridge.delegate = [PhiChromiumCoordinator shared];
    }
    [self initializeChromium];
   
}

@end
