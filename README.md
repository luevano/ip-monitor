# ip-monitor

IP monitor and DNS A record setter for Vultr. With small Discord and Speedtest integration. This is just a quick script and api I set up for personal usage.

## Requirements

`curl`, `jq` and [`speedtest-go`](https://github.com/showwin/speedtest-go).

## Usage

Make a copy of `config.sh.sample` and modify accordingly:

```bash
cp config.sh.sample config.sh
```

Which needs to be next to ip-monitor.sh. To run manually once:

```bash
./ip-monitor.sh # or bash ip-monitor.sh
```

To run in a timing basis a cronjob or systemd service/timer can be used. I provide an example with `ip-moitor.service.sample` and `ip-monitor.timer.sample`, modify accordingly.
