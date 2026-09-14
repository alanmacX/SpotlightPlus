#!/usr/bin/env python3
"""Maintain the current-user Enhanced Siri UI availability cache.

This intentionally changes only user preference files. It never opens or
activates Siri AI.app, touches SIP, edits /System, or changes eligibility DBs.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import plistlib
import subprocess


HOME = pathlib.Path.home()
PREFS = HOME / "Library/Preferences"
CACHE = PREFS / "com.apple.CloudSubscriptionFeatures.cache.plist"
WAITLIST = PREFS / "com.apple.CloudSubscriptionFeatures.waitlist.plist"
GMS = PREFS / "com.apple.gms.availability.plist"
BYHOST = PREFS / "ByHost"


def load(path: pathlib.Path):
    with path.open("rb") as stream:
        return plistlib.load(stream)


def save(path: pathlib.Path, value) -> None:
    mode = path.stat().st_mode & 0o777
    temporary = path.with_name(path.name + ".spotlightplus-temp")
    with temporary.open("wb") as stream:
        plistlib.dump(value, stream, fmt=plistlib.FMT_BINARY, sort_keys=False)
    os.chmod(temporary, mode)
    os.replace(temporary, path)


def decode_plist(value):
    if isinstance(value, (bytes, bytearray)):
        try:
            return plistlib.loads(value)
        except Exception:
            return None
    return value


def decode_json(value):
    if isinstance(value, (bytes, bytearray)):
        try:
            return json.loads(value.decode("utf-8"))
        except Exception:
            return None
    return value


def patch_cache(now: dt.datetime) -> bool:
    if not CACHE.exists():
        return False
    data = load(CACHE)
    entry = decode_plist(data.get("ai.enhanced-siri")) or {}
    value = entry.get("value") if isinstance(entry.get("value"), dict) else {}
    expiration = now + dt.timedelta(days=7)
    already_valid = (
        value.get("canUse") is True
        and isinstance(entry.get("expiration"), dt.datetime)
        and entry["expiration"] > now + dt.timedelta(days=2)
    )
    if already_valid:
        return False
    value.update({"featureKey": "ai.enhanced-siri", "canUse": True, "cacheTill": expiration})
    entry.update({"value": value, "expiration": expiration, "fetched": now})
    data["ai.enhanced-siri"] = plistlib.dumps(entry, fmt=plistlib.FMT_BINARY)
    save(CACHE, data)
    return True


def patch_waitlist() -> bool:
    if not WAITLIST.exists():
        return False
    data = load(WAITLIST)
    results = decode_json(data.get("waitlistResults")) or []
    changed = False
    for item in results:
        value = item.get("value", {}) if isinstance(item, dict) else {}
        if "ai.enhanced-siri" not in value.get("featureIDs", []):
            continue
        if value.get("status") != "active" or item.get("dirty") is not False:
            value["status"] = "active"
            item["value"] = value
            item["dirty"] = False
            changed = True
        break
    if changed:
        data["waitlistResults"] = json.dumps(results, separators=(",", ":")).encode("utf-8")
        save(WAITLIST, data)
    return changed


def patch_gms() -> bool:
    if not GMS.exists():
        return False
    data = load(GMS)
    desired = {
        "com.apple.gms.availability.accessNotGrantedUseCases": [],
        "com.apple.gms.availability.reasons": [],
        "com.apple.gms.availability.wasAvailable": True,
        "com.apple.gms.enhancedSiri.wasEverAvailable": True,
        "com.apple.gms.enhancedSiri.unifiedReasons": b"[]",
    }
    changed = any(data.get(key) != value for key, value in desired.items())
    if changed:
        data.update(desired)
        save(GMS, data)
    return changed


def patch_byhost(now: dt.datetime) -> bool:
    changed_any = False
    for path in sorted(BYHOST.glob(".GlobalPreferences.*.plist")):
        data = load(path)
        denied = data.get("com.apple.gms.availability.accessNotGrantedUseCases", [])
        filtered = [item for item in denied if item != "com.apple.Siri.EnhancedSiriDisablement"] \
            if isinstance(denied, list) else denied
        changed = (
            filtered != denied
            or data.get("com.apple.gms.enhancedSiri.availability") is not True
            or data.get("com.apple.gms.enhancedSiri.reasons") != []
        )
        if changed:
            data["com.apple.gms.availability.accessNotGrantedUseCases"] = filtered
            data["com.apple.gms.enhancedSiri.availability"] = True
            data["com.apple.gms.enhancedSiri.reasons"] = []
            data["com.apple.gms.enhancedSiri.lastUpdated"] = now
            save(path, data)
            changed_any = True
    return changed_any


def defaults_bool(domain: str, key: str, value: bool) -> None:
    subprocess.run(
        ["/usr/bin/defaults", "write", domain, key, "-bool", "true" if value else "false"],
        check=True,
    )


def notify() -> None:
    for name in (
        "com.apple.CloudSubscriptionFeature.Changed",
        "com.apple.siri.orchestration.capabilities.didChange",
        "com.apple.gms.availability.notification",
    ):
        subprocess.run(["/usr/bin/notifyutil", "-p", name], check=False)


def repair() -> None:
    now = dt.datetime.now()
    results = {
        "cloud-cache": patch_cache(now),
        "waitlist": patch_waitlist(),
        "gms": patch_gms(),
        "byhost": patch_byhost(now),
    }
    defaults_bool("com.apple.siri", "GMSignedUp", True)
    defaults_bool("com.apple.siri.generativeassistantsettings", "isEnabled", True)
    changed = [name for name, did_change in results.items() if did_change]
    if changed:
        notify()
    print("changed=" + (",".join(changed) if changed else "no"))


def status() -> None:
    cache = load(CACHE)
    entry = decode_plist(cache.get("ai.enhanced-siri")) or {}
    value = entry.get("value", {}) if isinstance(entry, dict) else {}
    gms = load(GMS)
    print(f"cache_canUse={value.get('canUse')!r}")
    print(f"cache_expiration={entry.get('expiration')!r}")
    print(f"user_unifiedReasons={decode_json(gms.get('com.apple.gms.enhancedSiri.unifiedReasons'))!r}")
    for path in sorted(BYHOST.glob(".GlobalPreferences.*.plist")):
        data = load(path)
        print(f"byhost_availability={data.get('com.apple.gms.enhancedSiri.availability')!r}")
        print(f"byhost_reasons={data.get('com.apple.gms.enhancedSiri.reasons')!r}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("repair", "status"))
    args = parser.parse_args()
    repair() if args.command == "repair" else status()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
