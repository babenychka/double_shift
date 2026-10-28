#!/bin/bash
set -euo pipefail
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  BASE="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" == /* ]] || SOURCE="$BASE/$SOURCE"
done
ROOT="$(cd "$(dirname "$SOURCE")/.." && pwd)"
APP="$HOME/Applications/LayoutFixer.app"
LABEL=com.local.layoutfixer
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
CLI="$HOME/.local/bin/double-shift"
stop() {
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  pkill -x LayoutFixer >/dev/null 2>&1 || true
}
start() {
  if [[ -f "$PLIST" ]]; then
    launchctl bootstrap "$DOMAIN" "$PLIST"
  else
    open "$APP"
  fi
}
autostart() {
  mkdir -p "$(dirname "$PLIST")" "$HOME/Library/Logs/DoubleShift"
  # plutil handles XML escaping for home directories with special characters.
  plutil -create xml1 "$PLIST"
  plutil -insert Label -string "$LABEL" "$PLIST"
  plutil -insert ProgramArguments -json '[]' "$PLIST"
  plutil -insert ProgramArguments.0 -string "$APP/Contents/MacOS/LayoutFixer" "$PLIST"
  plutil -insert RunAtLoad -bool YES "$PLIST"
  plutil -insert StandardOutPath -string "$HOME/Library/Logs/DoubleShift/output.log" "$PLIST"
  plutil -insert StandardErrorPath -string "$HOME/Library/Logs/DoubleShift/error.log" "$PLIST"
}
install_app() {
  "$ROOT/scripts/build.sh"
  mkdir -p "$HOME/Applications" "$(dirname "$CLI")"
  local stage
  stage="$(mktemp -d "$HOME/Applications/.double-shift.XXXXXX")"
  ditto "$ROOT/build/LayoutFixer.app" "$stage/LayoutFixer.app"
  codesign --verify --strict "$stage/LayoutFixer.app"
  stop
  # Keep one previous installed version; replace only after successful compilation.
  if [[ -d "$APP" ]]; then
    rm -rf "$HOME/Applications/LayoutFixer.previous.app"
    mv "$APP" "$HOME/Applications/LayoutFixer.previous.app"
  fi
  if ! mv "$stage/LayoutFixer.app" "$APP"; then
    [[ ! -d "$HOME/Applications/LayoutFixer.previous.app" ]] || mv "$HOME/Applications/LayoutFixer.previous.app" "$APP"
    start || true
    return 1
  fi
  rmdir "$stage"
  ln -sfn "$ROOT/scripts/manage.sh" "$CLI"
  if [[ "${1:-}" != --no-autostart ]]; then autostart; fi
  start
  echo "Установлено: $APP"
  echo "Управление: $CLI {update|restart|status|rollback|uninstall}"
  echo 'Разрешите LayoutFixer в System Settings → Privacy & Security → Accessibility и Input Monitoring, затем выполните restart.'
}
case "${1:-help}" in
  install) [[ "${2:-}" == '' || "${2:-}" == --no-autostart ]] || exit 2; install_app "${2:-}" ;;
  update)
    [[ -d "$ROOT/.git" || -f "$ROOT/.git" ]] || { echo 'Обновление требует отдельного git clone проекта.' >&2; exit 1; }
    [[ -z "$(git -C "$ROOT" status --porcelain)" ]] || { echo 'Сначала сохраните изменения в репозитории.' >&2; exit 1; }
    git -C "$ROOT" pull --ff-only
    # Re-enter the updated script so updates to the installer take effect.
    if [[ -f "$PLIST" ]]; then exec "$ROOT/scripts/manage.sh" install; fi
    exec "$ROOT/scripts/manage.sh" install --no-autostart
    ;;
  restart) stop; start ;;
  status)
    if [[ -d "$APP" ]]; then /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"; else echo 'Не установлено'; fi
    if pgrep -x LayoutFixer >/dev/null; then echo 'Запущено'; else echo 'Остановлено'; fi
    if [[ -f "$PLIST" ]]; then echo 'Автозапуск включён'; else echo 'Автозапуск выключен'; fi
    ;;
  autostart-on) stop; autostart; start ;;
  autostart-off) stop; rm -f "$PLIST"; start ;;
  rollback)
    PREV="$HOME/Applications/LayoutFixer.previous.app"
    [[ -d "$PREV" && -d "$APP" ]] || { echo 'Нет предыдущей версии.' >&2; exit 1; }
    stop
    mv "$APP" "$HOME/Applications/LayoutFixer.swap.app"
    mv "$PREV" "$APP"
    mv "$HOME/Applications/LayoutFixer.swap.app" "$PREV"
    start
    ;;
  uninstall)
    stop
    rm -f "$PLIST" "$CLI"
    rm -rf "$APP" "$HOME/Applications/LayoutFixer.previous.app"
    echo 'Удалено. Настройки и журналы сохранены.'
    ;;
  *) echo "Использование: $0 {install [--no-autostart]|update|restart|status|autostart-on|autostart-off|rollback|uninstall}" ;;
esac
