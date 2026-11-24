"""Server registry for the ip-monitor API.

One JSON file holds, per server name, a salted scrypt hash of its token and
the addresses it was last seen with. Tokens are never stored: they can only
be checked, not read back.
"""

import fcntl
import hashlib
import hmac
import json
import os
import secrets
from contextlib import contextmanager
from datetime import datetime, timezone

DEFAULT_PATH = "/var/lib/ip-monitor-api/servers.json"
VERSION = 2
HISTORY_LIMIT = 100

SCRYPT_N = 2**14
SCRYPT_R = 8
SCRYPT_P = 1


def store_path() -> str:
    return os.environ.get("IP_MONITOR_SERVERS", DEFAULT_PATH)


def new_token() -> str:
    return secrets.token_urlsafe(32)


def hash_token(token: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.scrypt(token.encode(), salt=salt, n=SCRYPT_N, r=SCRYPT_R, p=SCRYPT_P)
    return f"scrypt${SCRYPT_N}${SCRYPT_R}${SCRYPT_P}${salt.hex()}${digest.hex()}"


def verify_token(token: str, stored: str) -> bool:
    try:
        scheme, n, r, p, salt, digest = stored.split("$")
        if scheme != "scrypt":
            return False
        candidate = hashlib.scrypt(token.encode(), salt=bytes.fromhex(salt),
                                   n=int(n), r=int(r), p=int(p))
        return hmac.compare_digest(candidate, bytes.fromhex(digest))
    except (ValueError, TypeError):
        return False


def _from_legacy(data: dict) -> dict:
    """The first format: {name: {"ip", "secret" (plain text), "ip_history"}}."""
    servers = {}
    for name, old in data.items():
        history = old.get("ip_history") or ([old["ip"]] if old.get("ip") else [])
        servers[name] = {
            "token_hash": hash_token(old.get("secret", new_token())),
            "ipv4": old.get("ip"),
            "ipv6": None,
            "ipv4_history": history[:HISTORY_LIMIT],
            "ipv6_history": [],
            "updated": None,
        }
    return {"version": VERSION, "servers": servers}


def _read(path: str) -> tuple[dict, bool]:
    """Returns the data and whether it was converted from the first format."""
    try:
        with open(path, "r") as json_file:
            data = json.load(json_file)
    except FileNotFoundError:
        return {"version": VERSION, "servers": {}}, False
    if data.get("version") == VERSION:
        return data, False
    return _from_legacy(data), True


def _write(path: str, data: dict):
    tmp = f"{path}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as json_file:
        json_file.write(json.dumps(data, indent=4))
        json_file.write("\n")
    # root (the admin tool) writes for the service: keep the service's ownership
    if os.geteuid() == 0:
        owner = os.stat(os.path.dirname(path) or ".")
        os.chown(tmp, owner.st_uid, owner.st_gid)
    os.replace(tmp, path)


@contextmanager
def locked():
    """The registry, read under a lock. Changes made to it are saved, unless
    the block raises."""
    path = store_path()
    # the lock is on the directory, so there's no lock file to own
    lock_fd = os.open(os.path.dirname(path) or ".", os.O_RDONLY)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        data, converted = _read(path)
        before = json.dumps(data, sort_keys=True)
        yield data["servers"]
        if converted or json.dumps(data, sort_keys=True) != before:
            _write(path, data)
    finally:
        os.close(lock_fd)


def migrate():
    """Rewrites a registry in the first format, hashing its plain text secrets."""
    with locked():
        pass


def record_address(server: dict, version: int, ip: str) -> str | None:
    """Stores the address a server was seen with. Returns the one it replaces,
    or None when it didn't change."""
    key = f"ipv{version}"
    old = server.get(key)
    if old == ip:
        return None
    server[key] = ip
    history = server.setdefault(f"{key}_history", [])
    history.insert(0, ip)
    del history[HISTORY_LIMIT:]
    server["updated"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    return old or ""
