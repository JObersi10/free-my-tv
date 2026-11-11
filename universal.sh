#!/usr/bin/env bash
# universal.sh — one-shot setup for Amazon Fire TV devices (2022+ / Fire OS 7-8):
#   - debloat via `pm disable-user` (never uninstall, every change is recorded and reversible)
#   - optionally disable the Fire TV system-update checker
#   - install your chosen apps (TizenTube Cobalt, PhairPlay, Stremio, Myspoti, NetGuard, FreeMyTV)
#   - optionally build & install a Home-redirect helper so pressing Home reopens FreeMyTV
#
# Usage:
#   ./universal.sh                    interactive run against an already-adb-connected
#                                      device, or prompts for the TV's IP
#   TV_HOST=192.168.1.246 ./universal.sh   skip the IP prompt
#   ./universal.sh --restore          re-enable everything the most recent run disabled
#
# Nothing here uninstalls anything. Every `pm disable-user` is logged to a per-run restore
# script under ~/.firetv-universal/, and re-running universal.sh is the "update checker" —
# it just re-does the installs/disables against whatever's current.

set -uo pipefail   # no -e: one failed `pm`/`adb` call should not kill the whole run

### ---------------------------------------------------------------- helpers
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLU=$'\033[34m'; DIM=$'\033[2m'; BLD=$'\033[1m'; RST=$'\033[0m'
log()  { printf '%s\n' "${BLU}➜${RST}  $*"; }
ok()   { printf '%s\n' "${GRN}✔${RST}  $*"; }
warn() { printf '%s\n' "${YEL}⚠${RST}  $*" >&2; }
err()  { printf '%s\n' "${RED}✖${RST}  $*" >&2; }

# A boxen-style border around a short headline, e.g. box "Setup complete".
box() {
  local text=" $1 " pad dash
  pad=$((${#1} + 2))
  dash="$(printf '─%.0s' $(seq 1 "$pad"))"
  printf '%s╭%s╮%s\n' "$GRN" "$dash" "$RST"
  printf '%s│%s│%s\n' "$GRN" "$text" "$RST"
  printf '%s╰%s╯%s\n' "$GRN" "$dash" "$RST"
}

SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
# spin "message" -- cmd args...   Runs cmd in the background, animates a braille spinner next to
# "message" while it's alive (skipped when stdout isn't a terminal), then prints cmd's own
# stdout+stderr and returns its exit code — a stand-in for `ora` in a plain bash script.
spin() {
  local msg="$1"; shift
  [ "${1:-}" = "--" ] && shift
  local tmp="$WORKDIR/.spin.$$.$RANDOM.out" pid i=0 rc out
  "$@" >"$tmp" 2>&1 &
  pid=$!
  if [ -t 1 ]; then
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  %s %s   ' "${SPIN_FRAMES[$((i % ${#SPIN_FRAMES[@]}))]}" "$msg"
      i=$((i + 1))
      sleep 0.1
    done
    printf '\r%*s\r' "$((${#msg} + 6))" ''
  fi
  wait "$pid"; rc=$?
  out="$(cat "$tmp" 2>/dev/null)"; rm -f "$tmp"
  printf '%s' "$out"
  return "$rc"
}

confirm() {   # confirm "question" [Y|N default]
  local q="$1" def="${2:-Y}" ans hint="[Y/n]"
  [ "$def" = "N" ] && hint="[y/N]"
  read -r -p "$q $hint " ans </dev/tty || ans=""
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy] ]]
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || { err "$1 not found. $2"; exit 1; }; }

# multiselect "Title" outvar "d1,d2,..." "label1" "label2" ...
# An arrow-key checkbox list — the bash equivalent of @clack/prompts' multiselect, swapping a run
# of sequential y/n questions for one screen: ↑/↓ move, space toggles, a/n check/uncheck all,
# enter confirms. "d1,d2,..." is the starting 0/1 state per label (same defaults the old per-item
# [Y/n] prompts had). Sets outvar to a 0/1 array in the same order as the labels. Falls back to
# the given defaults untouched when stdin isn't a real terminal (e.g. piped input).
multiselect() {
  local title="$1" outvar="$2" defaults="$3"; shift 3
  local -a items=("$@") checked
  local n=${#items[@]} i cur=0 key seq
  IFS=',' read -r -a checked <<< "$defaults"

  if [ ! -t 0 ] || [ ! -r /dev/tty ]; then
    eval "$outvar=(\"\${checked[@]}\")"
    return
  fi

  _ms_draw() {
    local j mark arrow
    for ((j = 0; j < n; j++)); do
      arrow=" "; [ "$j" -eq "$cur" ] && arrow="${BLU}❯${RST}"
      mark="${DIM}○${RST}"; [ "${checked[j]}" = 1 ] && mark="${GRN}◉${RST}"
      printf '\r\033[K %s %s %s\n' "$arrow" "$mark" "${items[j]}"
    done
    printf '\033[%dA' "$n"
  }

  printf '%s\n' "${BLD}${title}${RST}  ${DIM}(up/down move, space toggle, a all, n none, enter confirm)${RST}"
  printf '\033[?25l'
  _ms_draw
  while true; do
    IFS= read -rsn1 key </dev/tty
    case "$key" in
      $'\x1b')
        seq=""; read -rsn2 -t 0.02 seq </dev/tty
        case "$seq" in
          '[A') cur=$(((cur - 1 + n) % n)) ;;
          '[B') cur=$(((cur + 1) % n)) ;;
        esac ;;
      '') break ;;
      ' ') [ "${checked[cur]}" = 1 ] && checked[cur]=0 || checked[cur]=1 ;;
      a|A) for ((i = 0; i < n; i++)); do checked[i]=1; done ;;
      n|N) for ((i = 0; i < n; i++)); do checked[i]=0; done ;;
    esac
    _ms_draw
  done
  printf '\033[%dB' "$n"
  printf '\033[?25h\n'
  eval "$outvar=(\"\${checked[@]}\")"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$HOME/.firetv-universal"
mkdir -p "$STATE_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/firetv-universal.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
STATE_FILE="$STATE_DIR/restore-$TS.sh"
DEVICE=""
ARCH="arm64-v8a"

### ---------------------------------------------------------------- adb connect
require_adb() {
  require_cmd adb "Install it with: brew install android-platform-tools"
}

connect_device() {
  require_adb
  local existing
  existing="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
  if [ -n "$existing" ]; then
    DEVICE="$existing"
    log "Using already-connected ADB device: $DEVICE"
    return
  fi

  local ip state last_state waited max_wait
  while true; do
    ip="${TV_HOST:-}"
    if [ -z "$ip" ]; then
      read -r -p "No ADB device connected. Enter the Fire TV's IP address: " ip </dev/tty
    fi
    TV_HOST=""   # only honor the env var / previous entry once; a retry always re-prompts
    if [ -z "$ip" ]; then
      err "No IP given."
      continue
    fi
    [[ "$ip" == *:* ]] || ip="$ip:5555"
    log "Connecting to $ip ..."
    log "First connection: the TV will show an 'Allow USB debugging?' prompt — accept it there; this waits for it instead of giving up right away."
    adb connect "$ip" >/dev/null 2>&1

    # Live debugging view: keep re-trying `adb connect` and show the device's actual adb state
    # (none/offline/unauthorized/device) each second, instead of one `sleep 1` then a flat failure.
    # Fire TV's own prompt can take several seconds to render and more for someone to walk over
    # and accept it — the old single-shot check treated all of that as "could not connect".
    waited=0; max_wait=45; last_state=""
    while [ "$waited" -lt "$max_wait" ]; do
      state="$(adb devices | awk -v ip="$ip" 'NR>1 && $1==ip {print $2; exit}')"
      if [ "$state" = "device" ]; then
        printf '\n'
        DEVICE="$ip"
        ok "Connected: $DEVICE"
        return
      fi
      if [ "$state" != "$last_state" ]; then
        printf '\n'
        case "$state" in
          unauthorized) log "Reached the TV — waiting for you to accept 'Allow USB debugging?' on screen ..." ;;
          offline)      log "Device showed up offline, retrying the connect ..." ;;
          *)            log "No response yet from $ip, retrying ..." ;;
        esac
        last_state="$state"
      fi
      printf '\r  %s waiting (%2ds/%ds, adb state: %s)   ' "${SPIN_FRAMES[$((waited % ${#SPIN_FRAMES[@]}))]}" "$waited" "$max_wait" "${state:-none}"
      sleep 1
      waited=$((waited + 1))
      adb connect "$ip" >/dev/null 2>&1
    done
    printf '\n'

    err "Could not connect to $ip after ${max_wait}s (adb state: ${state:-none})."
    err "Check: Settings > My Fire TV > Developer options > ADB debugging is ON, and accept the on-TV prompt."
    confirm "Try again (same or a different IP)?" Y || exit 1
  done
}

### ---------------------------------------------------------------- restore mode
if [ "${1:-}" = "--restore" ]; then
  connect_device
  latest="$(ls -t "$STATE_DIR"/restore-*.sh 2>/dev/null | head -1)"
  [ -n "$latest" ] || { err "No saved restore file in $STATE_DIR"; exit 1; }
  log "Restoring from $latest ..."
  bash "$latest" "$DEVICE"
  ok "Restore done."
  exit 0
fi
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,15p' "$0"
  exit 0
fi

### ---------------------------------------------------------------- device detection
detect_device() {
  local prop; prop() { adb -s "$DEVICE" shell getprop "$1" 2>/dev/null | tr -d '\r'; }
  MANUFACTURER="$(prop ro.product.manufacturer)"
  MODEL="$(prop ro.product.model)"
  BRAND="$(prop ro.product.brand)"
  FIREOS="$(prop ro.build.version.fireos)"
  ANDROID_VER="$(prop ro.build.version.release)"
  ABIS="$(prop ro.product.cpu.abilist)"

  # Pulled once here instead of per-package in disable_pkgs() below: on real hardware over Wi-Fi,
  # each `adb shell pm ...` round trip is the slow part, not the disable itself — ~60 packages at
  # 2-3 round trips each was the actual wait. One full present/disabled snapshot now, then every
  # disable_pkgs() check below is a local grep against it, and an already-disabled package (e.g. on
  # a re-run) costs nothing at all instead of 3 more round trips for a no-op.
  PKG_LIST_ALL="$(spin "Reading the device's installed-package list ..." -- adb -s "$DEVICE" shell pm list packages)"
  PKG_LIST_DISABLED="$(adb -s "$DEVICE" shell pm list packages -d 2>/dev/null | tr -d '\r')"
  PKG_LIST_ALL="$(printf '%s' "$PKG_LIST_ALL" | tr -d '\r')"
  HAS_LAUNCHER="$(printf '%s\n' "$PKG_LIST_ALL" | grep -qx 'package:com.amazon.tv.launcher' && echo yes)"

  echo
  log "Device: ${BLD}${MODEL:-unknown}${RST}  (brand: ${BRAND:-?}, manufacturer: ${MANUFACTURER:-?})"
  [ -n "$FIREOS" ] && log "Fire OS: $FIREOS  (Android $ANDROID_VER)"
  log "CPU ABIs: ${ABIS:-unknown}"

  if [[ "$MANUFACTURER" == *Amazon* ]] || [ -n "$FIREOS" ] || [ -n "$HAS_LAUNCHER" ]; then
    ok "Detected a Fire TV device."
  else
    warn "This does not look like a Fire TV (no Fire OS build property, no com.amazon.tv.launcher)."
    warn "universal.sh is written and tested for Fire TV only — package names below assume Fire OS."
    confirm "Continue anyway on this non-Fire-TV device?" N || { err "Aborted."; exit 1; }
  fi

  if [ -n "$FIREOS" ]; then
    local major="${FIREOS%%.*}"
    case "$major" in
      ''|*[!0-9]*) : ;;
      *) if [ "$major" -lt 7 ]; then
           warn "Fire OS $FIREOS detected — this script targets 2022-and-up Fire TV devices (Fire OS 7/8)."
           warn "Older Fire OS may refuse 'pm disable-user' outright (needs 'pm hide' + root instead),"
           warn "and some package names below may not exist on it."
           confirm "Continue anyway?" N || { err "Aborted."; exit 1; }
         fi ;;
    esac
  fi

  ARCH="arm64-v8a"
  [[ "$ABIS" == *arm64-v8a* ]] || ARCH="armeabi-v7a"
}

### ---------------------------------------------------------------- debloat engine
# Packages that are NEVER touched regardless of what's selected below. This is a safety net on
# top of Fire OS's own protected-package list (which already refuses the deepest system packages).
NEVER_TOUCH=(
  com.amazon.tv.launcher com.amazon.tv.settings com.amazon.tv.settings.v2
  com.amazon.venezia com.amazon.tigris com.amazon.tv.ime
  com.amazon.vizzini com.amazon.aria com.amazon.cardinal
  com.amazon.cast.sink com.amazon.dialservice com.amazon.ssdpservice
  com.amazon.whisperlink.core.sdk.android com.amazon.whisperplay.fling.receiver
  com.amazon.tv.oobe com.amazon.firebat com.amazon.tv.support com.amazon.logan
)
is_protected() {
  local pkg="$1" p
  for p in "${NEVER_TOUCH[@]}"; do [ "$p" = "$pkg" ] && return 0; done
  return 1
}

echo '#!/usr/bin/env bash' > "$STATE_FILE"
echo "# Re-enables what this universal.sh run (at $TS) disabled. Usage: bash '$STATE_FILE' <adb-serial>" >> "$STATE_FILE"
chmod +x "$STATE_FILE"
DISABLED_COUNT=0

disable_pkgs() {   # disable_pkgs "label for log output" pkg1 pkg2 ...
  local label="$1"; shift
  local pkg present was_disabled out
  for pkg in "$@"; do
    if is_protected "$pkg"; then
      warn "skip (protected by universal.sh): $pkg"
      continue
    fi
    present="$(adb -s "$DEVICE" shell pm list packages "$pkg" 2>/dev/null | tr -d '\r')"
    [ -n "$present" ] || continue   # not on this device/model — skip quietly
    was_disabled="$(adb -s "$DEVICE" shell pm list packages -d "$pkg" 2>/dev/null | tr -d '\r')"
    out="$(adb -s "$DEVICE" shell pm disable-user --user 0 "$pkg" 2>&1 | tr -d '\r')"
    if [[ "$out" == *"disabled"* ]]; then
      echo "   disabled  $pkg   # $label"
      DISABLED_COUNT=$((DISABLED_COUNT + 1))
      if [ -z "$was_disabled" ]; then
        echo "adb -s \"\$1\" shell pm enable \"$pkg\" >/dev/null 2>&1 && echo re-enabled $pkg" >> "$STATE_FILE"
      fi
    else
      warn "could not disable $pkg (protected by Fire OS, or needs root): $out"
    fi
  done
}

### ---------------------------------------------------------------- package data
PKGS_TELEMETRY="com.amazon.client.metrics.api com.amazon.metrics.api com.amazon.tv.fw.metrics com.amazon.wirelessmetrics.service com.amazon.perfcollection com.amazon.dp.logger com.amazon.ceviche com.amazon.tv.developer.dataservice com.amazon.wifilocker com.amazon.device.telemetry.emitter"

PKGS_ADS="com.amazon.kso.blackbird com.amazon.sneakpeek com.amazon.hybridadidservice com.amazon.hedwig com.amazon.tv.easyupgrade com.amazon.device.sale.service com.amazon.shoptv.client com.amazon.shoptv.firetv.client com.amazon.minitv.android.app com.amazon.imdb.tv.android.app"

PKGS_BLOAT="com.amazon.tahoe com.amazon.bueller.music com.amazon.bueller.photos com.amazon.cloud9 com.amazon.tv.website_launcher com.imdb.livingroom.firetv com.amazon.tmm.tutorial com.amazon.storm.lightning.tutorial com.amazon.whad com.amazon.whasettings com.amazon.wha.mediabrowserservice com.amazon.whisperjoin.middleware.np com.amazon.whisperjoin.wss.wifiprovisioner com.amazon.tv.ffsprovisioneeclient com.amazon.ods.kindleconnect com.amazon.gamehub com.amazon.livedeviceservice com.amazon.franktvinput com.amazon.tv.livetv"

PKGS_NOISE="com.amazon.privacypassservice com.amazon.providers.contentsupport com.amazon.systemnotices com.amazon.tv.releasenotes com.amazon.uxnotification"

PKGS_ALEXA_EXTRAS="com.amazon.tv.alexaalerts com.amazon.tv.alexanotifications com.amazon.alexa.externalmediaplayer.fireos com.amazon.alexamediaplayer.runtime.ftv com.amazon.aiondec"

# Fire TV's own OTA/system-update checker. Asked about in the app-installer section, next to NetGuard.
OTA_PACKAGES="com.amazon.device.software.ota"

# One-off extra packages to always disable on every run. Empty by default — add anything you find
# later (e.g. after a Fire OS update re-introduces something) and every future run clears it again.
EXTRA_DISABLE=""

### ---------------------------------------------------------------- github release helper
GH_API="https://api.github.com"

gh_pick_asset() {   # gh_pick_asset <owner/repo> <name-regex> [allow_prerelease: 0|1]
  local repo="$1" pattern="$2" allow_pre="${3:-0}"
  curl -fsSL "$GH_API/repos/$repo/releases?per_page=10" 2>/dev/null | python3 -I -c '
import json, re, sys
pattern, allow_pre = sys.argv[1], sys.argv[2] == "1"
try:
    releases = json.load(sys.stdin)
except Exception:
    sys.exit(0)
def find(allow_prerelease):
    for rel in releases:
        if rel.get("prerelease") and not allow_prerelease:
            continue
        for a in rel.get("assets", []):
            if re.search(pattern, a["name"]):
                return a["browser_download_url"]
    return None
url = find(allow_pre) or (find(True) if not allow_pre else None)
if url:
    print(url)
' "$pattern" "$allow_pre"
}

install_apk_from_url() {   # install_apk_from_url "label" "<url>"
  local label="$1" url="$2" file
  [ -n "$url" ] || { err "No download URL for $label."; return 1; }
  file="$WORKDIR/$(basename "${url%%\?*}")"
  log "Downloading $label ..."
  if ! curl -fL --progress-bar -o "$file" "$url"; then
    err "Download failed for $label ($url)"
    return 1
  fi
  install_local_apk "$label" "$file"
}

# queue_download "label" "<url>"  — starts the download right now, in the background, and returns
# immediately so the app-installer menu can move on to the next pick (resolving a GitHub release
# URL, asking a follow-up question, building FreeMyTV) while this one keeps downloading. Nothing
# here talks to the TV yet — adb install has to happen one at a time, so that part waits for
# process_queue below.
APK_Q_LABELS=(); APK_Q_URLS=(); APK_Q_FILES=(); APK_Q_PIDS=()
queue_download() {
  local label="$1" url="$2" file
  if [ -z "$url" ]; then
    err "No download URL for $label."
    return
  fi
  file="$WORKDIR/$(basename "${url%%\?*}")"
  curl -fsSL -o "$file" "$url" &
  APK_Q_LABELS+=("$label"); APK_Q_URLS+=("$url"); APK_Q_FILES+=("$file"); APK_Q_PIDS+=("$!")
  log "Queued $label for download (running in the background) ..."
}

# process_queue — waits out whatever queue_download jobs are still running (showing all of them at
# once instead of one at a time), then installs each in turn. Call this once, after the last
# queue_download, when there's nothing left to ask the menu before installing.
process_queue() {
  local n=${#APK_Q_LABELS[@]} i alive status frame=0
  [ "$n" -eq 0 ] && return
  if [ -t 1 ]; then
    while true; do
      alive=0; status=""
      for ((i = 0; i < n; i++)); do
        kill -0 "${APK_Q_PIDS[i]}" 2>/dev/null && { alive=1; status+="${APK_Q_LABELS[i]} … "; }
      done
      [ "$alive" = 0 ] && break
      printf '\r  %s downloading: %s  ' "${SPIN_FRAMES[$((frame % ${#SPIN_FRAMES[@]}))]}" "$status"
      frame=$((frame + 1))
      sleep 0.15
    done
    printf '\r\033[K'
  fi
  for ((i = 0; i < n; i++)); do
    wait "${APK_Q_PIDS[i]}" 2>/dev/null
    if [ -s "${APK_Q_FILES[i]}" ]; then
      install_local_apk "${APK_Q_LABELS[i]}" "${APK_Q_FILES[i]}"
    else
      err "Download failed for ${APK_Q_LABELS[i]} (${APK_Q_URLS[i]:-no URL})"
    fi
  done
  APK_Q_LABELS=(); APK_Q_URLS=(); APK_Q_FILES=(); APK_Q_PIDS=()
}

install_local_apk() {   # install_local_apk "label" "/path/to/file.apk"
  local label="$1" file="$2" out
  [ -f "$file" ] || { err "$label: file not found: $file"; return 1; }
  out="$(spin "Installing $label on the TV ..." -- adb -s "$DEVICE" install -r -g "$file")"
  LAST_INSTALL_FAIL_REASON=""
  if printf '%s' "$out" | grep -qi success; then
    ok "$label installed."
    return 0
  fi
  # Classify the failure so callers (e.g. the uninstall-and-retry below) don't waste a retry on a
  # reason retrying can't fix — only a signing-key clash is actually worth a clean reinstall.
  case "$out" in
    *INSTALL_FAILED_OLDER_SDK*)
      LAST_INSTALL_FAIL_REASON="older_sdk"
      err "$label needs a newer Android version than this TV has (Android ${ANDROID_VER:-?}). Not a"
      err "signing issue — retrying the same file won't help; there's no older-SDK build to fall back to."
      ;;
    *INSTALL_FAILED_NO_MATCHING_ABIS*)
      LAST_INSTALL_FAIL_REASON="abi"
      err "$label has no native code for this TV's CPU (${ABIS:-unknown}). Wrong architecture, not a"
      err "signing issue — retrying the same file won't help."
      ;;
    *INSTALL_FAILED_UPDATE_INCOMPATIBLE*|*INSTALL_FAILED_VERSION_DOWNGRADE*|*signatures*do*not*match*)
      LAST_INSTALL_FAIL_REASON="signature"
      warn "$label: a different signing key than what's already on the TV (e.g. switching sources)."
      ;;
    *)
      LAST_INSTALL_FAIL_REASON="other"
      warn "$label install may have failed:"
      ;;
  esac
  printf '%s\n' "$out" >&2
  return 1
}

### ---------------------------------------------------------------- Home-redirect helper
# Fire OS hardcodes the physical Home button to Amazon's launcher — no app can become the real
# default home. The actual trick (same one fire-tv-cleanup's launcher uses): a tiny accessibility
# service watches for Amazon's home screen coming to the foreground and instantly reopens a chosen
# app instead. This builds that helper locally from the vendored project in home-redirect/launcher
# (patched to redirect into FreeMyTV) and installs + enables it over adb — no manual taps needed.
ensure_build_tools() {
  local d jh="" sdk=""
  for d in "${JAVA_HOME:-}" "/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
           "$(/usr/libexec/java_home 2>/dev/null)" \
           /opt/homebrew/opt/openjdk@17 /opt/homebrew/opt/openjdk /usr/local/opt/openjdk@17; do
    [ -n "$d" ] && [ -x "$d/bin/javac" ] && { jh="$d"; break; }
  done
  if [ -z "$jh" ]; then
    err "No JDK found (checked Android Studio's bundled JBR, \$JAVA_HOME, java_home, Homebrew)."
    return 1
  fi
  export JAVA_HOME="$jh"
  export PATH="$JAVA_HOME/bin:$PATH"

  for d in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" /Volumes/SABRENT/Applications/AndroidSDK \
           "$HOME/Library/Android/sdk" "$HOME/Android/Sdk" \
           /opt/homebrew/share/android-commandlinetools /usr/local/share/android-commandlinetools; do
    [ -n "$d" ] && [ -d "$d/build-tools" ] && { sdk="$d"; break; }
  done
  if [ -z "$sdk" ]; then
    err "No Android SDK found (checked \$ANDROID_HOME/\$ANDROID_SDK_ROOT and common install locations)."
    return 1
  fi
  export ANDROID_HOME="$sdk"
  export ANDROID_SDK_ROOT="$sdk"
  log "Using JDK: $JAVA_HOME"
  log "Using Android SDK: $ANDROID_HOME"
}

### ---------------------------------------------------------------- FreeMyTV (built from local source)
# Kept as a local, customized source tree (freemytv-src/) next to this script instead of fetching the generic
# GitHub release: that's the only way to carry our own config.properties (location, theme, temperature, the
# crypto ticker off, the extra shelf apps, the Unsplash background) and the shelf/HomeApps.java edits forward.
build_and_install_freemytv() {
  local src_dir="$SCRIPT_DIR/freemytv-src" apk url
  if [ ! -d "$src_dir" ]; then
    err "freemytv-src/ not found next to universal.sh — skipping FreeMyTV."
    return 1
  fi
  apk="$src_dir/FreeMyTV.apk"
  if ! ensure_build_tools; then
    if [ -f "$apk" ]; then
      warn "No JDK/Android SDK to rebuild — installing the FreeMyTV.apk already sitting in freemytv-src/ instead."
      warn "That's whatever was last built there; any source/config edits since then won't be in it."
    else
      warn "No JDK/Android SDK and no FreeMyTV.apk already built locally — falling back to a GitHub release."
      url="$(gh_pick_asset JObersi10/free-my-tv "\\.apk$" 1)"   # our fork's rolling "dev" release (a prerelease
      if [ -n "$url" ]; then                                    # tag) carries the same customizations as the
        log "Using the customized fork's dev build (github.com/JObersi10/free-my-tv) instead of a local build."
        install_apk_from_url "FreeMyTV (fork dev release)" "$url"
        return $?
      fi
      warn "Fork has no dev release yet — falling back to the generic upstream one (github.com/simbasjungles/"
      warn "free-my-tv). That build won't have our customizations (Curaçao location, dark theme, Celsius,"
      warn "crypto ticker off, the extra shelf apps, Unsplash) — install Android Studio (gives both the JDK"
      warn "and SDK) and re-run to get the customized build, or push to the fork to get its dev release going."
      url="$(gh_pick_asset simbasjungles/free-my-tv "\\.apk$" 0)"
      install_apk_from_url "FreeMyTV (generic release)" "$url"
      return $?
    fi
  else
    [ -f "$src_dir/config.properties" ] || cp "$src_dir/config.example.properties" "$src_dir/config.properties"
    log "Building FreeMyTV from the local source (first build can take a minute) ..."
    if ! (cd "$src_dir" && ./build.sh); then
      err "FreeMyTV build failed — see its output above."
      return 1
    fi
  fi
  [ -f "$apk" ] || { err "Build did not produce $apk"; return 1; }
  if ! install_local_apk "FreeMyTV" "$apk"; then
    if [ "$LAST_INSTALL_FAIL_REASON" != "signature" ]; then
      return 1   # older_sdk/abi/other: the same file will fail the same way, no point retrying
    fi
    # A different signing key than what's on the TV now (e.g. switching from the old generic release) — the
    # only fix is a clean reinstall; FreeMyTV's own "Original" mode state resets, same as its own docs warn.
    warn "Install failed (signing-key mismatch with what's on the TV) — uninstalling and retrying once ..."
    adb -s "$DEVICE" uninstall io.freemytv >/dev/null 2>&1
    install_local_apk "FreeMyTV" "$apk" || return 1
  fi
  return 0
}

build_and_install_home_redirect() {
  local launcher_dir="$SCRIPT_DIR/home-redirect/launcher" apk
  if [ ! -d "$launcher_dir" ]; then
    err "home-redirect/launcher not found next to universal.sh — skipping."
    return 1
  fi
  apk="$launcher_dir/app/build/outputs/apk/debug/app-debug.apk"
  if ! ensure_build_tools; then
    if [ -f "$apk" ]; then
      warn "No JDK/Android SDK to rebuild — installing the app-debug.apk already sitting in home-redirect/"
      warn "launcher/ instead. That's whatever was last built there; any code changes since won't be in it."
      warn "(There's no downloadable release for this helper — it's a custom local component.)"
    else
      err "No JDK/Android SDK and no app-debug.apk already built locally — skipping the Home-redirect helper."
      return 1
    fi
  else
    log "Building the Home-redirect helper (first build downloads Gradle + deps, can take a few minutes) ..."
    echo "sdk.dir=$ANDROID_HOME" > "$launcher_dir/local.properties"
    if ! (cd "$launcher_dir" && ./gradlew assembleDebug -q --console=plain); then
      err "Build failed — see Gradle's output above."
      return 1
    fi
  fi
  [ -f "$apk" ] || { err "Build did not produce $apk"; return 1; }
  install_local_apk "Home-redirect helper" "$apk" || return 1
  adb -s "$DEVICE" shell pm grant com.gathin.tvhome android.permission.WRITE_SECURE_SETTINGS >/dev/null 2>&1
  adb -s "$DEVICE" shell settings put secure enabled_accessibility_services com.gathin.tvhome/com.gathin.tvhome.HomeRedirectService
  adb -s "$DEVICE" shell settings put secure accessibility_enabled 1
  echo "adb -s \"\$1\" shell pm uninstall com.gathin.tvhome >/dev/null 2>&1 && echo removed home-redirect helper" >> "$STATE_FILE"
  ok "Home-redirect helper installed and enabled."
  log "Escape hatch: FreeMyTV's Shortcuts row has a 'Fire TV Home' button that pauses the redirect for 45s."
  log "Testing it — sending a Home keypress ..."
  sleep 1
  adb -s "$DEVICE" shell input keyevent KEYCODE_HOME
}

### =================================================================== MAIN
printf '%s\n' "${BLU}${BLD}"
cat <<'BANNER'
   _____ _          _______      __
  |  ___(_)_ __ ___|_   _\ \    / /
  | |_  | | '__/ _ \ | |  \ \  / /
  |  _| | | | |  __/ | |   \ \/ /
  |_|   |_|_|  \___| |_|    \__/   universal.sh
BANNER
printf '%s\n' "$RST"
log "Debloats, installs apps, and (optionally) replaces the Home button — all reversible with ${BLD}--restore${RST}."
echo
connect_device
detect_device

[ -n "$EXTRA_DISABLE" ] && disable_pkgs "extra (your one-off list)" $EXTRA_DISABLE

echo
log "${BLD}Debloat menu${RST} — each category only disables packages (nothing is uninstalled), and every"
log "change is reversible with: ./universal.sh --restore"

confirm "Disable telemetry, crash & usage reporting?" Y && disable_pkgs "telemetry" $PKGS_TELEMETRY
confirm "Disable ads, sponsored rows & upsell promos?" Y && disable_pkgs "ads" $PKGS_ADS
confirm "Disable unused preloaded Amazon apps (Kids/FreeTime, Music, Photos, Silk browser, IMDb, whole-home audio, device-pairing helpers)?" Y && disable_pkgs "bloat" $PKGS_BLOAT
confirm "Disable system notices, release notes & UX popups?" Y && disable_pkgs "system noise" $PKGS_NOISE
confirm "Disable Alexa EXTRAS — alarms/timers/notifications/Alexa-controlled music? (voice search itself stays on either way, it's not in this list)" N && disable_pkgs "Alexa extras" $PKGS_ALEXA_EXTRAS

echo
if confirm "Go through preinstalled streaming apps you don't use, one by one?" Y; then
  stream_item() { local label="$1"; shift; confirm "  Disable $label?" Y && disable_pkgs "$label" "$@"; }
  stream_item "Hulu" com.hulu.plus
  stream_item "Max (HBO)" com.hbo.hbonow
  stream_item "Peacock" com.peacock.peacockfiretv
  stream_item "Tubi" com.tubitv.ott
  stream_item "Pluto TV" tv.pluto.android
  stream_item "Paramount+" com.cbs.ott
  stream_item "ESPN" com.espn.gtv com.foxsports.videogo
  stream_item "FOX" com.fox.fts.android
  stream_item "fuboTV" com.fubo.firetv.screen
  stream_item "Telemundo" com.nbcuni.telemundostation.houston.firetv com.amazon.webapps.nbc.telemundo
  stream_item "Univision" com.univision.android
  stream_item "Adult Swim" com.adultswim.firetv
  stream_item "Fox News web app" com.amazon.rialto.cordova.webapp.webapp855cc15add08457a8a1fe62312eab585
fi

echo
log "Debloat done — $DISABLED_COUNT package(s) newly disabled this run."

### ---------------------------------------------------------------- app installer
require_cmd python3 "Needed to read GitHub's release API; macOS ships it by default."

echo
log "${BLD}App installer${RST}"

multiselect "Pick what to install/do:" APP_SEL "1,1,1,0,0,1,1,1,1" \
  "TizenTube Cobalt — ad-free/SponsorBlock YouTube (Cobalt, reisxd's fork; real TizenTube is Tizen-only)" \
  "PhairPlay — your AirPlay 2/DLNA receiver" \
  "Stremio — media center" \
  "Myspoti — Spotify client for Fire TV/Android TV" \
  "Apple Music TV — your app" \
  "NetGuard — no-root, per-app firewall" \
  "Disable updates — disables the Fire TV system-update checker" \
  "FreeMyTV — clean, ad-free home screen (built from the local customized source)" \
  "AerialViews — Apple-TV-style aerial drone video screensaver"

# Everything that's just a plain APK gets its download started now, in the background, so it's
# running while we resolve the next URL / build FreeMyTV / ask follow-ups below — adb install
# still happens one at a time (process_queue, once there's nothing left to ask first).
if [ "${APP_SEL[0]}" = 1 ]; then
  cobalt_arch="arm64"; [ "$ARCH" = "armeabi-v7a" ] && cobalt_arch="arm"
  queue_download "TizenTube Cobalt" "$(gh_pick_asset reisxd/TizenTubeCobalt "cobalt-${cobalt_arch}\\.apk$" 0)"
fi

if [ "${APP_SEL[1]}" = 1 ]; then
  url="$(gh_pick_asset JObersi10/PhairPlay "[Ff]ire[Tt][Vv].*\\.apk$|firetv.*\\.apk$" 0)"
  [ -z "$url" ] && url="$(gh_pick_asset JObersi10/PhairPlay "firetv.*\\.apk$" 1)"
  queue_download "PhairPlay" "$url"
fi

if [ "${APP_SEL[2]}" = 1 ]; then
  page="$(curl -fsSL -A 'Mozilla/5.0' https://www.stremio.com/downloads 2>/dev/null)"
  url="$(printf '%s' "$page" | grep -oE "https://dl\.strem\.io/android/v[0-9][^\"' ]*-androidTV/[^\"' ]*${ARCH}\.apk" | sort -V | tail -1)"
  if [ -z "$url" ]; then
    warn "Couldn't scrape stremio.com/downloads — using a known-good build as fallback (check stremio.com/downloads if this is stale)."
    if [ "$ARCH" = "arm64-v8a" ]; then
      url="https://dl.strem.io/android/v1.12.1-androidTV/com.stremio.one-1.12.1-53145729-arm64-v8a.apk"
    else
      url="https://dl.strem.io/android/v1.12.1-androidTV/com.stremio.one-1.12.1-51048577-armeabi-v7a.apk"
    fi
  fi
  queue_download "Stremio" "$url"
fi

if [ "${APP_SEL[3]}" = 1 ]; then
  url="$(gh_pick_asset kota-zo/myspoti "TV\\.apk$" 0)"
  [ -z "$url" ] && url="https://github.com/kota-zo/myspoti/releases/download/v2.4.0/Myspoti-2.4.0-TV.apk"
  queue_download "Myspoti" "$url"
fi

[ "${APP_SEL[4]}" = 1 ] && queue_download "Apple Music TV" "$(gh_pick_asset JObersi10/apple-music-tv "AM-TV.*\\.apk$|Apple-Music-TV\\.apk$" 0)"

NETGUARD_PICKED="${APP_SEL[5]}"
[ "$NETGUARD_PICKED" = 1 ] && queue_download "NetGuard" "$(gh_pick_asset M66B/NetGuard "release\\.apk$" 0)"

AERIAL_PICKED="${APP_SEL[8]}"
[ "$AERIAL_PICKED" = 1 ] && queue_download "AerialViews" "$(gh_pick_asset theothernt/AerialViews "aerial-views.*\\.apk$" 0)"

if [ "${APP_SEL[6]}" = 1 ]; then
  disable_pkgs "system update checker" $OTA_PACKAGES
  warn "Note: community reports are mixed on whether this fully blocks OTA installs vs. just the manual"
  warn "check in Settings — treat it as best-effort, and expect to re-run this after any update that slips through."
fi

INSTALLED_FREEMYTV=0
if [ "${APP_SEL[7]}" = 1 ] && build_and_install_freemytv; then
  INSTALLED_FREEMYTV=1
  adb -s "$DEVICE" shell am start -n io.freemytv/.SettingsActivity >/dev/null 2>&1
  if confirm "Also replace Amazon's screensaver with FreeMyTV's (same idea as the Home redirect, just for idle timeout — skip this if you're installing AerialViews, which looks better)?" N; then
    saver_class=".Screensaver"
    saver_major="${ANDROID_VER%%.*}"
    case "$saver_major" in
      11|12) saver_class=".ScreensaverAlone" ;;   # FreeMyTV runs the dream alone on Android 11-12L
    esac
    adb -s "$DEVICE" shell settings put secure screensaver_components "io.freemytv/${saver_class}"
    adb -s "$DEVICE" shell settings put secure screensaver_enabled 1
    ok "Screensaver set to FreeMyTV ($saver_class for Android $ANDROID_VER)."
  fi
fi

process_queue   # pick up whatever's still downloading and install each one, now that nothing's
                # left to ask before them

INSTALLED_NETGUARD=0
if [ "$NETGUARD_PICKED" = 1 ] && [ -n "$(adb -s "$DEVICE" shell pm list packages eu.faircode.netguard 2>/dev/null | tr -d '\r')" ]; then
  INSTALLED_NETGUARD=1
  log "Granting NetGuard VPN permission (best-effort — Fire OS may refuse this without root) ..."
  if adb -s "$DEVICE" shell appops set eu.faircode.netguard ACTIVATE_VPN allow >/dev/null 2>&1; then
    ok "VPN permission pre-granted."
  else
    warn "Could not pre-grant it — you'll need to open NetGuard on the TV once and accept the 'VPN connection request' prompt yourself."
  fi
  adb -s "$DEVICE" shell am start -n eu.faircode.netguard/.ActivityMain >/dev/null 2>&1
fi

if [ "$AERIAL_PICKED" = 1 ] && [ -n "$(adb -s "$DEVICE" shell pm list packages com.neilturner.aerialviews 2>/dev/null | tr -d '\r')" ]; then
  if confirm "Set AerialViews as the screensaver (overrides any other screensaver choice above)?" Y; then
    adb -s "$DEVICE" shell settings put secure screensaver_components com.neilturner.aerialviews/.ui.screensaver.DreamActivity
    adb -s "$DEVICE" shell settings put secure screensaver_default_component com.neilturner.aerialviews/.ui.screensaver.DreamActivity
    adb -s "$DEVICE" shell settings put secure screensaver_enabled 1
    adb -s "$DEVICE" shell settings put secure contextual_screen_off_timeout 300000
    adb -s "$DEVICE" shell settings put secure amazon_ambient_enabled 0
    adb -s "$DEVICE" shell appops set com.neilturner.aerialviews SYSTEM_ALERT_WINDOW allow
    ok "Screensaver set to AerialViews."
  fi
fi

HAS_FREEMYTV="$(adb -s "$DEVICE" shell pm list packages io.freemytv 2>/dev/null | tr -d '\r')"
[ -z "$HAS_FREEMYTV" ] && warn "FreeMyTV isn't installed — the helper below would fall back to its own plain screen instead of FreeMyTV."
INSTALLED_HOME_REDIRECT=0
if confirm "Actually replace Fire TV's Home-button behavior — build & install a tiny helper that reopens FreeMyTV the instant Amazon's home screen appears?" Y; then
  build_and_install_home_redirect && INSTALLED_HOME_REDIRECT=1
fi

### ---------------------------------------------------------------- summary
echo
box "Setup complete"
echo "  Restore script: $STATE_FILE"
echo "  Undo this run's disables with:  ./universal.sh --restore"

if [ "$INSTALLED_FREEMYTV" = 1 ] && [ "$INSTALLED_HOME_REDIRECT" != 1 ]; then
  echo
  warn "FreeMyTV: its Settings screen should now be open on the TV. Fire OS always keeps Amazon's"
  warn "launcher bound to the physical Home button (no app can replace that) — FreeMyTV instead"
  warn "switches itself into 'Free My TV mode' from inside the app over its own local ADB connection."
  warn "On the TV: accept the 'Allow USB debugging?' prompt if it pops up, then turn on Free My TV"
  warn "mode from the Settings screen."
fi
if [ "$INSTALLED_HOME_REDIRECT" = 1 ]; then
  echo
  ok "Home button -> FreeMyTV is wired up: pressing Home now reopens FreeMyTV automatically,"
  ok "even though Amazon's launcher still technically answers it first (that redirect happens in"
  ok "well under a second). To go back to Amazon's real home screen at any point, either uninstall"
  ok "the helper (./universal.sh --restore undoes this run, including it) or turn off accessibility"
  ok "services for it in Settings > Accessibility on the TV."
fi
if [ "$INSTALLED_NETGUARD" = 1 ]; then
  warn "NetGuard: if the VPN permission wasn't pre-granted above, accept the one-time 'VPN connection"
  warn "request' prompt on the TV, then flip it on from NetGuard's own screen."
fi

echo
log "Re-run ./universal.sh any time — it reuses this same flow to pick up newer app releases or"
log "disable one more package later. No separate update-checker app needed."
