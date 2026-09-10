#!/bin/bash
set -euo pipefail

usage_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$usage_root"
usage_tmp="$(mktemp -d /tmp/codexbar-usage-check.XXXXXXXX)"
trap 'rm -rf "$usage_tmp"' EXIT

python3 -B -m unittest discover -s Tests -p 'test_usage_*.py' -v
usage_compiler="${CODEXBAR_SWIFTC:-swiftc}"
usage_sdk="$(xcrun --show-sdk-path)"
usage_flags=(-sdk "$usage_sdk" -swift-version 6 -parse-as-library)
if "$usage_compiler" -help | rg -- '-default-isolation' > /dev/null; then
    usage_flags+=(-default-isolation MainActor)
fi

"$usage_compiler" "${usage_flags[@]}" \
    CodexBar/Models/UsageCenterModels.swift \
    CodexBar/Models/UsageValuationModels.swift \
    CodexBar/Services/UsageCenter/UsageCenterStore.swift \
    Tests/UsageCenterSmoke.swift -o "$usage_tmp/store-tests"
"$usage_tmp/store-tests"

"$usage_compiler" "${usage_flags[@]}" \
    CodexBar/Models/UsageCenterModels.swift \
    CodexBar/Models/UsageValuationModels.swift \
    CodexBar/Services/UsageCenter/UsageCenterStore.swift \
    CodexBar/Services/UsageCenter/UsageCollectorClient.swift \
    CodexBar/Services/Process/ProcessTermination.swift \
    Tests/UsageCommandSmoke.swift -o "$usage_tmp/command-tests"
"$usage_tmp/command-tests"

"$usage_compiler" "${usage_flags[@]}" \
    CodexBar/Models/UsageCenterModels.swift \
    CodexBar/Models/UsageValuationModels.swift \
    CodexBar/Services/UsageCenter/UsageCenterStore.swift \
    CodexBar/Services/UsageCenter/UsageAnalyticsParser.swift \
    CodexBar/Services/UsageCenter/UsageAnalyticsValuation.swift \
    CodexBar/Services/UsageCenter/UsageModelAllocation.swift \
    Tests/UsageAnalyticsSmoke.swift -o "$usage_tmp/analytics-tests"
"$usage_tmp/analytics-tests"

"$usage_compiler" "${usage_flags[@]}" \
    CodexBar/Controllers/MenuHostingController.swift \
    Tests/UsageMenuLayoutSmoke.swift -o "$usage_tmp/menu-layout-tests"
"$usage_tmp/menu-layout-tests"

"$usage_compiler" "${usage_flags[@]}" \
    CodexBar/Services/Support/RefreshTaskCoordinator.swift \
    Tests/RefreshSleepSmoke.swift -o "$usage_tmp/refresh-sleep-tests"
"$usage_tmp/refresh-sleep-tests"
