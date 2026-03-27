#!/usr/bin/env bash
set -euo pipefail

# cleanup_backups.sh - garbage collect old backup archives per retention policy
# Usage: cleanup_backups.sh <backup-root> <retention-months> [state-file]

if [ "$#" -lt 2 ]; then
  echo "Usage: cleanup_backups.sh <backup-root> <retention-months> [state-file]" >&2
  exit 1
fi

backup_root="$1"
retention_months="$2"
state_file="${3:-data/state.json}"

[ -d "$backup_root" ] || {
  echo "Backup directory does not exist: $backup_root" >&2
  exit 1
}

# Calculate cutoff timestamp (now - retention period)
cutoff_seconds=$((retention_months * 30 * 24 * 3600))
cutoff_date=$(date -d "${retention_months} months ago" -u +"%Y%m%d" 2>/dev/null || \
              date -u -v-${retention_months}m +"%Y%m%d")

echo "Backup retention policy: keep archives from last $retention_months months (cutoff: $cutoff_date)"

deleted_count=0
freed_bytes=0

# Find and delete archives older than retention period
while IFS= read -r archive; do
  # Extract date from filename: <service-id>-YYYYMMDDTHHMMSSZ.tar.gz
  archive_name=$(basename "$archive")
  archive_date=$(echo "$archive_name" | grep -oE '[0-9]{8}' | head -1)

  if [ -z "$archive_date" ]; then
    echo "  [SKIP] Cannot parse date from: $archive_name"
    continue
  fi

  # Compare dates
  if [ "$archive_date" -lt "$cutoff_date" ]; then
    archive_size=$(stat --printf="%s" "$archive" 2>/dev/null || stat -f%z "$archive" 2>/dev/null || echo 0)
    echo "  [DELETE] $archive_name (${archive_date}, +$(($archive_size / 1024 / 1024)) MB)"
    rm -f "$archive"
    deleted_count=$((deleted_count + 1))
    freed_bytes=$((freed_bytes + archive_size))
  fi
done < <(find "$backup_root" -type f -name "*.tar.gz" 2>/dev/null)

freed_mb=$((freed_bytes / 1024 / 1024))
echo "Cleanup complete: deleted $deleted_count archives, freed ${freed_mb}MB"

# Log cleanup to state
jq --arg deleted "$deleted_count" \
   --arg freed "$freed_mb" \
   --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
   '.maintenance.lastBackupCleanup = {
     ts: $ts,
     deleted: ($deleted | tonumber),
     freedMB: ($freed | tonumber)
   }' "$state_file" >"${state_file}.tmp"

mv "${state_file}.tmp" "$state_file"

echo "✓ Backup cleanup logged to state"
