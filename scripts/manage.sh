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
BACKUP="$HOME/Applications/LayoutFixer.previous.zip"
LEGACY_BACKUP="$HOME/Applications/LayoutFixer.previous.app"
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
install_log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}
install_app() {
  local logdir="$HOME/Library/Logs/DoubleShift"
  mkdir -p "$logdir"
  install_app_steps "$@" 2>&1 | tee -a "$logdir/install.log"
}
install_app_steps() {
  install_log "Начало установки. Исходники: $ROOT"
  if [[ -d "$APP" ]]; then
    local installed_version
    installed_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 'неизвестна')"
    install_log "Найдена установленная версия $installed_version: $APP. Будет заменена."
  else
    install_log "Приложение не установлено: $APP. Первая установка."
  fi
  install_log "Сборка новой версии; установленная версия пока сохраняется."
  "$ROOT/scripts/build.sh"
  mkdir -p "$HOME/Applications" "$(dirname "$CLI")"
  local stage
  stage="$(mktemp -d "$HOME/Applications/.double-shift.XXXXXX")"
  ditto "$ROOT/build/LayoutFixer.app" "$stage/LayoutFixer.app"
  codesign --verify --strict "$stage/LayoutFixer.app"
  install_log "Сборка и подпись проверены. Останавливаем приложение."
  stop
  # Archive the backup: moving the live .app to .previous.app makes macOS
  # permission records follow the renamed application instead of the new one.
  if [[ -d "$APP" ]]; then
    if ! ditto -c -k --sequesterRsrc --keepParent "$APP" "$stage/previous.zip"; then
      start || true
      return 1
    fi
    mv "$stage/previous.zip" "$BACKUP"
    install_log "Резервная копия сохранена: $BACKUP"
  elif [[ -d "$LEGACY_BACKUP" ]]; then
    # Normalize the archive's top-level name for rollback.
    mkdir "$stage/archive"
    ditto "$LEGACY_BACKUP" "$stage/archive/LayoutFixer.app"
    ditto -c -k --sequesterRsrc --keepParent "$stage/archive/LayoutFixer.app" "$stage/previous.zip"
    mv "$stage/previous.zip" "$BACKUP"
    rm -rf "$stage/archive"
  fi
  if [[ -d "$APP" ]]; then
    install_log "Удаляем старую установленную версию: $APP"
  fi
  if [[ -d "$LEGACY_BACKUP" ]]; then
    install_log "Удаляем устаревшую копию приложения: $LEGACY_BACKUP"
  fi
  rm -rf "$APP" "$LEGACY_BACKUP"
  install_log "Устанавливаем новую версию: $APP"
  if ! mv "$stage/LayoutFixer.app" "$APP"; then
    install_log "ОШИБКА установки. Восстанавливаем резервную копию."
    [[ ! -f "$BACKUP" ]] || ditto -x -k "$BACKUP" "$HOME/Applications"
    start || true
    return 1
  fi
  rmdir "$stage"
  ln -sfn "$ROOT/scripts/manage.sh" "$CLI"
  if [[ "${1:-}" != --no-autostart ]]; then autostart; fi
  install_log "Запускаем установленное приложение."
  start
  install_log "Установка завершена: $APP"
  echo "Журнал установки: $HOME/Library/Logs/DoubleShift/install.log"
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
    [[ -d "$APP" ]] || { echo 'Нет установленной версии.' >&2; exit 1; }
    stage="$(mktemp -d "$HOME/Applications/.double-shift.XXXXXX")"
    if [[ -f "$BACKUP" ]]; then
      ditto -x -k "$BACKUP" "$stage"
    elif [[ -d "$LEGACY_BACKUP" ]]; then
      ditto "$LEGACY_BACKUP" "$stage/LayoutFixer.app"
    else
      rmdir "$stage"
      echo 'Нет предыдущей версии.' >&2; exit 1
    fi
    codesign --verify --strict "$stage/LayoutFixer.app"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$stage/current.zip"
    stop
    rm -rf "$APP"
    if ! mv "$stage/LayoutFixer.app" "$APP"; then
      ditto -x -k "$stage/current.zip" "$HOME/Applications"
      start || true
      exit 1
    fi
    mv "$stage/current.zip" "$BACKUP"
    rm -rf "$LEGACY_BACKUP"
    rmdir "$stage"
    start
    ;;
  uninstall)
    stop
    rm -f "$PLIST" "$CLI" "$BACKUP"
    rm -rf "$APP" "$HOME/Applications/LayoutFixer.previous.app"
    echo 'Удалено. Настройки и журналы сохранены.'
    ;;
  *) echo "Использование: $0 {install [--no-autostart]|update|restart|status|autostart-on|autostart-off|rollback|uninstall}" ;;
esac
