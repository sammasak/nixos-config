#!/usr/bin/env bash
# Fix Neovim Home Manager directory permissions

set -euo pipefail

echo "Fixing Neovim directory..."

# Remove the problematic nvim directory
sudo rm -rf /home/lukas/.config/nvim

# Restart Home Manager to recreate it properly
sudo systemctl restart home-manager-lukas.service

# Check status
sudo systemctl status home-manager-lukas.service --no-pager

echo ""
echo "Done! Neovim directory should now be properly managed by Home Manager."
