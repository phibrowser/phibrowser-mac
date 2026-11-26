#!/bin/zsh
# Repoint the shared Canary installation before returning from the Athena trial.
set -eu
set -o pipefail
autoload -Uz is-at-least

regular=${1:-"/Applications/Phi Canary.app"}
packages="$regular/Contents/Frameworks/Phi Framework.framework/Versions/Current/Default Apps"
registry="$HOME/Library/Application Support/com.phibrowser.canary.Mac/External Extensions"
fail() { print -u2 -- "$1"; exit 1; }

[[ -d "$regular" ]] || fail "Install a current regular Phi Canary in Applications first."
/usr/bin/codesign --verify --deep --strict -R='anchor apple generic and certificate leaf[subject.OU] = "87DQ3HMK5G" and identifier "com.phibrowser.canary.Mac"' "$regular"
[[ -n "$(/usr/bin/plutil -extract SUFeedURL raw "$regular/Contents/Info.plist")" ]] || fail "Select a regular Canary release with its update feed."
[[ -d "$registry" ]] || { print "There is no Athena extension registration to switch."; exit 0; }
/usr/bin/pgrep -x 'Phi Canary' >/dev/null && fail "Quit the running Canary browser and try again."

work=$(/usr/bin/mktemp -d "$registry/.switch-canary.XXXXXXXX")
trap '/bin/rm -rf "$work"' EXIT
for id in fenmfiepnpdlhplemgijlimpbebebljo pjgdkljlcbjgedgeppodjijjphfcplno pjlnhbfabokjejbhmgghmjiaknfhnima ickhcgejficcoofnjnnobadfdnfbilnm; do
    source="$packages/$id.json"
    filename=$(/usr/bin/plutil -extract external_crx raw "$source")
    version=$(/usr/bin/plutil -extract external_version raw "$source")
    [[ "$filename" == "$id-$version-"*.crx && "$filename" != */* && -f "$packages/$filename" ]] || fail "Invalid packaged extension $id."
    if [[ -f "$registry/$id.json" ]]; then
        previous=$(/usr/bin/plutil -extract external_version raw "$registry/$id.json")
        previous_crx=$(/usr/bin/plutil -extract external_crx raw "$registry/$id.json")
        if [[ "$previous_crx" != "$packages/$filename" ]] && is-at-least "$version" "$previous"; then
            fail "Install a regular Canary with extensions newer than $previous before switching."
        fi
    fi
    /usr/bin/plutil -replace external_crx -string "$packages/$filename" -o "$work/$id.json" "$source"
    /usr/bin/plutil -convert json "$work/$id.json"
done
for descriptor in "$work"/*.json; do
    /bin/mv -f "$descriptor" "$registry/"
done
print "The shared profiles will install the regular extensions when opened."
/usr/bin/open -a "$regular"
