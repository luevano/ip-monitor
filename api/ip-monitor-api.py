import logging
import json
from fastapi import FastAPI, Request, status
from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from config import SERVERS_PATH, ROOT_PATH


app = FastAPI(root_path=ROOT_PATH)
log = logging.getLogger(__name__)


servers = {}
try:
    with open(SERVERS_PATH, "r") as json_file:
        servers = json.load(json_file)
except FileNotFoundError:
    with open(SERVERS_PATH, "x") as json_file:
        json_file.write(json.dumps(servers, indent=4))


def save_servers_info():
    with open(SERVERS_PATH, "w") as json_file:
        json_file.write(json.dumps(servers, indent=4))


# really dumb way of checking v4/v6
def is_ipv4(ip: str) -> bool:
    if "." in ip:
        log.info("Incoming request is IPv4.")
        return True
    log.info("Incoming request is IPv6.")
    return False


class Credentials(BaseModel):
    name: str
    secret: str


@app.get("/ip")
async def get_ip(request: Request):
    ip = request.client.host
    ipv4 = is_ipv4(ip)
    status_code = status.HTTP_200_OK
    out = {"ip": ip, "ipv4": ipv4, "status_code": status_code}

    return JSONResponse(content=jsonable_encoder(out),
                        status_code=status_code)


@app.put("/ip")
async def update_ips(credentials: Credentials, request: Request):
    ip = request.client.host
    sname = credentials.name
    ssecret = credentials.secret

    ipv4 = is_ipv4(ip)
    if not ipv4:
        msg = "Only IPv4 supported."
        status_code = status.HTTP_406_NOT_ACCEPTABLE
        out = {"error": msg, "status_code": status_code}
        return JSONResponse(content=jsonable_encoder(out),
                            status_code=status_code)

    if sname not in servers:
        servers[sname] = {"ip": ip, "secret": ssecret}
        save_servers_info()
        status_code = status.HTTP_201_CREATED
        out = {"name": sname, "secret": ssecret, "ip": ip, "status_code": status_code}
        return JSONResponse(content=jsonable_encoder(out),
                            status_code=status_code)

    if ssecret != servers[sname]["secret"]:
        msg = "Wrong secret."
        status_code = status.HTTP_401_UNAUTHORIZED
        out = {"msg": msg, "status_code": status_code}
        return JSONResponse(content=jsonable_encoder(out),
                            status_code=status_code)

    if servers[sname]["ip"] != ip:
        old_ip = servers[sname]["ip"]
        servers[sname]["ip"] = ip
        servers[sname]["ip_history"].insert(0, ip)
        save_servers_info()

        status_code = status.HTTP_201_CREATED
        out = {"name": sname, "ip": ip, "old_ip": old_ip, "status_code": status_code}
        return JSONResponse(content=jsonable_encoder(out),
                            status_code=status_code)

    msg = "IP hasn't changed."
    status_code = status.HTTP_200_OK
    out = {"name": sname, "msg": msg, "ip": ip, "status_code": status_code}
    return JSONResponse(content=jsonable_encoder(out),
                        status_code=status_code)

