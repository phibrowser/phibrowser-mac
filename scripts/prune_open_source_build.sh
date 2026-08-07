#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: ${0##*/} <app-path>" >&2
    exit 2
fi

app_path=$1
contents_path="$app_path/Contents"
macos_path="$contents_path/MacOS"
info_plist_path="$contents_path/Info.plist"

if [ ! -d "$app_path" ] || [ ! -d "$macos_path" ] || [ ! -f "$info_plist_path" ]; then
    echo "error: OpenSource app product is incomplete: $app_path" >&2
    exit 1
fi

sparkle_framework="$contents_path/Frameworks/Sparkle.framework"
if [ -e "$sparkle_framework" ]; then
    /bin/rm -rf "$sparkle_framework"
fi

phi_framework="$contents_path/Frameworks/Phi Framework.framework"
if [ ! -d "$phi_framework" ]; then
    echo "error: required Phi Framework is missing from app product" >&2
    exit 1
fi

sparkle_path=$(/usr/bin/find "$app_path" -iname '*sparkle*' -print -quit)
if [ -n "$sparkle_path" ]; then
    echo "error: Sparkle content remains in app product: $sparkle_path" >&2
    exit 1
fi

phi_framework_linked=NO
for binary_path in "$macos_path"/*; do
    [ -f "$binary_path" ] || continue
    /usr/bin/file "$binary_path" | /usr/bin/grep -q 'Mach-O' || continue

    linked_libraries=$(/usr/bin/otool -L "$binary_path")
    if printf '%s\n' "$linked_libraries" | /usr/bin/grep -q 'Sparkle.framework'; then
        echo "error: Sparkle load command remains in $binary_path" >&2
        exit 1
    fi
    if printf '%s\n' "$linked_libraries" | /usr/bin/grep -q 'Phi Framework.framework'; then
        phi_framework_linked=YES
    fi

    if /usr/bin/nm -g "$binary_path" 2>/dev/null | /usr/bin/grep -E -q 'SPU|SUAppcast|\$s7Sparkle|_OBJC_(CLASS|METACLASS)_\$_SU'; then
        echo "error: Sparkle symbol remains in $binary_path" >&2
        exit 1
    fi
done

if [ "$phi_framework_linked" != "YES" ]; then
    echo "error: required Phi Framework load command is missing" >&2
    exit 1
fi

for key in \
    SUAutomaticallyUpdate \
    SUEnableAutomaticChecks \
    SUFeedURL \
    SUPublicEDKey \
    SUScheduledCheckInterval
do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$info_plist_path" >/dev/null 2>&1 || true
    if /usr/libexec/PlistBuddy -c "Print :$key" "$info_plist_path" >/dev/null 2>&1; then
        echo "error: Sparkle Info.plist key remains: $key" >&2
        exit 1
    fi
done

echo "Verified pruned OpenSource product"
