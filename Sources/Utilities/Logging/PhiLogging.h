// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

//  Objective-C logging interface that integrates with the existing Swift CocoaLumberjack
//  logging system. This provides the same logging functionality as the Swift implementation
//  while writing to the same log files and using the same formatting.
//  Usage:
//    #import "PhiLogging.h"
//    // Basic logging
//    AppLogInfo(@"User logged in: %@", username);
//    AppLogError(@"Network error: %@", error.localizedDescription);
//    // Convenience functions
//    AppLogUserAction(@"Button Clicked", @"Settings button");
//    AppLogNetwork(@"GET", @"https://api.example.com", @200);
//    AppLogPerformance(@"Database Query", 0.045);

#ifndef PhiLogging_h
#define PhiLogging_h

#import <Foundation/Foundation.h>
#import <Phi-Swift.h>

// Set default log level for Objective-C (should match Swift DDDefaultLogLevel)
#ifdef DEBUG
    static const DDLogLevel ddLogLevel = DDLogLevelAll;
#else
    static const DDLogLevel ddLogLevel = DDLogLevelWarning;
#endif

/**
 * Basic logging macros that capture file, line, and function information automatically.
 * These macros provide the same interface as the Swift logging functions and integrate
 * seamlessly with the existing logging infrastructure.
 *
 * All logs are written to the same files as Swift logs and use the same PhiLogFormatter
 * for consistent formatting across both languages.
 */

/**
 * Log an informational message
 * @param format NSString format string, followed by format arguments
 * @discussion Use for general application flow information
 * Example: AppLogInfo(@"User %@ logged in successfully", username);
 */
#define AppLogInfo(format, ...) \
    DDLogInfo(format, ##__VA_ARGS__)

/**
 * Log an error message
 * @param format NSString format string, followed by format arguments
 * @discussion Use for error conditions that need attention
 * Example: AppLogError(@"Failed to save file: %@", error.localizedDescription);
 */
#define AppLogError(format, ...) \
    DDLogError(format, ##__VA_ARGS__)

/**
 * Log a warning message
 * @param format NSString format string, followed by format arguments
 * @discussion Use for potentially problematic situations
 * Example: AppLogWarn(@"Memory usage is high: %ld MB", memoryUsage);
 */
#define AppLogWarn(format, ...) \
    DDLogWarn(format, ##__VA_ARGS__)

/**
 * Log a debug message
 * @param format NSString format string, followed by format arguments
 * @discussion Use for debugging information (filtered out in release builds)
 * Example: AppLogDebug(@"Processing item %ld of %ld", current, total);
 */
#define AppLogDebug(format, ...) \
    DDLogDebug(format, ##__VA_ARGS__)

/**
 * Log a verbose message
 * @param format NSString format string, followed by format arguments
 * @discussion Use for detailed debugging information (filtered out in release builds)
 * Example: AppLogVerbose(@"Internal state: %@", internalState);
 */
#define AppLogVerbose(format, ...) \
    DDLogVerbose(format, ##__VA_ARGS__)

/**
 * Convenience logging functions for specific use cases.
 * These functions provide the same functionality as the Swift convenience functions
 * and include emoji prefixes for easy identification in log files.
 */

/**
 * Log a user action with optional details
 * @param action The action performed by the user (required)
 * @param details Optional additional details about the action (can be nil)
 * @discussion Logs with 👤 emoji prefix for easy identification
 * Example: AppLogUserAction(@"Button Clicked", @"Settings button in toolbar");
 */
void AppLogUserAction(NSString *action, NSString *details);

/**
 * Log a network request
 * @param method HTTP method (GET, POST, etc.) (required)
 * @param url The URL being requested (required)
 * @param statusCode HTTP status code (can be nil)
 * @discussion Logs with 🌐 emoji prefix for easy identification
 * Example: AppLogNetwork(@"GET", @"https://api.example.com/users", @200);
 */
void AppLogNetwork(NSString *method, NSString *url, NSNumber *statusCode);

/**
 * Log performance metrics
 * @param operation Description of the operation being measured (required)
 * @param duration Time taken for the operation in seconds
 * @discussion Logs with ⏱️ emoji prefix for easy identification
 * Example: AppLogPerformance(@"Database Query", 0.045);
 */
void AppLogPerformance(NSString *operation, NSTimeInterval duration);

/**
 * Log memory warning
 * @param message Optional custom message (can be nil for default message)
 * @discussion Logs with 🧠 emoji prefix for easy identification
 * Example: AppLogMemoryWarning(@"Custom memory warning message");
 */
void AppLogMemoryWarning(NSString *message);

#endif /* PhiLogging_h */
