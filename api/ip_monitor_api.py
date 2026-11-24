"""ip-monitor API: tells a client the public address it connects from and
keeps track of it per registered server.

Servers are registered with the ip-monitor-admin tool on this machine, never
through the API.
"""

import ipaddress
import logging
import os

from fastapi import FastAPI, Header, Request, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

import store

# The path the reverse proxy serves the API under. Requests work with or
# without it in their path, so the proxy may strip it or not.
ROOT_PATH = os.environ.get("IP_MONITOR_API_ROOT_PATH", "")

# no interactive docs or schema: there's nothing here for a browser
app = FastAPI(root_path=ROOT_PATH, docs_url=None, redoc_url=None, openapi_url=None)
log = logging.getLogger("uvicorn.error")

# hashes the plain text secrets of a registry in the first format
store.migrate()


class Credentials(BaseModel):
    name: str = Field(max_length=255)
    # deprecated: clients before the Authorization header sent the secret here
    secret: str | None = Field(default=None, max_length=1024)


def reply(status_code: int, **content) -> JSONResponse:
    return JSONResponse(content={**content, "status_code": status_code},
                        status_code=status_code)


def client_address(request: Request) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
    """The address the request came from, None if it can't be told."""
    try:
        ip = ipaddress.ip_address(request.client.host)
    except (ValueError, AttributeError):
        return None
    # IPv4 that arrived on an IPv6 socket
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return ip


@app.get("/ip")
def get_ip(request: Request):
    ip = client_address(request)
    if ip is None:
        return reply(status.HTTP_400_BAD_REQUEST, error="Can't tell the client address.")
    return reply(status.HTTP_200_OK, ip=str(ip), version=ip.version, ipv4=ip.version == 4)


@app.put("/ip")
def update_ip(credentials: Credentials, request: Request,
              authorization: str | None = Header(default=None)):
    token = credentials.secret
    if authorization and authorization.lower().startswith("bearer "):
        token = authorization[7:].strip()

    ip = client_address(request)
    # A private or loopback address means the reverse proxy isn't passing the
    # client's address on: never record that as someone's public address.
    if ip is None or not ip.is_global:
        log.warning("Request from non public address %s, check the proxy headers.", ip)
        return reply(status.HTTP_400_BAD_REQUEST, error="Not a public client address.")

    name = credentials.name
    with store.locked() as servers:
        server = servers.get(name)
        # same answer for an unknown name and a wrong token
        if (server is None or not token
                or not store.verify_token(token, server.get("token_hash", ""))):
            return reply(status.HTTP_401_UNAUTHORIZED, error="Unknown server or wrong token.")

        old_ip = store.record_address(server, ip.version, str(ip))

    if old_ip is None:
        return reply(status.HTTP_200_OK, name=name, msg="IP hasn't changed.",
                     ip=str(ip), version=ip.version)
    log.info("%s: IPv%d changed from %s to %s.", name, ip.version, old_ip or "nothing", ip)
    return reply(status.HTTP_201_CREATED, name=name, ip=str(ip), version=ip.version,
                 old_ip=old_ip)
