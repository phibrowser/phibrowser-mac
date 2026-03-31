# Dependency Management

## Goal

`PackageCollection` is the single source of truth for all Swift Package Manager dependencies in this project. It keeps dependency changes centralized and makes CI/CD integration simpler.

## How To Update Dependencies

Make all dependency additions, removals, and version updates in this package.

1. Open `Package.swift` in this directory.
2. Edit the `dependencies` array (add, remove, or update packages and versions).
3. Return to the main project. Xcode / Swift Package Manager will resolve and sync changes automatically.

This avoids managing complex dependency graphs directly in the main app target and keeps the process maintainable.
