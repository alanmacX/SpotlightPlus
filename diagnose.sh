#!/bin/zsh

# Collect a small, read-only SpotlightPlus diagnostic report for GitHub Issues.
# The report intentionally excludes serial numbers, Apple Account information,
# Siri requests, unified logs, and the contents of preference/backup files.

set -u
setopt pipefail
umask 077

SCRIPT_DIR=${0:A:h}
SUPPORT_DIR="$HOME/Library/Application Support/SpotlightPlus"
PAYLOAD="$SUPPORT_DIR/state_tool.py"
AGENT="$HOME/Library/LaunchAgents/io.github.spotlightplus.enhanced-siri-ui-state.plist"
LABEL="io.github.spotlightplus.enhanced-siri-ui-state"
DOMAIN="gui/$(/usr/bin/id -u)"
PREFS="$HOME/Library/Preferences"
STAMP=$(/bin/date '+%Y%m%d-%H%M%S')
OUTPUT=${1:-"$PWD/SpotlightPlus-diagnostics-$STAMP.txt"}

if [[ -e "$OUTPUT" ]]; then
  echo "诊断文件已存在，为避免覆盖已停止：$OUTPUT" >&2
  exit 1
fi

RAW=$(/usr/bin/mktemp -t spotlightplus-diagnostics)
exec 3>&1
exec >"$RAW" 2>&1

section() {
  print
  print "===== $1 ====="
}

read_default() {
  local domain=$1
  local key=$2
  local value
  value=$(/usr/bin/defaults read "$domain" "$key" 2>/dev/null) || value="<missing>"
  print "$domain.$key=$value"
}

print "SpotlightPlus diagnostic report"
print "generated=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
print "privacy=No serial number, Apple Account, Siri query, preference contents, or unified logs collected"

section "System"
/usr/bin/sw_vers 2>&1
print "architecture=$(/usr/bin/uname -m)"
print "hardware_model=$(/usr/sbin/sysctl -n hw.model 2>/dev/null || print '<unavailable>')"
print "boot_time=$(/usr/sbin/sysctl -n kern.boottime 2>/dev/null || print '<unavailable>')"
print "uptime=$(/usr/bin/uptime 2>/dev/null || print '<unavailable>')"
/usr/bin/csrutil status 2>&1 || true
read_default NSGlobalDomain AppleLocale

section "Apple UI host"
CAMPO_APP="/System/Applications/Siri AI.app"
if [[ -d "$CAMPO_APP" ]]; then
  print "campo_app=present"
  print "campo_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CAMPO_APP/Contents/Info.plist" 2>/dev/null || print '<missing>')"
  print "campo_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$CAMPO_APP/Contents/Info.plist" 2>/dev/null || print '<missing>')"
else
  print "campo_app=missing"
fi

CAMPO_PID=$(/usr/bin/pgrep -x "Siri AI" | /usr/bin/head -n 1)
if [[ -n "$CAMPO_PID" ]]; then
  print "campo_process=running"
  /bin/ps -p "$CAMPO_PID" -o pid=,rss=,%cpu=,etime=,comm=
else
  print "campo_process=not-running"
fi

section "SpotlightPlus installation"
print "repository_state_tool=$([[ -f "$SCRIPT_DIR/state_tool.py" ]] && print present || print missing)"
print "installed_state_tool=$([[ -f "$PAYLOAD" ]] && print present || print missing)"
print "launch_agent=$([[ -f "$AGENT" ]] && print present || print missing)"
print "original_backup=$([[ -f "$SUPPORT_DIR/Original/.complete" ]] && print complete || print missing)"
if [[ -f "$SCRIPT_DIR/state_tool.py" ]]; then
  print "repository_state_tool_sha256=$(/usr/bin/shasum -a 256 "$SCRIPT_DIR/state_tool.py" | /usr/bin/awk '{print $1}')"
fi
if [[ -f "$PAYLOAD" ]]; then
  print "installed_state_tool_sha256=$(/usr/bin/shasum -a 256 "$PAYLOAD" | /usr/bin/awk '{print $1}')"
fi

section "LaunchAgent summary"
if [[ -f "$AGENT" ]]; then
  for key in Label RunAtLoad StartInterval LimitLoadToSessionType ProcessType; do
    value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$AGENT" 2>/dev/null) || value="<missing>"
    print "$key=$value"
  done
  command=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' "$AGENT" 2>/dev/null) || command="<missing>"
  print "command=$command"
  print "WatchPaths:"
  /usr/libexec/PlistBuddy -c 'Print :WatchPaths' "$AGENT" 2>/dev/null || print "<missing>"
else
  print "LaunchAgent plist is not installed"
fi

/bin/launchctl print "$DOMAIN/$LABEL" 2>&1 | \
  /usr/bin/grep -E '^[[:space:]]*(state|runs|last exit code|run interval) =' || true

section "Maintained state"
if [[ -f "$PAYLOAD" ]]; then
  /usr/bin/python3 "$PAYLOAD" status 2>&1 || print "state_tool_status=failed:$?"
else
  print "state_tool_status=unavailable"
fi
read_default com.apple.siri GMSignedUp
read_default com.apple.siri.generativeassistantsettings isEnabled
read_default com.apple.siri TypeToSiriEnabled
read_default com.apple.siri KeyboardShortcutSAE

section "Relevant files"
files=(
  "$PREFS/com.apple.CloudSubscriptionFeatures.cache.plist"
  "$PREFS/com.apple.CloudSubscriptionFeatures.waitlist.plist"
  "$PREFS/com.apple.gms.availability.plist"
  "$PREFS/com.apple.siri.plist"
  "$PREFS/com.apple.siri.generativeassistantsettings.plist"
  "$SUPPORT_DIR/last-campo-refresh-boot"
)
for path in "${files[@]}"; do
  if [[ -e "$path" ]]; then
    /usr/bin/stat -f '%N | size=%z | modified=%Sm | mode=%Sp' -t '%Y-%m-%dT%H:%M:%S%z' "$path"
  else
    print "$path | missing"
  fi
done

section "SpotlightUI Feature Flag"
FLAG="/Library/Preferences/FeatureFlags/Domain/SpotlightUI.plist"
if [[ -r "$FLAG" ]]; then
  /usr/bin/plutil -p "$FLAG" 2>&1
elif [[ -e "$FLAG" ]]; then
  print "present-but-not-readable-without-elevated-permission"
else
  print "missing-or-inaccessible-without-elevated-permission"
fi

section "Text-selection Ask Siri isolation"
WRITING_TOOLS_FLAG="/Library/Preferences/FeatureFlags/Domain/WritingTools.plist"
raw_value=$(/usr/bin/defaults read \
  "/Library/Preferences/FeatureFlags/Domain/WritingTools" LightweightUI_macOS 2>/dev/null) \
  || raw_value=""
value=$(print -r -- "$raw_value" | /usr/bin/awk '/Enabled/ { gsub(/[^01]/, "", $0); print; exit }')
if [[ "$value" == "0" ]]; then
  print "WritingTools.LightweightUI_macOS.Enabled=false"
elif [[ "$value" == "1" ]]; then
  print "WritingTools.LightweightUI_macOS.Enabled=true"
elif [[ -e "$WRITING_TOOLS_FLAG" ]]; then
  print "WritingTools.LightweightUI_macOS.Enabled=<missing-or-unreadable>"
else
  print "WritingTools.plist=absent"
fi

section "SpotlightPlus repair log (last 100 lines)"
if [[ -f "$SUPPORT_DIR/repair.log" ]]; then
  /usr/bin/tail -n 100 "$SUPPORT_DIR/repair.log"
else
  print "repair.log is missing"
fi

section "提交 Issue 时请手动填写"
print "实际界面（旧版/新版/无界面/小型 Ask Siri）："
print "登录后等待了多久："
print "手动打开 Siri AI.app 后结果是否变化："
print "复现步骤："

# Replace the home directory and short username before producing the shareable
# report. The raw temporary file is private (umask 077) and removed afterward.
/usr/bin/sed \
  -e "s|$HOME|~|g" \
  -e "s|$(/usr/bin/id -un)|<user>|g" \
  "$RAW" > "$OUTPUT"
/bin/rm -f "$RAW"

exec 1>&3 2>&3
print "诊断完成：$OUTPUT"
print "提交 Issue 前请自行检查文件内容；脚本不会自动上传任何信息。"
