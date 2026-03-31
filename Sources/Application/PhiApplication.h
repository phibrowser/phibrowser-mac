// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Chromium event handling hooks.
@protocol CrAppProtocol <NSObject>
- (BOOL)isHandlingSendEvent;
@end

@protocol CrAppControlProtocol <CrAppProtocol>
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent;
@end

@interface PhiApplication : NSApplication <CrAppControlProtocol>

@end

NS_ASSUME_NONNULL_END
