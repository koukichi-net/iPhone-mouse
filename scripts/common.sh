# Shared settings for the HIDPad scripts (sourced, not run).
# Personal values (device UDID, Apple development team ID) live in scripts/local.env,
# which is not tracked by git; copy scripts/local.env.example to create it.
# They can also be given as environment variables, and the UDID with --udid <UDID>.
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
if [[ "${1:-}" == "--udid" ]]; then UDID="$2"; shift 2; fi
if [[ -z "$UDID" ]]; then
  echo "UDID is not set. Copy scripts/local.env.example to scripts/local.env and fill it in, or pass --udid <UDID>." >&2
  exit 2
fi
export UDID DEVELOPMENT_TEAM
APP_PATH="$BUILD_DIR/Build/Products/Debug-iphoneos/$SCHEME.app"
