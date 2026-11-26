#!/usr/bin/env python3

import os
import pathlib
import plistlib
import re
import sys


def configure(root: dict, client_id: str, bundle_id: str) -> None:
    if not re.fullmatch(r"[A-Za-z0-9_-]+\.apps\.googleusercontent\.com", client_id):
        raise ValueError("Set a valid Google iOS OAuth client ID for Drive export.")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id):
        raise ValueError("Set the installed bundle ID registered with the Google iOS client.")
    scheme = ".".join(reversed(client_id.split(".")))
    types = root.setdefault("CFBundleURLTypes", [])
    if not isinstance(types, list):
        raise ValueError("Invalid CFBundleURLTypes in the base IPA.")
    if not any(isinstance(entry, dict) and scheme in entry.get("CFBundleURLSchemes", [])
               for entry in types):
        types.append({"CFBundleURLName": "YTKACE Drive Export", "CFBundleURLSchemes": [scheme]})
    root["YTKACEDriveClientID"] = client_id
    root["YTKACEDriveBundleID"] = bundle_id


def main() -> None:
    client_id = os.environ.get("YTKACE_DRIVE_IOS_CLIENT_ID", "").strip()
    bundle_id = os.environ.get("YTKACE_DRIVE_IOS_BUNDLE_ID", "").strip()
    if not client_id and not bundle_id:
        return
    path = pathlib.Path(sys.argv[1])
    root = plistlib.loads(path.read_bytes())
    try:
        configure(root, client_id, bundle_id)
    except ValueError as error:
        raise SystemExit(str(error)) from error
    path.write_bytes(plistlib.dumps(root, fmt=plistlib.FMT_BINARY, sort_keys=False))


if __name__ == "__main__":
    main()
