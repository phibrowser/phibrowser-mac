// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

private var phiObserverKey = "phiThemeObserverKey"

/// Theme-aware property binder.
@dynamicMemberLookup
public struct Phi<Base: AnyObject> {
    let base: Base
    let source: ThemeSource
    
    init(_ base: Base, _ source: ThemeSource) {
        self.base = base
        self.source = source
    }
    
    // MARK: - Bags Management
    
    fileprivate var bags: Bags {
        if let oldValue = objc_getAssociatedObject(base, &phiObserverKey) as? Bags {
            return oldValue
        }
        let newValue = Bags()
        objc_setAssociatedObject(base, &phiObserverKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return newValue
    }
    
    // MARK: - Value Setting
    
    func set<K: Key>(value: Mapper<K.Value>?, for key: K) where K.Base == Base {
        guard let value = value else {
            bags[key] = nil
            return
        }
        
        let subscription = source.subscribe { [weak base] theme, appearance in
            guard let base = base else { return }
            key.set(base, with: value[theme, appearance])
        }
        
        bags[key] = Bag(value: value, subscription: subscription)
    }
    
    // MARK: - Subscripts
    
    /// Key subscript
    public subscript<K: Key>(key key: K) -> Mapper<K.Value>? where K.Base == Base {
        get { bags[key]?.value as? Mapper<K.Value> }
        nonmutating set { set(value: newValue, for: key) }
    }
    
    /// Dynamic member lookup (KeyPath)
    public subscript<V>(dynamicMember keyPath: ReferenceWritableKeyPath<Base, V>) -> Mapper<V>? {
        get { self[key: keyPath] }
        nonmutating set { self[key: keyPath] = newValue }
    }
    
    /// KeyPath subscript
    public subscript<V>(_ keyPath: ReferenceWritableKeyPath<Base, V>) -> Mapper<V>? {
        get { self[key: keyPath] }
        nonmutating set { self[key: keyPath] = newValue }
    }
    
    /// Optional target KeyPath subscript (e.g., `\.layer, \.backgroundColor`)
    public subscript<Target, V>(
        _ targetKeyPath: KeyPath<Base, Target?>,
        _ keyPath: ReferenceWritableKeyPath<Target, V>
    ) -> Mapper<V>? {
        get { self[key: OptionalReferenceWritableKeyPath(targetKeyPath, keyPath)] }
        nonmutating set { self[key: OptionalReferenceWritableKeyPath(targetKeyPath, keyPath)] = newValue }
    }
}

// MARK: - NSObject String KeyPath Support

public extension Phi where Base: NSObject {
    /// ObjC string key path subscript.
    subscript(_ keyPath: String) -> Mapper<Any>? {
        get { self[key: StringKeyPath<Base>(keyPath)] }
        nonmutating set { self[key: StringKeyPath<Base>(keyPath)] = newValue }
    }
}

// MARK: - Subscribe Support

public extension Phi {
    /// Subscribes to theme and appearance changes.
    func subscribe(action: @escaping (Theme, Appearance) -> Void) -> VoidKey<Base> {
        let key = VoidKey<Base>()
        set(value: Mapper { theme, appearance in
            action(theme, appearance)
        }, for: key)
        return key
    }
    
    /// Cancels a subscription created through `subscribe`.
    func unsubscribe(for key: VoidKey<Base>) {
        set(value: nil, for: key)
    }
}

// MARK: - PhiCompatible Protocol

/// Marks objects that can vend a `Phi` binder.
public protocol PhiCompatible: AnyObject {}

public extension PhiCompatible {
    /// Creates a binder backed by the provided theme source.
    func phi(source: ThemeSource) -> Phi<Self> {
        Phi(self, source)
    }
}

public extension PhiCompatible where Self: ThemeSource {
    /// Creates a binder that uses `self` as the theme source.
    var phi: Phi<Self> {
        get { Phi(self, self) }
        set {}  // Preserve assignment-style call sites.
    }
}

// MARK: - NSObject Conformance

extension NSObject: PhiCompatible {}

// MARK: - Convenience Extensions

public extension PhiCompatible {
    /// Subscribes using the shared theme manager as the source.
    @discardableResult
    func phiSubscribe(action: @escaping (Theme, Appearance) -> Void) -> VoidKey<Self> {
        phi(source: ThemeManager.shared).subscribe(action: action)
    }
    
    /// Cancels a shared theme-manager subscription.
    func phiUnsubscribe(for key: VoidKey<Self>) {
        phi(source: ThemeManager.shared).unsubscribe(for: key)
    }
}

// MARK: - Legacy Support

public extension NSView {
    /// Legacy theme-change callback. Prefer typed subscriptions instead.
    @objc var themeChanged: (() -> Void)? {
        get {
            phi.bags[""]?.value as? () -> Void
        }
        set {
            guard let newValue = newValue else {
                phi.bags[""] = nil
                return
            }
            
            let subscription = phi.source.subscribe { _, _ in
                newValue()
            }
            phi.bags[""] = Bag(value: newValue, subscription: subscription)
        }
    }
}
