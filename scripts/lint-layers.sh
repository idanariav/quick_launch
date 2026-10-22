#!/bin/bash
# Enforces the import rules from docs/ARCHITECTURE.md §3 that Package.swift can't:
# Apple frameworks are always importable, so nothing stops QLCore from importing
# AppKit, or a module from importing a framework it shouldn't. This does.
set -euo pipefail
cd "$(dirname "$0")/../Packages/QuickLaunchKit/Sources"

status=0

# check <target directory> <regex of allowed imports>
check() {
    local bad
    bad=$(grep -rhoE '^(@testable )?import [A-Za-z_.]+' "$1" | awk '{print $NF}' | sort -u | grep -vxE "$2" || true)
    if [[ -n "$bad" ]]; then
        echo "✘ $1 imports forbidden module(s): $(echo "$bad" | tr '\n' ' ')"
        status=1
    fi
}

# Core: pure logic. Carbon.HIToolbox only for virtual key code constants.
check QLCore 'Foundation|Observation|os|Carbon\.HIToolbox'
# Modules: Core, Observation (state the app renders, decision 0007), and the OS
# frameworks their own adapters need (EventKit: QLModuleCalendar, decision 0024); never
# another QL target.
for module in QLModule*; do
    check "$module" 'Foundation|Observation|os|QLCore|AppKit|ApplicationServices|CoreGraphics|Carbon\.HIToolbox|EventKit'
done

if [[ $status -eq 0 ]]; then echo "✔ layer imports OK"; fi
exit $status
