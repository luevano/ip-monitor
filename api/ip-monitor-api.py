import logging
import json
from fastapi import FastAPI, Request, Response, status
from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from config import SERVERS_PATH, ROOT_PATH


app = FastAPI(root_path=ROOT_PATH)
log = logging.getLogger(__name__)


servers = {}
with open(SERVERS_PATH, "r") as json_file:
    servers = json.load(json_file)


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

    return {"ip": ip}


@app.put("/ip")
async def update_ips(credentials: Credentials, request: Request):
    ip = request.client.host
    sname = credentials.name
    ssecret = credentials.secret

    ipv4 = is_ipv4(ip)

    if sname not in servers:
        servers[sname] = {"ip": ip, "secret": ssecret}
        save_servers_info()
        return JSONResponse(content=jsonable_encoder(servers[sname]),
                            status_code=status.HTTP_201_CREATED)

    if ssecret != servers[sname]["secret"]:
        return Response(content=f"401",
                        media_type="text/plain",
                        status_code=status.HTTP_401_UNAUTHORIZED)

    if servers[sname]["ip"] != ip:
        old_ip = servers[sname]["ip"]
        servers[sname]["ip"] = ip
        servers[sname]["ip_history"].insert(0, ip)
        save_servers_info()
        return Response(content=f"201: {sname} IP changed:{old_ip}-{ip}",
                        media_type="text/plain",
                        status_code=status.HTTP_201_CREATED)

    return Response(content=f"200: {sname} IP hasn't changed",
                    media_type="text/plain",
                    status_code=status.HTTP_200_OK)

