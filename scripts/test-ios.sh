#!/bin/bash
set -euo pipefail

ZSUBLAYER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ZSUBLAYER_ROOT"

# Select a process-local toolchain; don't change the machine's xcode-select setting.
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(python3 - <<'PY'
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

ZSUBLAYER_ARTIFACTS="$ZSUBLAYER_ROOT/.build/validation/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$ZSUBLAYER_ARTIFACTS"
export CLANG_MODULE_CACHE_PATH="$ZSUBLAYER_ARTIFACTS/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"

xcodebuild -version | tee "$ZSUBLAYER_ARTIFACTS/toolchain.log"
swift --version | tee -a "$ZSUBLAYER_ARTIFACTS/toolchain.log"
spm_options=(--cache-path "$ZSUBLAYER_ARTIFACTS/PackageCache")
# Opt in only for environments which prohibit SwiftPM's nested sandbox.
if [[ "${ZSUBLAYER_DISABLE_SPM_SANDBOX:-0}" == "1" ]]; then
    spm_options+=(--disable-sandbox)
fi
swift package "${spm_options[@]}" resolve 2>&1 | tee "$ZSUBLAYER_ARTIFACTS/resolve.log"
swift package "${spm_options[@]}" dump-package > "$ZSUBLAYER_ARTIFACTS/package.json"

ZSUBLAYER_SIMULATOR_ID="${ZSUBLAYER_SIMULATOR_ID:-$(python3 - <<'PY'
import json, re, subprocess
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
candidates = []
for runtime, entries in devices.items():
    if '.iOS-' not in runtime:
        continue
    version = tuple(map(int, re.findall(r'\d+', runtime.rsplit('iOS-', 1)[1])))
    if version < (17,):
        continue
    for device in entries:
        if device.get('isAvailable') and device['name'].startswith('iPhone'):
            candidates.append((device.get('state') == 'Booted', version, device['udid']))
if not candidates:
    raise SystemExit('Install an iOS 17+ iPhone simulator to run the StoreKitTest suite')
print(max(candidates)[2])
PY
)}"

project_options=(-project Examples/DemoApp/DemoApp.xcodeproj -scheme DemoApp
    -destination "platform=iOS Simulator,id=$ZSUBLAYER_SIMULATOR_ID"
    -derivedDataPath "$ZSUBLAYER_ARTIFACTS/DerivedData"
    -clonedSourcePackagesDirPath "$ZSUBLAYER_ROOT/.build"
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile
    CODE_SIGNING_ALLOWED=NO)

xcodebuild "${project_options[@]}" build 2>&1 | tee "$ZSUBLAYER_ARTIFACTS/build.log"
xcodebuild "${project_options[@]}" -parallel-testing-enabled NO \
    -resultBundlePath "$ZSUBLAYER_ARTIFACTS/Tests.xcresult" test 2>&1 | tee "$ZSUBLAYER_ARTIFACTS/test.log"
printf 'Validation artifacts: %s\n' "$ZSUBLAYER_ARTIFACTS"
