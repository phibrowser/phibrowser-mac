#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
# Match the core tests: Foundation normalizes /private/tmp through a symlink,
# which the production managed-directory checks intentionally reject.
task_build="$(mktemp -d "/Users/Shared/phi-time-machine-enumeration.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
# Compile the production store without the app; the installer flag only supplies
# TimeMachinePaths' standalone default bundle identifier.
for optimization in Onone O; do
  xcrun swiftc -swift-version 5 -parse-as-library -"$optimization" \
    -D TIME_MACHINE_INSTALLER -module-cache-path "$task_build/modules" \
    "$task_root/Sources/Application/TimeMachine/TimeMachineModels.swift" \
    "$task_root/Sources/Application/TimeMachine/TimeMachinePaths.swift" \
    "$task_root/Sources/Application/TimeMachine/TimeMachineCatalogStore.swift" \
    "$task_root/Tests/TimeMachineDirectoryEnumeration/main.swift" -o "$task_build/tests"
  for operation in delete resume measure; do
    echo "Testing $operation (-$optimization) with Guard Malloc"
    DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib MALLOC_STRICT_SIZE=1 \
      "$task_build/tests" "$task_build/$optimization-$operation" "$operation"
  done
done
