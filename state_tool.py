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
import time


HOME = pathlib.Path.home()
PREFS = HOME / "Library/Preferences"
CACHE = PREFS / "com.apple.CloudSubscriptionFeatures.cache.plist"
WAITLIST = PREFS / "com.apple.CloudSubscriptionFeatures.waitlist.plist"
GMS = PREFS / "com.apple.gms.availability.plist"
BYHOST = PREFS / "ByHost"
SUPPORT = HOME / "Library/Application Support/SpotlightPlus"
BOOT_MARKER = SUPPORT / "last-campo-refresh-boot"


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


def defaults_bool(domain: str, key: str, value: bool) -> bool:
    current = subprocess.run(
        ["/usr/bin/defaults", "read", domain, key],
        check=False,
        capture_output=True,
        text=True,
    )
    normalized = current.stdout.strip().lower()
    desired = value
    current_value = normalized in {"1", "true", "yes"}
    if current.returncode == 0 and current_value == desired:
        return False
    subprocess.run(
        ["/usr/bin/defaults", "write", domain, key, "-bool", "true" if value else "false"],
        check=True,
    )
    return True


def notify() -> None:
    for name in (
        "com.apple.CloudSubscriptionFeature.Changed",
        "com.apple.siri.orchestration.capabilities.didChange",
        "com.apple.gms.availability.notification",
    ):
        subprocess.run(["/usr/bin/notifyutil", "-p", name], check=False)


def current_boot_id() -> str:
    result = subprocess.run(
        ["/usr/sbin/sysctl", "-n", "kern.boottime"],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def is_first_repair_this_boot(boot_id: str) -> bool:
    try:
        return BOOT_MARKER.read_text(encoding="utf-8").strip() != boot_id
    except FileNotFoundError:
        return True


def mark_boot_repaired(boot_id: str) -> None:
    SUPPORT.mkdir(parents=True, exist_ok=True)
    temporary = BOOT_MARKER.with_suffix(".tmp")
    temporary.write_text(boot_id + "\n", encoding="utf-8")
    os.replace(temporary, BOOT_MARKER)


def restart_campo() -> bool:
    """Restart Apple's UI host without activating its normal app window."""
    time.sleep(1)
    kickstart = subprocess.run(
        [
            "/bin/launchctl",
            "kickstart",
            "-k",
            f"gui/{os.getuid()}/com.apple.campo",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if kickstart.returncode == 0:
        print("campo_restart=ok:kickstart")
        return True

    # SIP protects Apple's launchd job from an explicit kickstart. Terminating
    # the current user's UI process is permitted; Apple's existing KeepAlive
    # job then recreates it in the background without NSWorkspace activation.
    terminate = subprocess.run(
        ["/usr/bin/killall", "Siri AI"],
        check=False,
        capture_output=True,
        text=True,
    )
    if terminate.returncode == 0:
        print("campo_restart=ok:keepalive")
        return True

    kickstart_message = (kickstart.stderr or kickstart.stdout).strip()
    terminate_message = (terminate.stderr or terminate.stdout).strip()
    print(
        "campo_restart=failed:"
        f"kickstart={kickstart_message}; terminate={terminate_message}"
    )
    return False


def watched_signature() -> tuple[tuple[str, int, int], ...]:
    """Cheaply detect files rewritten during asynchronous login startup."""
    paths = [
        CACHE,
        WAITLIST,
        GMS,
        PREFS / "com.apple.siri.plist",
        PREFS / "com.apple.siri.generativeassistantsettings.plist",
        *sorted(BYHOST.glob(".GlobalPreferences.*.plist")),
    ]
    signature = []
    for path in paths:
        try:
            info = path.stat()
            signature.append((str(path), info.st_mtime_ns, info.st_size))
        except FileNotFoundError:
            signature.append((str(path), -1, -1))
    return tuple(signature)


def repair(*, quiet: bool = False) -> bool:
    now = dt.datetime.now()
    boot_id = current_boot_id()
    first_this_boot = is_first_repair_this_boot(boot_id)
    results = {
        "cloud-cache": patch_cache(now),
        "waitlist": patch_waitlist(),
        "gms": patch_gms(),
        "byhost": patch_byhost(now),
        "siri-signed-up": defaults_bool("com.apple.siri", "GMSignedUp", True),
        "siri-enabled": defaults_bool(
            "com.apple.siri.generativeassistantsettings", "isEnabled", True
        ),
    }
    changed = [name for name, did_change in results.items() if did_change]
    if changed:
        notify()
    # Campo selects its coordinator when the process starts. Darwin
    # notifications refresh availability consumers, but do not reliably make
    # an already-running Campo replace a coordinator selected before login
    # repair. Restart once per boot, and again only after a real state repair.
    restarted = False
    if first_this_boot or changed:
        restarted = restart_campo()
        if restarted:
            mark_boot_repaired(boot_id)
    if not quiet or changed or first_this_boot:
        print("changed=" + (",".join(changed) if changed else "no"))
    return bool(changed or restarted)


def startup() -> None:
    """Repair at login and catch late GMS initialization for three minutes."""
    boot_id = current_boot_id()
    first_this_boot = is_first_repair_this_boot(boot_id)
    repair()
    if not first_this_boot:
        return

    # GMS and Campo initialize asynchronously after the Aqua login session is
    # created. They can overwrite the just-repaired values tens of seconds
    # later. A short-lived startup watch catches that race without keeping a
    # high-frequency process alive for the rest of the session.
    print("startup_watch=begin:180s")
    signature = watched_signature()
    for _ in range(90):
        time.sleep(2)
        new_signature = watched_signature()
        marker_missing = is_first_repair_this_boot(boot_id)
        if marker_missing or new_signature != signature:
            repair(quiet=True)
            new_signature = watched_signature()
        signature = new_signature
    print("startup_watch=end")


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
    parser.add_argument("command", choices=("repair", "startup", "status"))
    args = parser.parse_args()
    if args.command == "repair":
        repair()
    elif args.command == "startup":
        startup()
    else:
        status()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
