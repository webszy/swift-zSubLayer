#!/bin/bash
set -euo pipefail

ZSUBLAYER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ZSUBLAYER_ROOT"

ZSUBLAYER_ARTIFACTS="$ZSUBLAYER_ROOT/.build/validation/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$ZSUBLAYER_ARTIFACTS"
trap 'result=$?; printf "Validation exit status: %s; artifacts: %s\n" "$result" "$ZSUBLAYER_ARTIFACTS"; exit "$result"' EXIT
# Keep early failures diagnosable; a missing phase must not look like a passed phase.
for phase in resolve build test; do
    printf 'Phase not started. See toolchain.log, simulator.log and resolve.log.\n' > "$ZSUBLAYER_ARTIFACTS/$phase.log"
done

# Select a process-local toolchain; don't change the machine's xcode-select setting.
DEVELOPER_DIR="${DEVELOPER_DIR:-$(python3 - <<'PY'
from pathlib import Path
import subprocess
selected = subprocess.run(['xcode-select', '-p'], capture_output=True, text=True).stdout.strip()
if selected and (Path(selected) / 'Platforms/iPhoneSimulator.platform').exists():
    print(selected)
else:
    candidates = sorted(Path('/Applications').glob('Xcode*.app'), reverse=True)
    candidates += sorted((Path.home() / 'Applications').glob('Xcode*.app'), reverse=True)
    for app in candidates:
        developer = app / 'Contents/Developer'
        if (developer / 'Platforms/iPhoneSimulator.platform').exists():
            print(developer)
            break
    else:
        raise SystemExit('No installed Xcode with an iOS Simulator SDK')
PY
)}"
export DEVELOPER_DIR

export CLANG_MODULE_CACHE_PATH="$ZSUBLAYER_ARTIFACTS/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"

{
    printf 'DEVELOPER_DIR=%s\n' "$DEVELOPER_DIR"
    xcodebuild -version
    swift --version
    xcrun --sdk iphonesimulator --show-sdk-version
    xcrun simctl list runtimes
    xcrun simctl list devices available
} 2>&1 | tee "$ZSUBLAYER_ARTIFACTS/toolchain.log"
if [[ -n "${ZSUBLAYER_EXPECTED_XCODE_VERSION:-}" ]]; then
    if ! grep -Fxq "Xcode $ZSUBLAYER_EXPECTED_XCODE_VERSION" "$ZSUBLAYER_ARTIFACTS/toolchain.log"; then
        printf 'Expected Xcode %s; refusing to test with a different toolchain.\n' "$ZSUBLAYER_EXPECTED_XCODE_VERSION" | tee -a "$ZSUBLAYER_ARTIFACTS/toolchain.log" >&2
        exit 1
    fi
fi
spm_options=(--cache-path "$ZSUBLAYER_ARTIFACTS/PackageCache"
    --scratch-path "$ZSUBLAYER_ARTIFACTS/SwiftPM"
    --only-use-versions-from-resolved-file)
# Opt in only for environments which prohibit SwiftPM's nested sandbox.
if [[ "${ZSUBLAYER_DISABLE_SPM_SANDBOX:-0}" == "1" ]]; then
    spm_options+=(--disable-sandbox)
fi
swift package "${spm_options[@]}" resolve 2>&1 | tee "$ZSUBLAYER_ARTIFACTS/resolve.log"
swift package "${spm_options[@]}" dump-package > "$ZSUBLAYER_ARTIFACTS/package.json" 2>> "$ZSUBLAYER_ARTIFACTS/resolve.log"

project_options=(-project Examples/DemoApp/DemoApp.xcodeproj -scheme DemoApp
    -configuration Debug
    -derivedDataPath "$ZSUBLAYER_ARTIFACTS/DerivedData"
    -clonedSourcePackagesDirPath "$ZSUBLAYER_ARTIFACTS/SourcePackages"
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile
    CODE_SIGNING_ALLOWED=NO)
# Xcode has its own package workspace. Populate it explicitly on a fresh runner;
# a successful `swift package resolve` alone does not populate this directory.
xcodebuild "${project_options[@]}" -resolvePackageDependencies 2>&1 | tee -a "$ZSUBLAYER_ARTIFACTS/resolve.log"
xcodebuild "${project_options[@]}" -showdestinations 2>&1 | tee "$ZSUBLAYER_ARTIFACTS/destinations.log"
xcrun simctl list -j > "$ZSUBLAYER_ARTIFACTS/simulators.json" 2> "$ZSUBLAYER_ARTIFACTS/simulator.log"

# Validate overrides too. simctl's "available" list can include newer runtimes
# installed for another Xcode, including ones shown by -showdestinations.
ZSUBLAYER_SIMULATOR_ID="$(python3 - "$ZSUBLAYER_ARTIFACTS" <<'PY'
import json, os, re, subprocess, sys
from pathlib import Path

artifacts = Path(sys.argv[1])
inventory = json.loads((artifacts / 'simulators.json').read_text())
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True).strip()
def version(value):
    return tuple((list(map(int, value.split('.'))) + [0, 0])[:2])

sdk_version = version(sdk)
destinations = (artifacts / 'destinations.log').read_text()
available = destinations.split('Available destinations for', 1)[-1].split('Ineligible destinations for', 1)[0]
destination_ids = set(re.findall(r'platform:iOS Simulator,.*?id:([0-9A-Fa-f-]{36})[, }]', available))
runtimes = {r['identifier']: r for r in inventory['runtimes'] if r.get('isAvailable')}
candidates = []
for runtime_id, entries in inventory['devices'].items():
    runtime = runtimes.get(runtime_id)
    if not runtime or '.iOS-' not in runtime_id:
        continue
    runtime_version = version(runtime['version'])
    # Conservatively stay at or below the selected SDK major/minor version.
    if not (version('17.0') <= runtime_version <= sdk_version):
        continue
    for device in entries:
        if (device.get('isAvailable') and device['name'].startswith('iPhone')
                and device['udid'] in destination_ids):
            candidates.append((runtime_version, device.get('state') == 'Booted', device['udid'], device['name'], runtime['version']))
requested = os.environ.get('ZSUBLAYER_SIMULATOR_ID')
if requested:
    candidates = [c for c in candidates if c[2] == requested]
if not candidates:
    raise SystemExit(f'No compatible iOS 17+ iPhone simulator for SDK {sdk}'
                     + (f' (requested {requested})' if requested else '')
                     + '; see simulators.json and destinations.log')
selected = max(candidates)
print(f'Selected {selected[3]} / iOS {selected[4]} / {selected[2]} (SDK {sdk})', file=sys.stderr)
print(selected[2])
PY
)" 2>> "$ZSUBLAYER_ARTIFACTS/simulator.log"
cat "$ZSUBLAYER_ARTIFACTS/simulator.log"
xcrun simctl bootstatus "$ZSUBLAYER_SIMULATOR_ID" -b 2>&1 | tee -a "$ZSUBLAYER_ARTIFACTS/simulator.log"

project_options+=(-destination "platform=iOS Simulator,id=$ZSUBLAYER_SIMULATOR_ID"
    -destination-timeout 120)

xcodebuild "${project_options[@]}" build 2>&1 | tee "$ZSUBLAYER_ARTIFACTS/build.log"
xcodebuild "${project_options[@]}" -parallel-testing-enabled NO \
    -resultBundlePath "$ZSUBLAYER_ARTIFACTS/Tests.xcresult" test 2>&1 | tee "$ZSUBLAYER_ARTIFACTS/test.log"
printf 'Validation artifacts: %s\n' "$ZSUBLAYER_ARTIFACTS"
