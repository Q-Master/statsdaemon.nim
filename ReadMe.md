# Pure Nim implementation of StatsD-compatible daemon
This work is based upon the [bitly go statsd implementaion](https://github.com/bitly/statsdaemon).

## Currently supported:
| Type        | Status             |  Notes |
|------------:|:-------------------|:-------|
| timers      |       WORKING      |        |
| counters    |       WORKING      |        |
| sets        |       WORKING      |        |
| gauge       |       WORKING      |        |

## Configuring the daemon
Daemon is supporting the ini format config.
Filename is **statsd.ini**

### example:
```ini
address = 0.0.0.0:8125
graphite = 127.0.0.1:2003
delete-gauges = true
flush-interval = 10
persist-count-keys = 60
```
### supported parameters:
| Parameter name | Description | Default value |
|:--------------:|:------------|:--------------:|
| address | UDP socket address on which daemon will listen incoming packets  |    0.0.0.0:8125    |
| tcpaddr | TCP socket address on which daemon will listen incoming packets  |  empty (**disabled**) |
| graphite | Address of graphite instance | 127.0.0.1:2003 |
| delete-gauges | Will clear gauges after sending to graphite | true |
| flush-interval | Interval in seconds to send data to graphite | 10 |
| prefix | Prefix which will be added to all metrics | empty (**disabled**) |
| postfix | Postfix which will be added to all metrics | empty (**disabled**) |
| persist-count-keys | Iterations to wait before delete the counter from the metrics if inactive | 60 |
| percentiles | Percentile settings for timers as a list of numbers split by comma (e.x. 80,90,95) | empty (**disabled**) |


## Building and installation
To build this daemon you either should install nim toolchain see [Nim installation](https://nim-lang.org/install.html) or use a supplied docker file.

### Manual building
To build daemon you should use

**Debug mode**
```bash
nimble build
```

**Release mode**
```bash
nimble build -d:release -l:"-flto" -t:"-flto" --opt:size --threads:on
objcopy --strip-all -R .comment -R .comments  statsdaemon
```

### Docker building
Docker building requires the preconfigured statsd.ini file to be in the current directory.
```bash
docker build --target release -t statsdaemon .
```