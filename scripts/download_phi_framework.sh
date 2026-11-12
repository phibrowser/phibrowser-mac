#!/bin/sh

set -eu

repository="phibrowser/phibrowser-framework"
# Overridable for testing against a local fixture server. The value is the
# GitHub "releases" collection endpoint; "/tags/<tag>" and "?per_page=" are
# appended to it.
releases_api_url=${PHI_FRAMEWORK_RELEASES_API:-"https://api.github.com/repos/$repository/releases"}

# macOS releases are tagged mac-vX.Y.Z and ship phi-browser-framework-mac.zip.
# Releases published before Windows frameworks joined the repository are tagged
# vX.Y.Z and ship Phi.Framework.zip; both are still accepted. Windows releases
# (win-vX.Y.Z) are never selected.
asset_name="phi-browser-framework-mac.zip"
legacy_asset_name="Phi.Framework.zip"
mac_tag_prefix="mac-v"
legacy_tag_prefix="v"
max_release_pages=10
requested_version=""

usage() {
    cat <<EOF
Usage: ${0##*/} [--version <version>]

Download and install the macOS Phi Framework from GitHub Releases
($repository).

Without --version, installs the newest published macOS release: the newest
mac-vX.Y.Z release, or the newest legacy vX.Y.Z release if no mac-v release
exists yet. Windows (win-v*) releases are ignored.

Options:
  --version <version>  Install a specific macOS release. Accepts 2.17.0,
                       v2.17.0 or mac-v2.17.0; mac-v<version> is tried first,
                       then the legacy v<version> tag.
  -h, --help           Show this help message.

Environment:
  PHI_FRAMEWORK_RELEASES_API  Override the releases API endpoint
                              (default: https://api.github.com/repos/$repository/releases).
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            if [ "$#" -lt 2 ]; then
                echo "error: --version requires a value" >&2
                exit 2
            fi
            requested_version=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ -n "$requested_version" ]; then
    original_requested_version=$requested_version
    case "$requested_version" in
        win-*)
            echo "error: $requested_version is a Windows release; this script installs the macOS framework" >&2
            echo "       pass a macOS version such as 2.17.0, v2.17.0 or mac-v2.17.0" >&2
            exit 2
            ;;
        "$mac_tag_prefix"*) requested_version=${requested_version#"$mac_tag_prefix"} ;;
        "$legacy_tag_prefix"*) requested_version=${requested_version#"$legacy_tag_prefix"} ;;
    esac
    case "$requested_version" in
        ""|*[!0-9A-Za-z.+-]*)
            echo "error: invalid version: $original_requested_version" >&2
            exit 2
            ;;
    esac
fi

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd)
frameworks_directory="$repository_root/Frameworks"
destination="$frameworks_directory/Phi Framework.framework"

temporary_directory=""
install_work_directory=""
installation_complete=NO

cleanup() {
    if [ "$installation_complete" = "NO" ] \
        && [ -n "$install_work_directory" ] \
        && [ -e "$install_work_directory/Phi Framework.framework.previous" ] \
        && [ ! -e "$destination" ]; then
        /bin/mv "$install_work_directory/Phi Framework.framework.previous" "$destination"
    fi

    if [ -n "$temporary_directory" ] && [ -d "$temporary_directory" ]; then
        /bin/rm -rf "$temporary_directory"
    fi
    if [ -n "$install_work_directory" ] && [ -d "$install_work_directory" ]; then
        /bin/rm -rf "$install_work_directory"
    fi
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

temporary_directory=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/phi-framework.XXXXXX")
release_metadata="$temporary_directory/release.json"
extracted_directory="$temporary_directory/extracted"

# Prints the HTTP status code; the response body is written to $2.
fetch_json() {
    /usr/bin/curl \
        --location \
        --silent \
        --show-error \
        --retry 3 \
        --header "Accept: application/vnd.github+json" \
        --output "$2" \
        --write-out '%{http_code}' \
        "$1"
}

# Downloads the release tagged $1 into $release_metadata.
# Returns 0 when found, 1 when the tag does not exist; exits on other errors.
fetch_release_by_tag() {
    status=$(fetch_json "$releases_api_url/tags/$1" "$release_metadata") || {
        echo "error: failed to query GitHub for release $1" >&2
        exit 1
    }
    case "$status" in
        200) return 0 ;;
        404) return 1 ;;
        *)
            echo "error: GitHub returned HTTP $status for release $1" >&2
            exit 1
            ;;
    esac
}

# Selects the newest published macOS release into $release_metadata.
# GitHub lists releases newest first (by creation date), so the first
# non-draft, non-prerelease mac-v* entry wins; the first legacy v* entry is
# remembered as a fallback while no mac-v* release has been published yet.
select_latest_release() {
    release_list="$temporary_directory/releases.json"
    fallback_index=""
    page=1
    while [ "$page" -le "$max_release_pages" ]; do
        status=$(fetch_json "$releases_api_url?per_page=100&page=$page" "$release_list") || {
            echo "error: failed to list Phi Framework releases" >&2
            exit 1
        }
        if [ "$status" != "200" ]; then
            echo "error: GitHub returned HTTP $status while listing releases" >&2
            exit 1
        fi

        index=0
        while :; do
            tag=$(/usr/bin/plutil -extract "$index.tag_name" raw -o - "$release_list" 2>/dev/null) || break
            draft=$(/usr/bin/plutil -extract "$index.draft" raw -o - "$release_list" 2>/dev/null || echo false)
            prerelease=$(/usr/bin/plutil -extract "$index.prerelease" raw -o - "$release_list" 2>/dev/null || echo false)

            if [ "$draft" != "true" ] && [ "$prerelease" != "true" ]; then
                case "$tag" in
                    "$mac_tag_prefix"[0-9]*)
                        /usr/bin/plutil -extract "$index" json -o "$release_metadata" "$release_list"
                        return 0
                        ;;
                    "$legacy_tag_prefix"[0-9]*)
                        if [ -z "$fallback_index" ]; then
                            fallback_index=$index
                            /usr/bin/plutil -extract "$index" json -o "$release_metadata" "$release_list"
                        fi
                        ;;
                esac
            fi
            index=$((index + 1))
        done

        if [ "$index" -lt 100 ]; then
            break
        fi
        page=$((page + 1))
    done

    if [ -n "$fallback_index" ]; then
        return 0
    fi

    echo "error: no published macOS release (${mac_tag_prefix}X.Y.Z or ${legacy_tag_prefix}X.Y.Z) found in $repository" >&2
    exit 1
}

echo "Fetching Phi Framework release metadata..."
if [ -n "$requested_version" ]; then
    if ! fetch_release_by_tag "$mac_tag_prefix$requested_version" \
        && ! fetch_release_by_tag "$legacy_tag_prefix$requested_version"; then
        echo "error: no macOS release for version $requested_version in $repository" >&2
        echo "       tried tags: $mac_tag_prefix$requested_version, $legacy_tag_prefix$requested_version" >&2
        exit 1
    fi
else
    select_latest_release
fi

release_tag=$(/usr/bin/plutil -extract tag_name raw -o - "$release_metadata" 2>/dev/null || true)
if [ -z "$release_tag" ]; then
    echo "error: GitHub returned invalid release metadata" >&2
    exit 1
fi

# Prefers the current asset name and falls back to the legacy one.
asset_url=""
asset_digest=""
selected_asset_name=""
for candidate_asset_name in "$asset_name" "$legacy_asset_name"; do
    asset_index=0
    while :; do
        current_asset_name=$(/usr/bin/plutil \
            -extract "assets.$asset_index.name" raw -o - "$release_metadata" 2>/dev/null || true)
        if [ -z "$current_asset_name" ]; then
            break
        fi

        if [ "$current_asset_name" = "$candidate_asset_name" ]; then
            selected_asset_name=$current_asset_name
            asset_url=$(/usr/bin/plutil \
                -extract "assets.$asset_index.browser_download_url" raw -o - "$release_metadata")
            asset_digest=$(/usr/bin/plutil \
                -extract "assets.$asset_index.digest" raw -o - "$release_metadata" 2>/dev/null || true)
            break 2
        fi

        asset_index=$((asset_index + 1))
    done
done

if [ -z "$asset_url" ]; then
    echo "error: release $release_tag does not contain $asset_name (or legacy $legacy_asset_name)" >&2
    exit 1
fi

archive_path="$temporary_directory/$selected_asset_name"

case "$asset_digest" in
    sha256:*) expected_sha256=${asset_digest#sha256:} ;;
    *)
        echo "error: release $release_tag does not provide a SHA-256 digest" >&2
        exit 1
        ;;
esac

echo "Downloading Phi Framework $release_tag ($selected_asset_name)..."
/usr/bin/curl \
    --fail \
    --location \
    --show-error \
    --progress-bar \
    --retry 3 \
    --output "$archive_path" \
    "$asset_url"

actual_sha256=$(/usr/bin/shasum -a 256 "$archive_path" | /usr/bin/awk '{print $1}')
if [ "$actual_sha256" != "$expected_sha256" ]; then
    echo "error: SHA-256 verification failed for $selected_asset_name" >&2
    exit 1
fi

/bin/mkdir -p "$extracted_directory"
/usr/bin/ditto -x -k "$archive_path" "$extracted_directory"

extracted_framework="$extracted_directory/Phi Framework.framework"
framework_executable="$extracted_framework/Versions/Current/Phi Framework"

if [ ! -d "$extracted_framework" ] \
    || [ ! -d "$extracted_framework/Versions/Current" ] \
    || [ ! -f "$framework_executable" ]; then
    echo "error: $selected_asset_name does not contain a complete Phi Framework.framework" >&2
    exit 1
fi

if ! /usr/bin/file "$framework_executable" | /usr/bin/grep -q 'Mach-O'; then
    echo "error: Phi Framework executable is not a Mach-O binary" >&2
    exit 1
fi

/bin/mkdir -p "$frameworks_directory"
install_work_directory=$(/usr/bin/mktemp -d "$frameworks_directory/.phi-framework-install.XXXXXX")
staged_framework="$install_work_directory/Phi Framework.framework"
previous_framework="$install_work_directory/Phi Framework.framework.previous"

/usr/bin/ditto "$extracted_framework" "$staged_framework"

if [ -e "$destination" ] || [ -L "$destination" ]; then
    /bin/mv "$destination" "$previous_framework"
fi

/bin/mv "$staged_framework" "$destination"
installation_complete=YES

echo "Installed Phi Framework $release_tag at:"
echo "$destination"
