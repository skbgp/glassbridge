#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_binary="${TMPDIR:-/tmp}/glassbridge-checks"
mkdir -p "${TMPDIR:-/tmp}/glassbridge-module-cache"
swiftc -swift-version 5 -O -parse-as-library -module-cache-path "${TMPDIR:-/tmp}/glassbridge-module-cache" "$project_root/Sources/GlassBridge/Models.swift" "$project_root/Sources/GlassBridge/ProcessRunner.swift" "$project_root/Sources/GlassBridge/AppModel.swift" "$project_root/Sources/GlassBridge/TransferPublishing.swift" "$project_root/Tests/BridgeChecks.swift" -o "$test_binary"
"$test_binary"
