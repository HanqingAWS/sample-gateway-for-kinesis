#!/bin/sh
set -e

DATA_DIR="/var/lib/vector"
RETENTION_HOURS="${EBS_RETENTION_HOURS:-24}"
RECLAIM_PERCENT="${EBS_RECLAIM_PERCENT:-80}"
CHECK_INTERVAL=300  # check every 5 minutes

# Background disk management
disk_cleanup() {
  while true; do
    sleep "$CHECK_INTERVAL"

    # Check disk usage percentage
    USAGE=$(df "$DATA_DIR" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
    if [ -z "$USAGE" ]; then
      continue
    fi

    # Delete files older than retention period
    if [ "$USAGE" -gt "$RECLAIM_PERCENT" ]; then
      echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') disk-cleanup: usage=${USAGE}% > threshold=${RECLAIM_PERCENT}%, cleaning files older than ${RETENTION_HOURS}h"
      find "$DATA_DIR" -type f -name "*.log" -mmin +$((RETENTION_HOURS * 60)) -delete 2>/dev/null || true
      find "$DATA_DIR" -type f -name "*.db" -mmin +$((RETENTION_HOURS * 60)) -delete 2>/dev/null || true
      AFTER=$(df "$DATA_DIR" | tail -1 | awk '{print $5}')
      echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') disk-cleanup: after cleanup usage=${AFTER}"
    fi
  done
}

# Start disk cleanup in background
disk_cleanup &

# Start Vector
exec vector --config /etc/vector/vector.toml
