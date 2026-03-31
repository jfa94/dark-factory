#!/usr/bin/env bash
set -euo pipefail

# Swap factory autonomous settings into target project and restore on exit.
# Backup is stored inside the target project as settings.json.bak.

# Module state
_SETTINGS_SWAPPED=0
_SETTINGS_TARGET=""
_SETTINGS_BACKUP=""

# Copy factory settings.autonomous.json into target .claude/settings.json.
# Backs up the original first.
swap_settings() {
  local project_dir="$1"
  local target_settings="$project_dir/.claude/settings.json"
  local backup="$project_dir/.claude/settings.json.bak"
  local factory_settings="$FACTORY_DIR/templates/settings.autonomous.json"

  if [[ ! -f "$factory_settings" ]]; then
    log_error "Factory settings not found: $factory_settings"
    return 1
  fi

  if [[ ! -f "$target_settings" ]]; then
    log_error "Target settings not found: $target_settings"
    return 1
  fi

  # Track state before mutations so trap can restore on partial failure
  _SETTINGS_TARGET="$target_settings"
  _SETTINGS_BACKUP="$backup"

  # Backup original
  cp "$target_settings" "$backup"
  _SETTINGS_SWAPPED=1
  log_info "Backed up settings to $backup"

  # Inject factory settings
  cp "$factory_settings" "$target_settings"
  log_info "Swapped in autonomous settings"
}

# Restore original settings from backup.
# Safe to call multiple times.
restore_settings() {
  if [[ "$_SETTINGS_SWAPPED" -eq 0 ]]; then
    return 0
  fi

  if [[ -f "$_SETTINGS_BACKUP" ]]; then
    cp "$_SETTINGS_BACKUP" "$_SETTINGS_TARGET"
    rm -f "$_SETTINGS_BACKUP"
    log_info "Restored original settings"
  else
    log_warn "Settings backup not found; cannot restore"
  fi

  _SETTINGS_SWAPPED=0
}
