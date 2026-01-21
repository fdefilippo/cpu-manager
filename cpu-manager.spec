Name:           cpu-manager
Version:        6.0
Release:        1%{?dist}
Summary:        Dynamic CPU management with cgroups v2
License:        MIT
URL:            https://github.com/your-org/cpu-manager
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch

Requires:       bash >= 4.0
Requires(post): systemd
Requires(preun): systemd

%description
CPU Manager is a dynamic CPU resource management tool that uses cgroups v2
to automatically limit CPU usage for non-system users when the system is
under load. It provides configurable thresholds, Prometheus metrics export,
and systemd integration.

%prep
%setup -q

%build
# Nothing to build for shell script

%install
# Create directories
install -d %{buildroot}/etc
install -d %{buildroot}/usr/local/sbin
install -d %{buildroot}/etc/systemd/system
install -d %{buildroot}/usr/local/share/cpu-manager
install -d %{buildroot}/var/run/cpu-manager

# Install main script
install -m 0755 cpu-manager.sh %{buildroot}/usr/local/sbin/cpu-manager

# Install configuration file
install -m 0644 cpu-manager.conf %{buildroot}/etc/cpu-manager.conf

# Install systemd service file
install -m 0644 cpu-manager.service %{buildroot}/etc/systemd/system/

# Install README
install -m 0644 README.md %{buildroot}/usr/local/share/cpu-manager/

%post
# Systemd service registration
%systemd_post cpu-manager.service

# Check for existing config on first install
if [ $1 -eq 1 ] && [ ! -f /etc/cpu-manager.conf ]; then
    cp /etc/cpu-manager.conf.rpmnew /etc/cpu-manager.conf 2>/dev/null || :
    echo "Configuration file created: /etc/cpu-manager.conf"
fi

echo "=================================================="
echo "CPU Manager v%{version} installed successfully!"
echo ""
echo "Configuration: /etc/cpu-manager.conf"
echo "Main script:   /usr/local/sbin/cpu-manager"
echo "Service:       systemctl {start|stop|status} cpu-manager"
echo "Logs:          journalctl -u cpu-manager -f"
echo ""
echo "Edit /etc/cpu-manager.conf for your needs."
echo "=================================================="

%preun
%systemd_preun cpu-manager.service

%postun
%systemd_postun_with_restart cpu-manager.service

%clean
rm -rf %{buildroot}

%files
%license LICENSE
%doc /usr/local/share/cpu-manager/README.md
%config(noreplace) /etc/cpu-manager.conf
%attr(0755,root,root) /usr/local/sbin/cpu-manager
%attr(0644,root,root) /etc/systemd/system/cpu-manager.service
%dir %attr(0755,root,root) /var/run/cpu-manager

%changelog
* Wed Jan 21 2026 Francesco Defilippo <francesco@defilippo.org> - 6.0-1
- Initial RPM package release
- Dynamic CPU management with cgroups v2
- Configurable thresholds and limits
- Prometheus metrics support
- Systemd service integration
