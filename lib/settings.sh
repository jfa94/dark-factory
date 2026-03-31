#!/usr/bin/env bash
set -euo pipefail

# Swap factory autonomous settings into target project and restore on exit.
# Backup is stored inside the target project as settings.json.bak.

# Module state
_SETTINGS_SWAPPED=0
_SETTINGS_TARGET=""
_SETTINGS_BACKUP=""
_SETTINGS_CREATED_DIR=0
_SETTINGS_NO_ORIGINAL=0

# Copy factory settings.autonomous.json into target .claude/settings.json.
# Backs up the original first. Creates .claude/ if missing.
swap_settings() {
  local project_dir="$1"
  local target_dir="$project_dir/.claude"
  local target_settings="$target_dir/settings.json"
  local backup="$target_dir/settings.json.bak"
  local factory_settings="$FACTORY_DIR/templates/settings.autonomous.json"

  if [[ ! -f "$factory_settings" ]]; then
    log_error "Factory settings not found: $factory_settings"
    return 1
  fi

  # Track state before mutations so trap can restore on partial failure
  _SETTINGS_TARGET="$target_settings"
  _SETTINGS_BACKUP="$backup"

  # Create .claude/ if missing; track so restore can clean up
  if [[ ! -d "$target_dir" ]]; then
    mkdir -p "$target_dir"
    _SETTINGS_CREATED_DIR=1
  fi

  # Backup original (if it exists)
  if [[ -f "$target_settings" ]]; then
    cp "$target_settings" "$backup"
    log_info "Backed up settings to $backup"
  else
    _SETTINGS_NO_ORIGINAL=1
    log_info "No existing settings.json — will remove on restore"
  fi

  _SETTINGS_SWAPPED=1

  # Inject factory settings
  cp "$factory_settings" "$target_settings"
  log_info "Swapped in autonomous settings"
}

# Restore original settings from backup.
# If no original existed, removes the injected file (and .claude/ if we created it).
# Safe to call multiple times.
restore_settings() {
  if [[ "$_SETTINGS_SWAPPED" -eq 0 ]]; then
    return 0
  fi

  if [[ "$_SETTINGS_NO_ORIGINAL" -eq 1 ]]; then
    # No original file — remove what we injected
    rm -f "$_SETTINGS_TARGET"
    if [[ "$_SETTINGS_CREATED_DIR" -eq 1 ]]; then
      rmdir "$(dirname "$_SETTINGS_TARGET")" 2>/dev/null || true
    fi
    log_info "Removed injected settings (no original existed)"
  elif [[ -f "$_SETTINGS_BACKUP" ]]; then
    cp "$_SETTINGS_BACKUP" "$_SETTINGS_TARGET"
    rm -f "$_SETTINGS_BACKUP"
    log_info "Restored original settings"
  else
    log_warn "Settings backup not found; cannot restore"
  fi

  _SETTINGS_SWAPPED=0
}
