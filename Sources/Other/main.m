// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

//  Main entry point for PhiBrowser application with Chromium integration

#import <Cocoa/Cocoa.h>
#import "PhiApplication.h"
#import "ChromiumLauncher.h"
#import "PhiLogging.h"
#import "Phi-Swift.h"

int main(int argc, const char * argv[]) {
    @try {
        AppLogInfo(@"PhiBrowser starting with main entry point...");
        AppLogInfo(@"Command line arguments: argc=%d", argc);
        
        for (int i = 0; i < argc; i++) {
            AppLogDebug(@"argv[%d]: %s", i, argv[i]);
        }
#if DEBUG
        if (EnvironmentChecker.isRunningPreview) {
            AppLogInfo(@"Running in Xcode Preview environment");
            [[NSThread currentThread] setName:@"main"];
            [PhiChromiumCoordinator.shared initApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
            return NSApplicationMain(argc, (const char **)argv);
        }
#endif
        
        ChromiumLauncher *launcher = [ChromiumLauncher sharedInstance];
        if (!launcher) {
            AppLogError(@"Failed to create ChromiumLauncher singleton");
            return 1;
        }
        
        AppLogInfo(@"ChromiumLauncher singleton created (Chromium will initialize after app launch)");
        [launcher launchChromium];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    } @catch (NSException *exception) {
        AppLogError(@"Exception in main: %@ - %@", exception.name, exception.reason);
        AppLogError(@"Exception callstack: %@", exception.callStackSymbols);
        return 1;
    }
}
