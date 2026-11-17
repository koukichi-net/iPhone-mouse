# Shared settings for the HIDPad scripts (sourced, not run).
# Personal values (device UDID, Apple development team ID) live in scripts/local.env,
# which is not tracked by git; copy scripts/local.env.example to create it.
# They can also be given as environment variables, and the UDID with --udid <UDID>.
# --release selects the Release build (no self-tests, probes or log; own build directory
# App/build/release); the default is the Debug build in App/build.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/App"
BUILD_DIR="$APP_DIR/build"
SCHEME=HIDPad
BUNDLE_ID=dev.koukichi.hidpad
_env_udid="${UDID:-}"
_env_team="${DEVELOPMENT_TEAM:-}"
if [[ -f "$ROOT/scripts/local.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT/scripts/local.env"
fi
UDID="${_env_udid:-${UDID:-}}"
DEVELOPMENT_TEAM="${_env_team:-${DEVELOPMENT_TEAM:-}}"
CONFIG=Debug
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) UDID="$2"; shift 2 ;;
    --release) CONFIG=Release; shift ;;
    *) break ;;
  esac
done
if [[ -z "$UDID" ]]; then
  echo "UDID is not set. Copy scripts/local.env.example to scripts/local.env and fill it in, or pass --udid <UDID>." >&2
  exit 2
fi
export UDID DEVELOPMENT_TEAM
if [[ $CONFIG == Release ]]; then DERIVED_DIR="$BUILD_DIR/release"; else DERIVED_DIR="$BUILD_DIR"; fi
APP_PATH="$DERIVED_DIR/Build/Products/$CONFIG-iphoneos/$SCHEME.app"
