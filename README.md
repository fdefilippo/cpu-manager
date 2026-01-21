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

## Prerequisites

### Enabling cgroups v2 on RHEL/CentOS 8+

CPU Manager requires cgroups v2 with CPU and cpuset controllers enabled. To activate them:

**Method 1: One-time kernel parameter (requires reboot)**
```bash
# Enable unified cgroup hierarchy
grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=1"
reboot

# After reboot, enable CPU controllers
echo "+cpu" >> /sys/fs/cgroup/cgroup.subtree_control
echo "+cpuset" >> /sys/fs/cgroup/cgroup.subtree_control
```

**Method 2: Persistent via systemd service**
Create `/etc/systemd/system/cgroup-tweaks.service`:
```ini
[Unit]
Description=Configure cgroup subtree controls
Before=systemd-user-sessions.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo "+cpu" >> /sys/fs/cgroup/cgroup.subtree_control'
ExecStart=/bin/sh -c 'echo "+cpuset" >> /sys/fs/cgroup/cgroup.subtree_control'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Then enable the service:
```bash
systemctl daemon-reload
systemctl enable --now cgroup-tweaks.service
```

**Method 3: System-wide accounting (alternative approach)**
Edit `/etc/systemd/system.conf`:
```ini
DefaultCPUAccounting=yes
DefaultMemoryAccounting=yes
```

Then reload systemd:
```bash
systemctl daemon-reexec
```

## Installation

### From RPM
```bash
sudo rpm -ivh cpu-manager-6.0-1.noarch.rpm
```

The RPM package will automatically install and configure the CPU Manager service. Ensure cgroups v2 is enabled using one of the methods above before starting the service.
