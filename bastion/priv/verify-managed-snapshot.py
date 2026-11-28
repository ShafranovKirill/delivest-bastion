#!/usr/bin/env python3
"""Check a managed Node archive without extracting its secret-bearing contents."""

import hashlib
import json
import re
import sys
import tarfile


FILES = {
    "project/.package-sha256",
    "project/.env",
    "project/docker-compose.yml",
    "project/deploy/nginx/gateway.conf.template",
    "project/release-manifest.json",
    "project/reservation.json",
    "volumes/postgres_prod_data.tar",
    "volumes/s3_data.tar",
    "volumes/public_site_state.tar",
    "volumes/instance_backups.tar",
}
DIGEST = re.compile(r"[0-9a-f]{64}\Z")


def verify(path, instance_id):
    seen = {}
    manifest = None
    with tarfile.open(path, mode="r|gz") as archive:
        for entry in archive:
            name = entry.name.removeprefix("./")
            if entry.isdir() and name.rstrip("/") in {"project", "project/deploy", "project/deploy/nginx", "volumes"}:
                continue
            if not entry.isfile() or name not in FILES | {"manifest.json"} or name in seen:
                raise ValueError("unsafe or unexpected archive entry")
            if name == "manifest.json" and entry.size > 100_000:
                raise ValueError("oversized manifest")
            data = archive.extractfile(entry)
            digest = hashlib.sha256()
            if name == "manifest.json":
                manifest = json.load(data)
                seen[name] = {"size": entry.size}
                continue
            while chunk := data.read(1024 * 1024):
                digest.update(chunk)
            seen[name] = {"size": entry.size, "sha256": digest.hexdigest()}

    if set(seen) != FILES | {"manifest.json"}:
        raise ValueError("archive files are incomplete")
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 1:
        raise ValueError("unsupported backup format")
    if manifest.get("instance_id") != instance_id or not isinstance(manifest.get("project_name"), str):
        raise ValueError("archive belongs to another installation")
    if not isinstance(manifest.get("placement_revision"), int) or manifest["placement_revision"] < 1:
        raise ValueError("invalid placement revision")
    if not isinstance(manifest.get("release_version"), str) or not DIGEST.fullmatch(manifest.get("release_manifest_sha256", "")):
        raise ValueError("invalid release identity")
    if manifest.get("files") != {name: seen[name] for name in FILES}:
        raise ValueError("backup file checksum mismatch")
    if manifest["release_manifest_sha256"] != seen["project/release-manifest.json"]["sha256"]:
        raise ValueError("release manifest checksum mismatch")
    return {key: manifest[key] for key in ("release_version", "release_manifest_sha256", "captured_at")}


if __name__ == "__main__":
    try:
        print(json.dumps(verify(sys.argv[1], sys.argv[2])))
    except (OSError, ValueError, tarfile.TarError, json.JSONDecodeError) as error:
        print(type(error).__name__, file=sys.stderr)
        sys.exit(1)
