# PhiBrowser Logging System

This directory contains the logging infrastructure for the PhiBrowser project, supporting both Swift and Objective-C with unified log files and consistent formatting.

## Overview

The logging system is built on CocoaLumberjack and provides:
- Unified logging across Swift and Objective-C
- Consistent formatting with timestamps, log levels, and file information
- Automatic log file rotation and management
- Emoji-prefixed convenience functions for easy log categorization

## Files

- `Logging.swift` - Swift logging interface and setup
- `PhiLogFormatter.swift` - Custom log formatter used by both languages
- `PhiLogging.h` - Objective-C logging interface header
- `PhiLogging.m` - Objective-C logging implementation
- `PhiLoggingExample.h/.m` - Example usage demonstrations
- `README.md` - This documentation

## Swift Usage

```swift
import Foundation

// Basic logging
AppLogInfo("User logged in successfully")
AppLogError("Network connection failed")
AppLogWarn("Low memory condition")
AppLogDebug("Debug information")
AppLogVerbose("Detailed debugging info")

// Convenience functions
AppLogUserAction("Button Clicked", details: "Settings button")
AppLogNetwork("GET", url: "https://api.example.com", statusCode: 200)
AppLogPerformance("Database Query", duration: 0.045)
AppLogMemoryWarning("Custom memory warning")
```

## Objective-C Usage

```objc
#import "PhiLogging.h"

// Basic logging
AppLogInfo(@"User logged in successfully");
AppLogError(@"Network connection failed");
AppLogWarn(@"Low memory condition");
AppLogDebug(@"Debug information");
AppLogVerbose(@"Detailed debugging info");

// Convenience functions
AppLogUserAction(@"Button Clicked", @"Settings button");
AppLogNetwork(@"GET", @"https://api.example.com", @200);
AppLogPerformance(@"Database Query", 0.045);
AppLogMemoryWarning(@"Custom memory warning");
```

## Log Format

All logs use the PhiLogFormatter and appear in this format:

```
[2025-08-15 10:30:45.123] ℹ️I|* [T:1|main] FileName.swift:42 functionName() - Log message
```

Where:
- `[2025-08-15 10:30:45.123]` - Timestamp
- `ℹ️I|*` - Log level with emoji and severity indicator
- `[T:1|main]` - Thread information
- `FileName.swift:42 functionName()` - File, line, and function information
- `Log message` - The actual log message

## Log Levels

- **Error** (❌): Critical errors that need immediate attention
- **Warning** (⚠️): Potentially problematic situations
- **Info** (ℹ️): General application flow information
- **Debug** (🐛): Debugging information (filtered in release builds)
- **Verbose** (📝): Detailed debugging information (filtered in release builds)

## Convenience Function Prefixes

- **User Actions** (👤): User interactions and behaviors
- **Network** (🌐): HTTP requests and network operations
- **Performance** (⏱️): Timing and performance metrics
- **Memory** (🧠): Memory-related warnings and information

## Configuration

Logging is configured in `Logging.swift` with the `setupLogging()` function:

- **Debug builds**: All log levels to both console and file
- **Release builds**: Warning and error levels only
- **File rotation**: 24-hour rotation with 7-day retention
- **File size limit**: 5MB per log file
- **Log directory**: Application Support/[Bundle ID]/Logs

## Integration

Both Swift and Objective-C logging functions:
- Write to the same log files
- Use the same formatter (PhiLogFormatter)
- Share the same DDLog configuration
- Provide identical functionality and behavior

## Testing

The logging system includes comprehensive tests:
- `PhiLoggingTests.m` - Objective-C unit tests
- `LoggingIntegrationTests.swift` - Swift/Objective-C integration tests

Run tests to verify:
- All logging functions work correctly
- Swift and Objective-C logs appear in the same files
- Formatting is consistent between languages
- Log level filtering works properly
- Parameter validation handles edge cases

## Best Practices

1. **Use appropriate log levels**: Error for critical issues, Info for general flow, Debug for development
2. **Include context**: Add relevant parameters and state information
3. **Use convenience functions**: Leverage emoji prefixes for easy log categorization
4. **Handle nil parameters**: The system gracefully handles nil inputs
5. **Performance considerations**: Logging is optimized but avoid excessive verbose logging in tight loops

## Troubleshooting

If logs aren't appearing:
1. Ensure `setupLogging()` is called during app initialization
2. Check log level configuration for your build type
3. Verify log file permissions and directory access
4. Check console output for any CocoaLumberjack warnings