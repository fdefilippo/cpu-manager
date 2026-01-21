PKG_NAME=cpu-manager
VERSION=6.0
RELEASE=1
ARCH=noarch

SOURCES = \
	cpu-manager.sh \
	cpu-manager.conf \
	cpu-manager.service \
	README.md \
	LICENSE

SPEC_FILE = cpu-manager.spec
TARBALL = $(PKG_NAME)-$(VERSION).tar.gz
RPM_FILE = rpmbuild/RPMS/$(ARCH)/$(PKG_NAME)-$(VERSION)-$(RELEASE).$(ARCH).rpm
SRPM_FILE = rpmbuild/SRPMS/$(PKG_NAME)-$(VERSION)-$(RELEASE).src.rpm

.PHONY: all clean prepare build rpm srpm install test

all: rpm

prepare:
	@echo "Preparing sources..."
	mkdir -p $(PKG_NAME)-$(VERSION)
	cp $(SOURCES) $(PKG_NAME)-$(VERSION)/
	cp $(SPEC_FILE) $(PKG_NAME)-$(VERSION)/
	tar -czf $(TARBALL) $(PKG_NAME)-$(VERSION)/
	rm -rf $(PKG_NAME)-$(VERSION)
	mkdir -p rpmbuild/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
	mv -f $(TARBALL) rpmbuild/SOURCES/ 2>/dev/null || true

build: prepare
	@echo "Building RPM..."
	rpmbuild -ba \
		--define "_topdir $(PWD)/rpmbuild" \
		--define "_version $(VERSION)" \
		--define "_release $(RELEASE)" \
		rpmbuild/SOURCES/$(PKG_NAME)-$(VERSION)/$(SPEC_FILE) 2>/dev/null || \
	rpmbuild -ba \
		--define "_topdir $(PWD)/rpmbuild" \
		--define "_version $(VERSION)" \
		--define "_release $(RELEASE)" \
		$(SPEC_FILE)

rpm: build
	@echo "RPM built: $(RPM_FILE)"
	@ls -la rpmbuild/RPMS/$(ARCH)/*.rpm

srpm: prepare
	@echo "Building SRPM..."
	rpmbuild -bs \
		--define "_topdir $(PWD)/rpmbuild" \
		--define "_version $(VERSION)" \
		--define "_release $(RELEASE)" \
		$(SPEC_FILE)
	@echo "SRPM built: $(SRPM_FILE)"

install: rpm
	@echo "Installing RPM..."
	sudo rpm -Uvh --force $(RPM_FILE)

test-install: rpm
	@echo "Testing installation (dry-run)..."
	sudo rpm -Uvh --test $(RPM_FILE)

verify: rpm
	@echo "Verifying RPM..."
	rpm -qpi $(RPM_FILE)
	@echo ""
	@echo "Package contents:"
	rpm -qpl $(RPM_FILE)

clean:
	@echo "Cleaning build files..."
	rm -rf $(PKG_NAME)-* *.tar.gz rpmbuild

distclean: clean
	@echo "Cleaning distribution files..."
	rm -f *.rpm

help:
	@echo "Available targets:"
	@echo "  all        - Build RPM (default)"
	@echo "  rpm        - Build binary RPM"
	@echo "  srpm       - Build source RPM"
	@echo "  install    - Install RPM"
	@echo "  test       - Test installation (dry-run)"
	@echo "  verify     - Verify RPM contents"
	@echo "  clean      - Clean build files"
	@echo "  distclean  - Clean everything"
	@echo "  help       - Show this help"
