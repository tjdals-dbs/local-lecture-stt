#!/bin/bash
# Local ad-hoc validation build only; no signing identity, upload or notarization.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: bash tools/t27/prepare_local_app.sh NEW_OUTPUT_DIRECTORY DERIVED_DATA_DIRECTORY" >&2
  exit 2
fi
repo_dir="$(cd "$(dirname "$0")/../.." && pwd -P)"
output_dir="$(python3 - "$1" "$repo_dir" <<'PY'
from pathlib import Path
import sys
out, repo = Path(sys.argv[1]).expanduser().resolve(), Path(sys.argv[2]).resolve()
if out.exists() or out == repo or repo in out.parents:
    raise SystemExit('Output must be a new directory outside the repository.')
print(out)
PY
)"
derived_dir="$(python3 - "$2" "$repo_dir" <<'PY'
from pathlib import Path
import sys
p, repo = Path(sys.argv[1]).expanduser().resolve(), Path(sys.argv[2]).resolve()
if p == repo or repo in p.parents:
    raise SystemExit('DerivedData must be outside the repository.')
print(p)
PY
)"
mkdir -p "$output_dir"
cd "$repo_dir"
git rev-parse HEAD > "$output_dir/source-commit.txt"
git status --porcelain > "$output_dir/source-status.txt"
xcodebuild -project LocalLectureSTT.xcodeproj -scheme LocalLectureSTT \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_dir" -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM= \
  OTHER_CODE_SIGN_FLAGS=--timestamp=none build > "$output_dir/build.log" 2>&1
app="$output_dir/LocalLectureSTT.app"
ditto "$derived_dir/Build/Products/Release/LocalLectureSTT.app" "$app"
codesign --verify --deep --strict --verbose=2 "$app" > "$output_dir/signature-check.txt" 2>&1
codesign --display --entitlements :- "$app" > "$output_dir/entitlements.plist" 2> "$output_dir/signature-details.txt"
python3 -B tools/verify_product_engine.py "$app" > "$output_dir/product-engine.txt"
python3 - "$app" "$output_dir/entitlements.plist" <<'PY'
import plistlib, sys
from pathlib import Path
app = Path(sys.argv[1])
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
ent = plistlib.loads(Path(sys.argv[2]).read_bytes())
assert info['LSMinimumSystemVersion'] == '15.0', info.get('LSMinimumSystemVersion')
assert info.get('NSMicrophoneUsageDescription')
for key in ['app-sandbox', 'device.audio-input', 'files.user-selected.read-write', 'files.bookmarks.app-scope']:
    assert ent.get('com.apple.security.' + key) is True, key
print('Local validation app ready:', app)
print('Ad-hoc signing only. Gatekeeper distribution, notarization and microphone permission are not verified.')
PY
