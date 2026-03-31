// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Abstracts how a resolved value gets assigned to a target.
public protocol Key: Hashable {
    associatedtype Base
    associatedtype Value
    
    func set(_ base: Base, with value: Value)
}

// MARK: - ReferenceWritableKeyPath Extension

extension ReferenceWritableKeyPath: Key {
    public typealias Base = Root
    
    public func set(_ base: Base, with value: Value) {
        base[keyPath: self] = value
    }
}

// MARK: - OptionalReferenceWritableKeyPath

/// Handles optional intermediate targets such as `\.layer?.backgroundColor`.
struct OptionalReferenceWritableKeyPath<Base, Target, Value>: Key, Hashable {
    let targetKeyPath: KeyPath<Base, Target?>
    let writableKeyPath: ReferenceWritableKeyPath<Target, Value>
    
    init(_ targetKeyPath: KeyPath<Base, Target?>, _ writableKeyPath: ReferenceWritableKeyPath<Target, Value>) {
        self.targetKeyPath = targetKeyPath
        self.writableKeyPath = writableKeyPath
    }
    
    func set(_ base: Base, with value: Value) {
        let target = base[keyPath: targetKeyPath]
        target?[keyPath: writableKeyPath] = value
    }
}

// MARK: - StringKeyPath (for ObjC compatibility)

/// String-based key path wrapper for ObjC KVC access.
struct StringKeyPath<Base: NSObject>: Key, Hashable {
    typealias Value = Any
    let keyPath: String
    
    init(_ keyPath: String) {
        self.keyPath = keyPath
    }
    
    func set(_ base: Base, with value: Value) {
        base.setValue(value, forKeyPath: keyPath)
    }
}

// MARK: - VoidKey

/// Placeholder key used for pure subscriptions with no property assignment.
public final class VoidKey<Base: AnyObject>: NSObject, Key {
    public typealias Value = Void
    
    public func set(_ base: Base, with value: Void) {
        // Intentionally left blank.
    }
    
    override init() {
        super.init()
    }
}
