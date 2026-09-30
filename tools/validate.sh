#!/bin/sh
set -e
dir="$(cd "$(dirname "$0")/ooxml-validate" && pwd)"
dll="$dir/bin/ooxml-validate.dll"
if [ ! -f "$dll" ] || [ -n "$(find "$dir" -maxdepth 1 \( -name '*.cs' -o -name '*.csproj' \) -newer "$dll")" ]; then
  DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 dotnet build "$dir" -c Release -o "$dir/bin" --nologo -v q >&2
fi
exec dotnet "$dll" "$@"
