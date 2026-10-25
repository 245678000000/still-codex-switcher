#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist/win-x64}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_GENERATE_ASPNET_CERTIFICATE=false
# On macOS/File Provider folders, stage source in /private/tmp before building.
dotnet run --project "$ROOT/Tests/Still.Tests.csproj" -c Release
dotnet publish "$ROOT/Windows/Still.Windows.csproj" -c Release -r win-x64 --self-contained true -p:RuntimeFrameworkVersion=8.0.32 -o "$OUT"
printf 'Built Windows executable: %s/StillCodexSwitcher.exe\n' "$OUT"
