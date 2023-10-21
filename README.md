# ip-monitor

IP monitor and DNS A record setter for Vultr. With small Discord and Speedtest integration. This is just a quick script and api I set up for personal usage.

## Requirements

For the monitor (client): `dc`, `curl`, `jq` and [`speedtest-go`](https://github.com/showwin/speedtest-go).
For the API: `uvicorn` and python's `fastapi`.

Full installation in Arch linux:

```bash
pacman -S dc curl jq uvicorn python-fastapi
yay -S speedtest-go
```

## Usage

### Client

Make a copy of `config.sh.sample` and modify accordingly:

```bash
cp config.sh.sample config.sh
```

Which needs to be next to ip-monitor.sh. To run manually once (from the root `/` dir of the repo):

```bash
./ip-monitor.sh # or bash ip-monitor.sh
```

To run in a timing basis a cronjob or systemd service/timer can be used. I provide an example with `ip-monitor.service.sample` and `ip-monitor.timer.sample`, modify accordingly.

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
