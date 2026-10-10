// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

#import "NativeMediaFakes.h"

@implementation FakeMediaControls {
  void (^_observer)(NSDictionary<NSString *, id> * _Nullable);
  void (^_stoppedObserver)(NSDictionary<NSString *, id> * _Nullable);
  NSMutableArray<NSDictionary<NSString *, id> *> *_recordedActions;
}
- (instancetype)init {
  if ((self = [super init])) {
    _recordedActions = [NSMutableArray array];
    _acceptsActions = YES;
  }
  return self;
}
- (NSArray<NSDictionary<NSString *, id> *> *)actions { return [_recordedActions copy]; }
- (BOOL)isObserving { return _observer != nil; }
- (void)startObserving:(void (^)(NSDictionary<NSString *, id> * _Nullable))observer {
  NSAssert(NSThread.isMainThread, @"Observation must start on the main thread");
  _startCount++;
  _observer = [observer copy];
  if (_rotateTokenOnStart && _snapshotValue) {
    NSMutableDictionary *value = [_snapshotValue mutableCopy];
    value[@"token"] = [NSString stringWithFormat:@"observation-%lu", (unsigned long)_startCount];
    _snapshotValue = value;
  }
  _observer(_snapshotValue);
}
- (void)stopObserving {
  NSAssert(NSThread.isMainThread, @"Observation must stop on the main thread");
  _stopCount++;
  _stoppedObserver = _observer;
  _observer = nil;
}
- (NSDictionary<NSString *, id> *)snapshot {
  NSAssert(NSThread.isMainThread, @"Snapshots must be read on the main thread");
  _snapshotCount++;
  return _observer ? _snapshotValue : nil;
}
- (BOOL)performAction:(PhiMediaControlAction)action expectedToken:(NSString *)token seconds:(double)seconds {
  NSAssert(NSThread.isMainThread, @"Actions must run on the main thread");
  [_recordedActions addObject:@{@"action": @(action), @"token": token, @"seconds": @(seconds)}];
  return _observer && _acceptsActions && [_snapshotValue[@"token"] isEqual:token];
}
- (BOOL)setVolume:(double)volume expectedToken:(NSString *)token {
  [_recordedActions addObject:@{@"volume": @(volume), @"token": token}];
  if (!_observer || !_acceptsActions || ![_snapshotValue[@"token"] isEqual:token]) return NO;
  NSMutableDictionary *value = [_snapshotValue mutableCopy];
  value[@"volume"] = @(volume);
  _snapshotValue = value;
  return YES;
}
- (void)emit:(NSDictionary<NSString *, id> *)value {
  _snapshotValue = [value copy];
  if (_observer) _observer(value);
}
- (void)emitStopped:(NSDictionary<NSString *, id> *)value {
  if (_stoppedObserver) _stoppedObserver(value);
}
@end

// Only the wrapper methods exercised by the production adapter/controller exist.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"
#pragma clang diagnostic ignored "-Wobjc-protocol-property-synthesis"
@implementation FakeWrapper
- (instancetype)init {
  if ((self = [super init])) _fakeControls = [[FakeMediaControls alloc] init];
  return self;
}
- (id<PhiMediaControls>)mediaControls { return _fakeControls; }
- (void)setAsActiveTab { _activationCount++; }
@end
@implementation LegacyWrapper
- (void)setAsActiveTab { _activationCount++; }
@end
#pragma clang diagnostic pop
