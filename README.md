# CPU Manager

Dynamic CPU resource management tool using cgroups v2.

## Features

- **Dynamic CPU limiting** for non-system users (UID 1000-60000)
- **Configurable thresholds** for activation and release
- **Absolute CPU limits** using `cpu.max` cgroup controller
- **Prometheus metrics** export (file-based for node_exporter)
- **Systemd service** integration
- **Automatic cleanup** on exit
- **Log rotation** and configurable log levels

## Installation

### From RPM
```bash
sudo rpm -ivh cpu-manager-6.0-1.noarch.rpm
