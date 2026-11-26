#!/usr/bin/env python3
"""Build the trial's Chromium Default Apps directory from one Athena revision."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile

# These Canary IDs are also used by the framework's built-in extension policy.
PACKAGES = {
    "sidecar/extension/crx/sidebar": "fenmfiepnpdlhplemgijlimpbebebljo",
    "ai-extension/lexington/crx/lexington": "pjgdkljlcbjgedgeppodjijjphfcplno",
    "ai-extension/kensington/crx/kensington": "pjlnhbfabokjejbhmgghmjiaknfhnima",
    "ai-extension/mirage/crx/mirage": "ickhcgejficcoofnjnnobadfdnfbilnm",
}


def build(repo, revision, version, workspace):
    archive = workspace / "source.tar"
    with archive.open("wb") as stream:
        subprocess.run(["git", "-C", repo, "archive", revision], stdout=stream, check=True)
    subprocess.run(["tar", "-xf", archive, "-C", workspace], check=True)
    archive.unlink()

    # The regular staging feed uses the same IDs and would replace trial CRXs.
    for name in ("ai-extension", "browser-use-extension", "mirage"):
        config = workspace / "ai-extension/deployment/env/dev" / (name + ".env")
        config.write_text(re.sub(r"^UPDATE_SERVER_URL=.*\n?", "", config.read_text(), flags=re.M))
    env = dict(os.environ, DEPLOY_ENV="dev", CI_ENV_NAME="staging",
               AI_EXTENSION_VERSION=version, SIDECAR_VERSION=version, UPDATE_SERVER_URL="")
    for directory, command in (
        (workspace, ["turbo", "run", "build", "--filter=@phi-ai/lexington...",
                     "--filter=@phi-ai/kensington...", "--filter=@phi-ai/mirage..."]),
        (workspace / "sidecar", ["--filter", "@sidecar/extension", "pack:crx"]),
    ):
        subprocess.run(["pnpm", "install", "--frozen-lockfile"], cwd=directory, env=env, check=True)
        subprocess.run(["pnpm", *command], cwd=directory, env=env, check=True)


def stage_packages(workspace, version, output):
    for prefix, expected_id in PACKAGES.items():
        source = workspace / (prefix + "-" + version + ".crx")
        with source.open("rb") as stream:
            if stream.read(8) != b"Cr24\x03\x00\x00\x00":
                raise ValueError(f"Expected CRX3 in {source.name}")
        with zipfile.ZipFile(source) as crx:
            manifest = json.loads(crx.read("manifest.json"))
        public_key = base64.b64decode(manifest["key"], validate=True)
        extension_id = hashlib.sha256(public_key).hexdigest()[:32].translate(
            str.maketrans("0123456789abcdef", "abcdefghijklmnop"))
        if extension_id != expected_id or manifest["version"] != version or manifest.get("update_url"):
            raise ValueError(f"Unexpected ID, version or update feed in {source.name}")
        digest = hashlib.sha256(source.read_bytes()).hexdigest()[:12]
        filename = f"{extension_id}-{version}-{digest}.crx"
        shutil.copyfile(source, output / filename)
        descriptor = {"external_crx": filename, "external_version": version}
        (output / (extension_id + ".json")).write_text(json.dumps(descriptor, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("athena_repo", type=Path)
    parser.add_argument("revision", help="Athena commit or tag")
    parser.add_argument("version", help="Chromium version newer than the installed Canary CRXs")
    parser.add_argument("output", type=Path, help="New directory for the four CRXs and descriptors")
    args = parser.parse_args()
    parts = args.version.split(".")
    if (len(parts) != 4 or not all(re.fullmatch(r"0|[1-9][0-9]{0,4}", p) and int(p) <= 65535
                                   for p in parts) or not any(int(p) for p in parts)):
        parser.error("expected four valid Chromium version components")
    if args.output.exists():
        parser.error("output already exists")
    revision = subprocess.check_output(
        ["git", "-C", args.athena_repo, "rev-parse", "--verify", "--end-of-options",
         args.revision + "^{commit}"], text=True).strip()
    with tempfile.TemporaryDirectory() as workspace, tempfile.TemporaryDirectory(dir=args.output.parent) as tmp:
        build(args.athena_repo, revision, args.version, Path(workspace))
        result = Path(tmp) / "Default Apps"
        result.mkdir()
        stage_packages(Path(workspace), args.version, result)
        result.rename(args.output)
    print(f"Packaged Athena {revision} extensions {args.version} in {args.output}")


if __name__ == "__main__":
    main()
