#!/bin/bash
# <bitbar.title>VPN Multi-Profile</bitbar.title>
# <bitbar.version>1.0</bitbar.version>
# <bitbar.author>AndersonCRocha</bitbar.author>
# <bitbar.author.github>AndersonCRocha</bitbar.author.github>
# <bitbar.desc>Status and control for VPNs managed by the 'vpn' CLI (https://github.com/AndersonCRocha/openfortivpn-macos)</bitbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>

# SwiftBar runs with a minimal PATH — make sure screen/pgrep/etc are found.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# Force UTF-8 so the shell forwards accents/emojis correctly to osascript.
export LC_ALL="en_US.UTF-8"
export LANG="en_US.UTF-8"

# Resolve the 'vpn' script via PATH. If the binary isn't on the default PATH,
# set VPN_BIN via SwiftBar env or add its directory to the export PATH above.
VPN_BIN="${VPN_BIN:-$(command -v vpn 2>/dev/null)}"
[ -z "$VPN_BIN" ] && VPN_BIN="/usr/local/bin/vpn"
STATE_DIR="$HOME/Library/Application Support/vpn"
PROFILES_DIR="$STATE_DIR/profiles"
LOG_DIR="/tmp"

# ------- helpers -------
is_openfortivpn_running() { pgrep -x openfortivpn >/dev/null; }

active_profile() {
    local line
    line=$(screen -ls 2>/dev/null | awk '$0 ~ /\.vpn-/ {print $1}' | tail -1)
    [ -z "$line" ] && return
    echo "$line" | sed -E 's/^[0-9]+\.vpn-//'
}

vpn_ip() {
    ifconfig ppp0 2>/dev/null | awk '/inet / {print $2; exit}'
}

profile_log() { echo "$LOG_DIR/vpn-$1.log"; }

is_waiting_mfa() {
    local p="$1"
    [ -z "$p" ] && return 1
    is_openfortivpn_running || return 1
    [ -z "$(vpn_ip)" ] || return 1
    grep -q "Two-factor authentication token" "$(profile_log "$p")" 2>/dev/null
}

list_profiles() {
    [ -d "$PROFILES_DIR" ] || return
    find "$PROFILES_DIR" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; | sort | while read -r p; do
        [ -f "$PROFILES_DIR/$p/config" ] && [ -f "$PROFILES_DIR/$p/user" ] && echo "$p"
    done
}

notify() {
    local msg="${1//\"/\\\"}"
    local title="${2:-VPN}"
    title="${title//\"/\\\"}"
    osascript -e "display notification \"$msg\" with title \"$title\"" 2>/dev/null
}

# Pulls the most likely error line out of the openfortivpn log.
extract_error() {
    local log="$1"
    [ ! -f "$log" ] && echo "" && return
    local err
    err=$(grep -iE "(ERROR|WARN|invalid|failed|denied|refused|unable|wrong|incorrect|authentication|timeout|no such host|could not resolve)" "$log" 2>/dev/null \
        | grep -viE "^(--- Starting|DEBUG)" \
        | grep -viE "You should not pass the password on the command line" \
        | tail -1 \
        | sed -E 's/^[[:space:]]*\[[^]]*\][[:space:]]*//; s/^[[:space:]]*//' \
        | head -c 200)
    echo "$err"
}

# True (return 0) if the profile has PREAUTH=1 — corporate flow that pushes MFA
# to the user's device before the tunnel starts. Takes longer, so the watchdog
# and marker TTL need to be extended.
profile_is_preauth() {
    local conf="$PROFILES_DIR/$1/config"
    [ -f "$conf" ] && grep -qE '^PREAUTH=1$' "$conf"
}

# Watchdog: re-invoke this plugin in the background to check state N seconds later.
spawn_watchdog() {
    local profile="$1" delay="${2:-25}"
    nohup "$0" watchdog "$profile" "$delay" >/dev/null 2>&1 &
    disown 2>/dev/null
}

# ------- action dispatcher -------
case "$1" in
    stop-clean)
        rm -f /tmp/vpn-connecting-*
        "$VPN_BIN" stop >/dev/null 2>&1
        exit 0
        ;;
    watchdog)
        PROFILE="$2"
        DELAY="${3:-25}"
        LOG="/tmp/vpn-$PROFILE.log"
        sleep "$DELAY"
        if ! pgrep -x openfortivpn >/dev/null; then
            ERR=$(extract_error "$LOG")
            [ -z "$ERR" ] && ERR="Connection dropped. Run: vpn log $PROFILE"
            notify "$ERR" "VPN — failure on $PROFILE"
        fi
        rm -f "/tmp/vpn-connecting-$PROFILE"
        exit 0
        ;;
    connect)
        PROFILE="$2"
        [ -z "$PROFILE" ] && exit 1
        USERF="$PROFILES_DIR/$PROFILE/user"
        if [ ! -f "$USERF" ]; then
            notify "Profile '$PROFILE' does not exist"
            exit 1
        fi
        P_USER=$(cat "$USERF")
        # If no password in Keychain, ask via a dialog (hidden input) and save it.
        if ! security find-generic-password -a "$P_USER" -s "vpn-$PROFILE" >/dev/null 2>&1; then
            PASS=$(osascript \
                -e "display dialog \"VPN password for $PROFILE (user $P_USER):\" default answer \"\" with title \"VPN Setup\" with icon note with hidden answer buttons {\"Cancel\", \"Save\"} default button \"Save\"" \
                -e "text returned of result" 2>/dev/null)
            [ -z "$PASS" ] && exit 0
            security add-generic-password -U -a "$P_USER" -s "vpn-$PROFILE" -w "$PASS"
        fi
        # Marker so the render shows 🟡 even if the attempt finishes before the next refresh.
        touch "/tmp/vpn-connecting-$PROFILE"
        notify "Connecting to $PROFILE..."
        ("$VPN_BIN" start "$PROFILE" >/dev/null 2>&1) &
        disown 2>/dev/null
        # PREAUTH profiles push MFA to the device first; the flow can take ~30s.
        if profile_is_preauth "$PROFILE"; then
            spawn_watchdog "$PROFILE" 60
        else
            spawn_watchdog "$PROFILE" 25
        fi
        exit 0
        ;;
    send-token)
        PROFILE="$2"
        [ -z "$PROFILE" ] && exit 1
        CODE=$(osascript \
            -e "display dialog \"MFA code for $PROFILE:\" default answer \"\" with title \"VPN Token\" with icon note buttons {\"Cancel\", \"Send\"} default button \"Send\"" \
            -e "text returned of result" 2>/dev/null)
        [ -z "$CODE" ] && exit 0
        "$VPN_BIN" token "$PROFILE" "$CODE" >/dev/null 2>&1
        notify "Token sent to $PROFILE"
        spawn_watchdog "$PROFILE" 15
        exit 0
        ;;
    change-password)
        PROFILE="$2"
        [ -z "$PROFILE" ] && exit 1
        USERF="$PROFILES_DIR/$PROFILE/user"
        [ ! -f "$USERF" ] && notify "Profile '$PROFILE' does not exist" && exit 1
        P_USER=$(cat "$USERF")
        PASS=$(osascript \
            -e "display dialog \"New VPN password for $PROFILE (user $P_USER):\" default answer \"\" with title \"VPN — Change password\" with icon note with hidden answer buttons {\"Cancel\", \"Save\"} default button \"Save\"" \
            -e "text returned of result" 2>/dev/null)
        [ -z "$PASS" ] && exit 0
        security add-generic-password -U -a "$P_USER" -s "vpn-$PROFILE" -w "$PASS"
        notify "Password for $PROFILE updated"
        exit 0
        ;;
    clone-profile)
        SRC="$2"
        [ -z "$SRC" ] && exit 1
        SRC_USER=$(cat "$PROFILES_DIR/$SRC/user" 2>/dev/null)
        [ -z "$SRC_USER" ] && notify "Source profile '$SRC' is invalid" && exit 1

        NEW_NAME=$(osascript \
            -e "display dialog \"Name for the new profile (a copy of $SRC):\" default answer \"\" with title \"VPN — Clone profile\" with icon note buttons {\"Cancel\", \"Next\"} default button \"Next\"" \
            -e "text returned of result" 2>/dev/null)
        [ -z "$NEW_NAME" ] && exit 0
        if [[ ! "$NEW_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            notify "Invalid name: use letters/digits/._-"; exit 1
        fi
        if [ -d "$PROFILES_DIR/$NEW_NAME" ]; then
            notify "Profile '$NEW_NAME' already exists"; exit 1
        fi

        NEW_USER=$(osascript \
            -e "display dialog \"Username for $NEW_NAME:\" default answer \"$SRC_USER\" with title \"VPN — Clone profile\" with icon note buttons {\"Cancel\", \"Create\"} default button \"Create\"" \
            -e "text returned of result" 2>/dev/null)
        [ -z "$NEW_USER" ] && exit 0

        mkdir -p "$PROFILES_DIR/$NEW_NAME"
        cp "$PROFILES_DIR/$SRC/config" "$PROFILES_DIR/$NEW_NAME/config"
        echo "$NEW_USER" > "$PROFILES_DIR/$NEW_NAME/user"
        notify "Profile '$NEW_NAME' created. Set its password via 🔑 Change password."
        exit 0
        ;;
    open-log)
        PROFILE="$2"
        LOG=$(profile_log "$PROFILE")
        [ -f "$LOG" ] && open -a Console "$LOG"
        exit 0
        ;;
esac

# ------- rendering -------
PROFILE_ACTIVE=$(active_profile)
IP=$(vpn_ip)

# Detects the "connecting" marker (fresh <30s). Expires on its own after that.
CONNECTING_PROFILE=""
NOW=$(date +%s)
for marker in /tmp/vpn-connecting-*; do
    [ -f "$marker" ] || continue
    MTIME=$(stat -f %m "$marker" 2>/dev/null || echo 0)
    AGE=$((NOW - MTIME))
    if [ "$AGE" -gt 60 ]; then
        rm -f "$marker"
        continue
    fi
    CONNECTING_PROFILE="${marker##/tmp/vpn-connecting-}"
done

if is_openfortivpn_running && [ -n "$IP" ]; then
    STATE="online"
    # If it's connected, the marker is stale — clear it.
    [ -n "$CONNECTING_PROFILE" ] && rm -f "/tmp/vpn-connecting-$CONNECTING_PROFILE"
    echo "🟢 $PROFILE_ACTIVE"
elif [ -n "$PROFILE_ACTIVE" ] && is_waiting_mfa "$PROFILE_ACTIVE"; then
    STATE="mfa"
    echo "🟡 $PROFILE_ACTIVE MFA"
elif [ -n "$PROFILE_ACTIVE" ]; then
    STATE="pending"
    echo "🟡 $PROFILE_ACTIVE"
elif [ -n "$CONNECTING_PROFILE" ]; then
    STATE="connecting"
    PROFILE_ACTIVE="$CONNECTING_PROFILE"
    echo "🟡 $CONNECTING_PROFILE"
else
    STATE="offline"
    echo "🔓 vpn"
fi

echo "---"

if [ -n "$PROFILE_ACTIVE" ]; then
    echo "Active profile: $PROFILE_ACTIVE | color=cyan"
    if is_openfortivpn_running; then
        echo "openfortivpn: running (PID $(pgrep -x openfortivpn))"
    else
        echo "openfortivpn: stopped | color=orange"
    fi
    [ -n "$IP" ] && echo "VPN IP: $IP | color=green" || echo "VPN IP: negotiating..."
    echo "---"

    if [ "$STATE" = "mfa" ]; then
        echo "🔑 Send MFA Token... | bash=\"$0\" param1=send-token param2=\"$PROFILE_ACTIVE\" terminal=false refresh=true"
    fi
    echo "🛑 Disconnect $PROFILE_ACTIVE | bash=\"$0\" param1=stop-clean terminal=false refresh=true"
    echo "🔑 Change password... | bash=\"$0\" param1=change-password param2=\"$PROFILE_ACTIVE\" terminal=false"
    echo "📄 Log for $PROFILE_ACTIVE | bash=\"$0\" param1=open-log param2=\"$PROFILE_ACTIVE\" terminal=false"
    echo "---"
fi

PROFILES=$(list_profiles)
if [ -n "$PROFILES" ]; then
    echo "Connect to: | color=gray"
    while read -r p; do
        [ -z "$p" ] && continue
        [ "$p" = "$PROFILE_ACTIVE" ] && continue
        echo "▸ $p | bash=\"$0\" param1=connect param2=\"$p\" terminal=false refresh=true"
        echo "-- 🔑 Change password for $p | bash=\"$0\" param1=change-password param2=\"$p\" terminal=false"
        echo "-- 📋 Clone $p... | bash=\"$0\" param1=clone-profile param2=\"$p\" terminal=false refresh=true"
    done <<< "$PROFILES"
    echo "---"
else
    echo "No profiles. Create one via terminal: | color=gray"
    echo "  vpn add <name> | color=gray"
    echo "---"
fi

echo "🛑 Disconnect (whatever is active) | bash=\"$0\" param1=stop-clean terminal=false refresh=true"
echo "🔄 Refresh | refresh=true"
