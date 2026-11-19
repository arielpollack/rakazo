#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sources=()
while IFS= read -r -d '' source; do
  sources+=("$source")
done < <(find App -type f -name '*.swift' ! -name RakazoApp.swift -print0)
swiftc -whole-module-optimization "${sources[@]}" "$1" -o "$2"
