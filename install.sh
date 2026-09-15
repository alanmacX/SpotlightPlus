#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
SUPPORT_DIR="$HOME/Library/Application Support/SpotlightPlus"
BACKUP_DIR="$SUPPORT_DIR/Original"
PAYLOAD="$SUPPORT_DIR/state_tool.py"
AGENT="$HOME/Library/LaunchAgents/io.github.spotlightplus.enhanced-siri-ui-state.plist"
LABEL="io.github.spotlightplus.enhanced-siri-ui-state"
DOMAIN="gui/$(/usr/bin/id -u)"
PREFS="$HOME/Library/Preferences"
MANIFEST="$BACKUP_DIR/present-files.txt"
ABSENT="$BACKUP_DIR/absent-files.txt"
SYSTEM_FLAG_DIR="/Library/Preferences/FeatureFlags/Domain"
WRITING_TOOLS_FLAG="$SYSTEM_FLAG_DIR/WritingTools.plist"
SYSTEM_BACKUP_DIR="$BACKUP_DIR/SystemFeatureFlags"
SYSTEM_FLAG_PRESENT="$BACKUP_DIR/writing-tools-flag-present"
SYSTEM_FLAG_ABSENT="$BACKUP_DIR/writing-tools-flag-absent"
SYSTEM_FLAG_COMPLETE="$BACKUP_DIR/.writing-tools-flag-complete"

if [[ $(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1) -lt 27 ]]; then
  echo "SpotlightPlus 需要 macOS 27 或更高版本。" >&2
  exit 1
fi

if [[ ! -x /usr/bin/python3 ]]; then
  echo "系统缺少 /usr/bin/python3，无法安装。" >&2
  exit 1
fi

/bin/mkdir -p "$SUPPORT_DIR" "$HOME/Library/LaunchAgents"

if [[ ! -e "$BACKUP_DIR/.complete" ]]; then
  /bin/mkdir -p "$BACKUP_DIR/files"
  : > "$MANIFEST"
  : > "$ABSENT"

  targets=(
    "Library/Preferences/com.apple.CloudSubscriptionFeatures.cache.plist"
    "Library/Preferences/com.apple.CloudSubscriptionFeatures.waitlist.plist"
    "Library/Preferences/com.apple.gms.availability.plist"
    "Library/Preferences/com.apple.siri.plist"
    "Library/Preferences/com.apple.siri.generativeassistantsettings.plist"
  )
  for path in "$PREFS"/ByHost/.GlobalPreferences.*.plist(N); do
    targets+=("${path#$HOME/}")
  done

  for relative in "${targets[@]}"; do
    source="$HOME/$relative"
    if [[ -e "$source" ]]; then
      destination="$BACKUP_DIR/files/$relative"
      /bin/mkdir -p "${destination:h}"
      /usr/bin/ditto "$source" "$destination"
      print -r -- "$relative" >> "$MANIFEST"
    else
      print -r -- "$relative" >> "$ABSENT"
    fi
  done
  /usr/bin/touch "$BACKUP_DIR/.complete"
fi

# Enhanced Siri availability also exposes AppKit's unfinished text-selection
# prompt. On unsupported regional configurations its remote Campo view can
# leave AppKit's menu/event tracking stuck. Disable only that lightweight UI;
# the Spotlight Assistant Island is controlled by a different gate.
echo "需要管理员密码以关闭可能卡住系统交互的文本选区 Ask Siri；不会关闭 SIP 或修改 /System。"
/usr/bin/sudo -v
if [[ ! -e "$SYSTEM_FLAG_COMPLETE" ]]; then
  /bin/mkdir -p "$SYSTEM_BACKUP_DIR"
  if [[ -e "$WRITING_TOOLS_FLAG" ]]; then
    /usr/bin/sudo /usr/bin/ditto \
      "$WRITING_TOOLS_FLAG" "$SYSTEM_BACKUP_DIR/WritingTools.plist"
    /usr/bin/sudo /usr/sbin/chown \
      "$(/usr/bin/id -u):$(/usr/bin/id -g)" "$SYSTEM_BACKUP_DIR/WritingTools.plist"
    /bin/chmod 600 "$SYSTEM_BACKUP_DIR/WritingTools.plist"
    /usr/bin/touch "$SYSTEM_FLAG_PRESENT"
  else
    /usr/bin/touch "$SYSTEM_FLAG_ABSENT"
  fi
  /usr/bin/touch "$SYSTEM_FLAG_COMPLETE"
fi

/usr/bin/sudo /bin/mkdir -p "$SYSTEM_FLAG_DIR"
/usr/bin/sudo /usr/bin/defaults write \
  "$SYSTEM_FLAG_DIR/WritingTools" LightweightUI_macOS -dict Enabled -bool false
/usr/bin/sudo /usr/sbin/chown root:wheel "$WRITING_TOOLS_FLAG"
/usr/bin/sudo /bin/chmod 644 "$WRITING_TOOLS_FLAG"

/usr/bin/ditto "$SCRIPT_DIR/state_tool.py" "$PAYLOAD"
/bin/chmod 755 "$PAYLOAD"

/usr/bin/plutil -create xml1 "$AGENT"
/usr/bin/plutil -insert Label -string "$LABEL" "$AGENT"
/usr/bin/plutil -insert ProgramArguments -xml \
  "<array><string>/usr/bin/python3</string><string>$PAYLOAD</string><string>startup</string></array>" "$AGENT"
/usr/bin/plutil -insert RunAtLoad -bool true "$AGENT"
/usr/bin/plutil -insert StartInterval -integer 300 "$AGENT"
/usr/bin/plutil -insert WatchPaths -xml \
  "<array><string>$PREFS/com.apple.CloudSubscriptionFeatures.cache.plist</string><string>$PREFS/com.apple.CloudSubscriptionFeatures.waitlist.plist</string><string>$PREFS/com.apple.gms.availability.plist</string></array>" "$AGENT"
/usr/bin/plutil -insert ProcessType -string Background "$AGENT"
/usr/bin/plutil -insert LimitLoadToSessionType -string Aqua "$AGENT"
/usr/bin/plutil -insert LowPriorityIO -bool true "$AGENT"
/usr/bin/plutil -insert StandardOutPath -string "$SUPPORT_DIR/repair.log" "$AGENT"
/usr/bin/plutil -insert StandardErrorPath -string "$SUPPORT_DIR/repair.log" "$AGENT"

/bin/launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
/usr/bin/python3 "$PAYLOAD" repair
/bin/launchctl bootstrap "$DOMAIN" "$AGENT"

echo "SpotlightPlus 已安装：登录时、状态文件变化时及每 5 分钟自动维护 Enhanced Siri UI 状态。"
echo "文本选区的 Ask Siri 浮动界面已关闭；重新登录或重启后对所有 App 生效，Spotlight 保持启用。"
echo "安装过程未打开或激活 Siri AI.app，也未修改 SIP 或 /System。"
echo "如需完整恢复安装前的用户设置，请运行 ./uninstall.sh。"
