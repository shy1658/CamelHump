#!/usr/bin/env bash
# Runs the GGUF parser self-test on the host (no device, no OHOS SDK needed).
set -euo pipefail
cd "$(dirname "$0")"

CPP_DIR="../../entry/src/main/cpp"

python3 gen_fixtures.py

CXX="${CXX:-c++}"
"$CXX" -std=c++17 -O2 -Wall -Wextra -I"$CPP_DIR" \
  main.cpp "$CPP_DIR/gguf_inspector.cpp" -o inspector

./inspector ./fixtures
