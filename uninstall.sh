#!/bin/zsh
set -euo pipefail

SUPPORT_DIR="$HOME/Library/Application Support/SpotlightPlus"
BACKUP_DIR="$SUPPORT_DIR/Original"
AGENT="$HOME/Library/LaunchAgents/io.github.spotlightplus.enhanced-siri-ui-state.plist"
LABEL="io.github.spotlightplus.enhanced-siri-ui-state"
DOMAIN="gui/$(/usr/bin/id -u)"
MANIFEST="$BACKUP_DIR/present-files.txt"
ABSENT="$BACKUP_DIR/absent-files.txt"
SYSTEM_FLAG_DIR="/Library/Preferences/FeatureFlags/Domain"
WRITING_TOOLS_FLAG="$SYSTEM_FLAG_DIR/WritingTools.plist"
SYSTEM_BACKUP_DIR="$BACKUP_DIR/SystemFeatureFlags"
SYSTEM_FLAG_PRESENT="$BACKUP_DIR/writing-tools-flag-present"
SYSTEM_FLAG_ABSENT="$BACKUP_DIR/writing-tools-flag-absent"
SYSTEM_FLAG_COMPLETE="$BACKUP_DIR/.writing-tools-flag-complete"

if [[ ! -e "$BACKUP_DIR/.complete" || ! -e "$MANIFEST" || ! -e "$ABSENT" ]]; then
  echo "未找到完整的 SpotlightPlus 原始状态备份；为避免误操作，没有修改任何文件。" >&2
  exit 1
fi

if [[ -e "$SYSTEM_FLAG_COMPLETE" ]]; then
  if [[ -e "$SYSTEM_FLAG_PRESENT" ]]; then
    if [[ ! -e "$SYSTEM_BACKUP_DIR/WritingTools.plist" ]]; then
      echo "系统 Feature Flag 备份不完整；为避免误操作，没有继续卸载。" >&2
      exit 2
    fi
  elif [[ ! -e "$SYSTEM_FLAG_ABSENT" ]]; then
    echo "系统 Feature Flag 备份状态不完整；为避免误操作，没有继续卸载。" >&2
    exit 2
  fi
  echo "需要管理员密码以恢复安装前的 WritingTools Feature Flag；不会修改 SIP 或 /System。"
  /usr/bin/sudo -v
fi

/bin/launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

if [[ -e "$SYSTEM_FLAG_COMPLETE" ]]; then
  if [[ -e "$SYSTEM_FLAG_PRESENT" ]]; then
    /usr/bin/sudo /bin/mkdir -p "$SYSTEM_FLAG_DIR"
    /usr/bin/sudo /usr/bin/ditto \
      "$SYSTEM_BACKUP_DIR/WritingTools.plist" "$WRITING_TOOLS_FLAG"
    /usr/bin/sudo /usr/sbin/chown root:wheel "$WRITING_TOOLS_FLAG"
    /usr/bin/sudo /bin/chmod 644 "$WRITING_TOOLS_FLAG"
  else
    /usr/bin/sudo /bin/rm -f "$WRITING_TOOLS_FLAG"
  fi
fi

while IFS= read -r relative; do
  [[ -n "$relative" ]] || continue
  source="$BACKUP_DIR/files/$relative"
  destination="$HOME/$relative"
  if [[ ! -e "$source" ]]; then
    echo "备份不完整，缺少：$relative" >&2
    exit 2
  fi
  /bin/mkdir -p "${destination:h}"
  /usr/bin/ditto "$source" "$destination"
done < "$MANIFEST"

while IFS= read -r relative; do
  [[ -n "$relative" ]] || continue
  /bin/rm -f "$HOME/$relative"
done < "$ABSENT"

for name in \
  com.apple.CloudSubscriptionFeature.Changed \
  com.apple.siri.orchestration.capabilities.didChange \
  com.apple.gms.availability.notification; do
  /usr/bin/notifyutil -p "$name" || true
done

/usr/bin/killall "Siri AI" 2>/dev/null || true
/bin/rm -f "$AGENT"
/bin/rm -rf "$SUPPORT_DIR"

echo "SpotlightPlus 已卸载，并已恢复安装前的用户偏好快照。"
echo "WritingTools Feature Flag 已恢复；重新登录或重启后对所有 App 生效。"
echo "SIP、/System、eligibility 数据库及系统 com.apple.campo 任务均未修改。"
echo "独立创建的 /Library SpotlightUI Feature Flag override 保持不变。"
