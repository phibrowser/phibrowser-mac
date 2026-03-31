// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

#import "PhiLogging.h"

// MARK: - Convenience Logging Functions

void AppLogUserAction(NSString *action, NSString *details) {
    if (!action) {
        AppLogWarn(@"AppLogUserAction called with nil action");
        return;
    }
    
    NSString *message;
    if (details && details.length > 0) {
        message = [NSString stringWithFormat:@"👤 %@ - %@", action, details];
    } else {
        message = [NSString stringWithFormat:@"👤 %@", action];
    }
    
    DDLogInfo(@"%@", message);
}

void AppLogNetwork(NSString *method, NSString *url, NSNumber *statusCode) {
    if (!method) {
        AppLogWarn(@"AppLogNetwork called with nil method");
        return;
    }
    if (!url) {
        AppLogWarn(@"AppLogNetwork called with nil url");
        return;
    }
    
    NSString *message;
    if (statusCode) {
        message = [NSString stringWithFormat:@"🌐 %@ %@ [%@]", method, url, statusCode];
    } else {
        message = [NSString stringWithFormat:@"🌐 %@ %@", method, url];
    }
    
    DDLogInfo(@"%@", message);
}

void AppLogPerformance(NSString *operation, NSTimeInterval duration) {
    if (!operation) {
        AppLogWarn(@"AppLogPerformance called with nil operation");
        return;
    }
    
    NSString *message = [NSString stringWithFormat:@"⏱️ %@ took %.3fs", operation, duration];
    DDLogInfo(@"%@", message);
}

void AppLogMemoryWarning(NSString *message) {
    NSString *logMessage;
    if (message && message.length > 0) {
        logMessage = [NSString stringWithFormat:@"🧠 %@", message];
    } else {
        logMessage = @"🧠 Memory warning received";
    }
    
    DDLogWarn(@"%@", logMessage);
}