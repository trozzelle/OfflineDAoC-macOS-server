#!/usr/bin/env bash
# setup-dotnet.sh - one-time installer for the .NET 10 SDK used by tools/build-release.sh.
# Installs into ~/.dotnet (user-local, no sudo). Safe to re-run.
set -euo pipefail

DOTNET_DIR="$HOME/.dotnet"

if [[ -x "$DOTNET_DIR/dotnet" ]] && "$DOTNET_DIR/dotnet" --list-sdks 2>/dev/null | grep -q '^10\.'; then
  echo "setup-dotnet: .NET 10 SDK already installed at $DOTNET_DIR"
  exit 0
fi

curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
bash /tmp/dotnet-install.sh --channel 10.0 --install-dir "$DOTNET_DIR"

"$DOTNET_DIR/dotnet" --version
echo "setup-dotnet: done. The build script finds it automatically (DOTNET_ROOT=~/.dotnet)."