# ip-monitor

IP monitor and DNS A/AAAA record setter for Vultr. With small Discord and Speedtest integration. This is just a quick script and api I set up for personal usage.

There are two parts, and a machine is one or the other depending on what it runs:

- **Client** (`ip-monitor.timer`): the machine whose address changes. It reports to the API, updates the DNS records and posts to Discord.
- **Server** (`ip-monitor-api.service`): a machine with a static address. Its API tells a client the public address it connects from and keeps track of it.

What the client does on each run, the same for IPv4 and IPv6:

- Reports to the API (`PUT /ip`) and gets back the public address the API saw.
- Updates the A or AAAA record in Vultr when that address isn't the one it last published. A record only counts as published once Vultr accepted it, so a failed update is retried on the next run.
- Posts changes and failures to Discord, with a speedtest on a change.

For IPv6 it first tests each public address of the interface and removes the ones that stopped working and belong to another prefix (left over from an old ISP prefix).

## Requirements

For the client: `curl`, `jq`, `iproute2`, `gawk`, `util-linux`, `systemd` and optionally [`speedtest-go`](https://github.com/showwin/speedtest-go).
For the server: `uvicorn` and python's `fastapi`, behind a reverse proxy with TLS that passes the client's address in `X-Forwarded-For`, reachable over both IPv4 and IPv6.

## Installation

The files are laid out for a package:

| File | Installed as |
|---|---|
| `ip-monitor.sh` | `/usr/bin/ip-monitor` |
| `ip-monitor-config` | `/usr/bin/ip-monitor-config` |
| `api/ip-monitor-admin` | `/usr/bin/ip-monitor-admin` |
| `api/ip_monitor_api.py`, `api/store.py` | `/usr/lib/ip-monitor/` |
| `api/api.conf` | `/etc/ip-monitor/api.conf` |
| `systemd/*.service`, `systemd/*.timer` | `/usr/lib/systemd/system/` |
| `systemd/ip-monitor.sysusers` | `/usr/lib/sysusers.d/ip-monitor.conf` |
| `config.sh.sample` | `/usr/share/doc/ip-monitor/config.sh.sample` |

Both services run as the `ip-monitor` system user, sandboxed.

## Server

Set the port, the path the proxy serves the API under and the proxy's address in `/etc/ip-monitor/api.conf`, then:

```bash
systemctl enable --now ip-monitor-api.service
```

Servers are only registered on the machine itself, never through the API:

```bash
ip-monitor-admin add example.com     # prints the token, once
ip-monitor-admin rotate example.com  # new token
ip-monitor-admin list
ip-monitor-admin show example.com    # addresses and history
ip-monitor-admin remove example.com
```

`add` and `rotate` take `--token-stdin` to set a token of your own instead of generating one. Only a salted hash (scrypt) of each token is stored, in `/var/lib/ip-monitor-api/servers.json`.

A registry in the first format (`{"name": {"ip", "secret"}}`, secrets in plain text) is converted when the API starts: copy it to `/var/lib/ip-monitor-api/servers.json` first and the old secrets keep working.

### API

- `GET /ip`: the address the request came from. No credentials.
- `PUT /ip` with `Authorization: Bearer <token>` and the body `{"name": "<name>"}`: records the address for that server. Answers `200` if it's the one already recorded and `201` if it changed, both with the address in `ip`; `401` for an unknown name or a wrong token; `400` if the address isn't a public one (the proxy isn't passing it on).

## Client

The config holds the API token, the Vultr API key and the Discord webhook, so it's kept encrypted with the machine's key (`systemd-creds`) in `/etc/ip-monitor/config.sh.cred`:

```bash
ip-monitor-config edit         # starts from the sample the first time
ip-monitor-config import FILE  # encrypt an existing plain config
ip-monitor-config show
```

Test it without changing anything (no DNS update, no address removal, no Discord post, and the API is only asked):

```bash
ip-monitor --dry-run
```

Then:

```bash
systemctl enable --now ip-monitor.timer
```

The state (the last published addresses) is in `/var/lib/ip-monitor`.

### Development

To run from the repo with a plain config:

```bash
cp config.sh.sample config.sh
IP_MONITOR_CONFIG=./config.sh ./ip-monitor.sh --dry-run
```

For a real run drop `--dry-run` and set `IP_MONITOR_STATE` to a writable directory. Removing stale IPv6 addresses needs `CAP_NET_ADMIN`.
