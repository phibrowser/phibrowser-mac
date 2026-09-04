#!/bin/sh

set -eu

repository="phibrowser/phibrowser-framework"
asset_name="Phi.Framework.zip"
requested_tag=""

usage() {
    cat <<EOF
Usage: ${0##*/} [--version <version>]

Download and install Phi Framework from GitHub Releases.

Options:
  --version <version>  Install a specific release, for example v2.9.0.
  -h, --help           Show this help message.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            if [ "$#" -lt 2 ]; then
                echo "error: --version requires a value" >&2
                exit 2
            fi
            requested_tag=$2
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

if [ -n "$requested_tag" ]; then
    case "$requested_tag" in
        v*) ;;
        *) requested_tag="v$requested_tag" ;;
    esac
    release_api_url="https://api.github.com/repos/$repository/releases/tags/$requested_tag"
else
    release_api_url="https://api.github.com/repos/$repository/releases/latest"
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
archive_path="$temporary_directory/$asset_name"
extracted_directory="$temporary_directory/extracted"

echo "Fetching Phi Framework release metadata..."
/usr/bin/curl \
    --fail \
    --location \
    --silent \
    --show-error \
    --retry 3 \
    --output "$release_metadata" \
    "$release_api_url"

release_tag=$(/usr/bin/plutil -extract tag_name raw -o - "$release_metadata" 2>/dev/null || true)
if [ -z "$release_tag" ]; then
    echo "error: GitHub returned invalid release metadata" >&2
    exit 1
fi

asset_url=""
asset_digest=""
asset_index=0
while :; do
    current_asset_name=$(/usr/bin/plutil \
        -extract "assets.$asset_index.name" raw -o - "$release_metadata" 2>/dev/null || true)
    if [ -z "$current_asset_name" ]; then
        break
    fi

    if [ "$current_asset_name" = "$asset_name" ]; then
        asset_url=$(/usr/bin/plutil \
            -extract "assets.$asset_index.browser_download_url" raw -o - "$release_metadata")
        asset_digest=$(/usr/bin/plutil \
            -extract "assets.$asset_index.digest" raw -o - "$release_metadata" 2>/dev/null || true)
        break
    fi

    asset_index=$((asset_index + 1))
done

if [ -z "$asset_url" ]; then
    echo "error: release $release_tag does not contain $asset_name" >&2
    exit 1
fi

case "$asset_digest" in
    sha256:*) expected_sha256=${asset_digest#sha256:} ;;
    *)
        echo "error: release $release_tag does not provide a SHA-256 digest" >&2
        exit 1
        ;;
esac

echo "Downloading Phi Framework $release_tag..."
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
    echo "error: SHA-256 verification failed for $asset_name" >&2
    exit 1
fi

/bin/mkdir -p "$extracted_directory"
/usr/bin/ditto -x -k "$archive_path" "$extracted_directory"

extracted_framework="$extracted_directory/Phi Framework.framework"
framework_executable="$extracted_framework/Versions/Current/Phi Framework"

if [ ! -d "$extracted_framework" ] \
    || [ ! -d "$extracted_framework/Versions/Current" ] \
    || [ ! -f "$framework_executable" ]; then
    echo "error: $asset_name does not contain a complete Phi Framework.framework" >&2
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
