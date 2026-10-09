// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

#import "PhiChromiumBridgeHeader.h"

NS_ASSUME_NONNULL_BEGIN
@interface FakeMediaControls : NSObject <PhiMediaControls>
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> *snapshotValue;
@property(nonatomic, readonly) NSUInteger startCount;
@property(nonatomic, readonly) NSUInteger stopCount;
@property(nonatomic, readonly) NSUInteger snapshotCount;
@property(nonatomic, readonly) BOOL isObserving;
@property(nonatomic, readonly) NSArray<NSDictionary<NSString *, id> *> *actions;
@property(nonatomic) BOOL acceptsActions;
@property(nonatomic) BOOL rotateTokenOnStart;
- (void)emit:(nullable NSDictionary<NSString *, id> *)value;
- (void)emitStopped:(nullable NSDictionary<NSString *, id> *)value;
@end

@interface FakeWrapper : NSObject <WebContentWrapper>
@property(nonatomic, strong, readonly) FakeMediaControls *fakeControls;
@property(nonatomic, readonly) NSUInteger activationCount;
@end

// Deliberately omits mediaControls to model an older installed framework.
@interface LegacyWrapper : NSObject <WebContentWrapper>
@property(nonatomic, readonly) NSUInteger activationCount;
@end
NS_ASSUME_NONNULL_END
