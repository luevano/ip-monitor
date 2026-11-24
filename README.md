# ip-monitor

IP monitor and DNS A/AAAA record setter for Vultr. With small Discord and Speedtest integration. This is just a quick script and api I set up for personal usage.

What the monitor (client) does on each run:

- IPv4: asks the API for the public address and updates the A record when it changed.
- IPv6: tests each public address of the interface, removes the ones that stopped working (left over from an old ISP prefix) and updates the AAAA record when the address changed.
- Posts changes and failures to Discord, with a speedtest on an IPv4 change.

A record is only marked as updated once Vultr accepted it, so a failed update is retried on the next run.

## Requirements

For the monitor (client): `curl`, `jq`, `iproute2`, `gawk`, `util-linux` and optionally [`speedtest-go`](https://github.com/showwin/speedtest-go).
For the API: `uvicorn` and python's `fastapi`.

Full installation in Arch linux:

```bash
pacman -S curl jq iproute2 gawk uvicorn python-fastapi
yay -S speedtest-go
```

## Usage

### Client

Make a copy of `config.sh.sample` and modify accordingly:

```bash
cp config.sh.sample config.sh
```

To run manually once, without changing anything (no DNS update, no address removal, no Discord post):

```bash
IP_MONITOR_CONFIG=./config.sh ./ip-monitor.sh --dry-run
```

For a real run drop `--dry-run` and set `IP_MONITOR_STATE` to a writable directory. Removing stale IPv6 addresses needs `CAP_NET_ADMIN`.

#### As a systemd service

The `systemd/` directory has a hardened service, a timer and the `ip-monitor` system user. They expect:

- the script at `/usr/bin/ip-monitor`,
- the config at `/etc/ip-monitor/config.sh`, owned by root with mode `600` (systemd passes it to the service),
- the state in `/var/lib/ip-monitor`, which systemd creates.

Then:

```bash
systemctl enable --now ip-monitor.timer
```

### API

Make a copy of `config.py.sample` and modify accordingly:

```bash
cp config.py.sample config.py
```

Also needs to be next to ip-monitor-api.py. To run manually (from the `/api` dir of the repo):

```bash
uvicorn ip-monitor-api:app --app-dir /path/to/ip-monitor/root/dir/api --port <PORT>
```

Or to run as a daemon in systemd you can use the provided `ip-monitor-api.service.sample`, modify accordingly.
