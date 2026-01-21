#!/bin/bash
# build.sh - Simple RPM build script

set -e

# Configuration
NAME="cpu-manager"
VERSION="6.0"
RELEASE="1"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Building CPU Manager RPM ===${NC}"

# Check dependencies
echo "Checking dependencies..."
command -v rpmbuild >/dev/null 2>&1 || {
    echo -e "${RED}Error: rpmbuild not found${NC}"
    echo "Install with: sudo dnf install rpm-build"
    exit 1
}

# Clean previous builds
echo "Cleaning previous builds..."
rm -rf ~/rpmbuild/BUILD/* ~/rpmbuild/BUILDROOT/* ~/rpmbuild/RPMS/* ~/rpmbuild/SOURCES/* ~/rpmbuild/SRPMS/* 2>/dev/null || true

# Create source tarball
echo "Creating source tarball..."
mkdir -p ~/rpmbuild/SOURCES
tar -czf ~/rpmbuild/SOURCES/${NAME}-${VERSION}.tar.gz \
    --transform "s,^,${NAME}-${VERSION}/," \
    cpu-manager.sh \
    cpu-manager.conf \
    cpu-manager.service \
    README.md \
    LICENSE

# Copy spec file
cp cpu-manager.spec ~/rpmbuild/SPECS/

# Build RPM
echo "Building RPM..."
rpmbuild -ba \
    --define "_version ${VERSION}" \
    --define "_release ${RELEASE}" \
    ~/rpmbuild/SPECS/cpu-manager.spec

# Check result
if [ $? -eq 0 ]; then
    RPM_FILE=$(find ~/rpmbuild/RPMS -name "*.rpm" | head -1)
    echo -e "${GREEN}=== RPM built successfully! ===${NC}"
    echo "RPM file: ${RPM_FILE}"
    echo ""
    echo "To install: sudo rpm -Uvh ${RPM_FILE}"
    echo "To test:     sudo rpm -Uvh --test ${RPM_FILE}"
    
    # Show package info
    echo ""
    echo "Package information:"
    rpm -qpi "${RPM_FILE}"
else
    echo -e "${RED}=== RPM build failed ===${NC}"
    exit 1
  fi
