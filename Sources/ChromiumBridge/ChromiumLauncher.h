// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "PhiChromiumBridgeHeader.h"
NS_ASSUME_NONNULL_BEGIN
@interface ChromiumLauncher : NSObject
@property (nonatomic, strong, nullable) id<PhiChromiumBridgeProtocol> bridge;
+(instancetype)sharedInstance;

-(void)launchChromium;

@end

NS_ASSUME_NONNULL_END
