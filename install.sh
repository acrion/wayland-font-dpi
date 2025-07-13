#!/usr/bin/env bash
# Copyright (c) 2025 acrion innovations GmbH
# Authors: Stefan Zipproth, s.zipproth@acrion.ch
#
# This file is part of wayland-font-dpi, see https://github.com/acrion/wayland-font-dpi
#
# wayland-font-dpi is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# wayland-font-dpi is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with wayland-font-dpi. If not, see <https://www.gnu.org/licenses/>.

# Installation script for wayland-font-dpi

set -euo pipefail

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (use sudo)" 
   exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Installing wayland-font-dpi...${NC}"

# Check if required binaries exist
REQUIRED_BINARIES=(
    "wayland-font-dpi"
    "wayland-font-dpi-session"
)

for binary in "${REQUIRED_BINARIES[@]}"; do
    if [[ ! -f "$binary" ]]; then
        echo -e "${RED}Error: Required binary '$binary' not found!${NC}"
        exit 1
    fi
done

# Check if required files exist
REQUIRED_FILES=(
    "wayland-font-dpi.service"
    "wayland-font-dpi-session.service"
    "README.md"
    "LICENSE"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
        echo -e "${RED}Error: Required file '$file' not found!${NC}"
        exit 1
    fi
done

# Check if wayland-display-info is installed
if ! systemctl list-unit-files --user | grep -q "wayland-display-info.service"; then
    echo -e "${YELLOW}Warning: wayland-display-info service not found!${NC}"
    echo "This package depends on https://github.com/acrion/wayland-display-info. Please install it first."
    exit 1
fi

# Install executables
echo "Installing executables..."
install -Dm755 wayland-font-dpi         /usr/lib/wayland-font-dpi/wayland-font-dpi
install -Dm755 wayland-font-dpi-session /usr/lib/wayland-font-dpi/wayland-font-dpi-session

# Install systemd services
echo "Installing systemd services..."
install -Dm644 wayland-font-dpi.service         /usr/lib/systemd/system/wayland-font-dpi.service
install -Dm644 wayland-font-dpi-session.service /usr/lib/systemd/user/wayland-font-dpi-session.service

# Install documentation
echo "Installing documentation..."
install -Dm644 README.md /usr/share/doc/wayland-font-dpi/README.md
install -Dm644 LICENSE   /usr/share/licenses/wayland-font-dpi/LICENSE

echo "Installing man page..."
install -Dm644 wayland-font-dpi.1 /usr/share/man/man1/wayland-font-dpi.1

# Reload systemd
echo "Reloading systemd..."
systemctl daemon-reload

# Enable services
echo "Enabling services..."
systemctl enable wayland-font-dpi.service
systemctl --global enable wayland-font-dpi-session.service

echo -e "${GREEN}Installation complete!${NC}"
echo
echo -e "${YELLOW}Important:${NC} Please log out and log back in for the changes to take effect."
echo
echo "You can check the service status with:"
echo "  systemctl status wayland-font-dpi.service"
echo "  systemctl --user status wayland-display-info.service"
echo "  systemctl --user status wayland-font-dpi-session.service"
echo
echo "View logs with:"
echo "  journalctl -t wayland-font-dpi"