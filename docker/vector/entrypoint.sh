#!/bin/sh
set -e

DATA_DIR="/var/lib/vector"
RETENTION_HOURS="${EBS_RETENTION_HOURS:-24}"
RECLAIM_PERCENT="${EBS_RECLAIM_PERCENT:-80}"
CHECK_INTERVAL=300  # check every 5 minutes
CONFIG_FILE="/etc/vector/vector.toml"

# ──────────────────────────────────────────
# Generate vector.toml from ROUTE_MAP
# Format: /path1:stream1,/path2:stream2,...
# Fallback: single-stream mode via KINESIS_STREAM_NAME
# ──────────────────────────────────────────
generate_config() {
  local region="${KINESIS_REGION:?KINESIS_REGION is required}"
  local route_map="${ROUTE_MAP:-}"
  local buffer_max_size="${VECTOR_BUFFER_MAX_SIZE:-858993459200}"

  cat > "$CONFIG_FILE" <<'HEADER'
data_dir = "/var/lib/vector"

[sources.nginx_events]
type = "http_server"
address = "0.0.0.0:8686"
decoding.codec = "json"
HEADER

  # Single-stream fallback (backward compatible)
  if [ -z "$route_map" ]; then
    local stream="${KINESIS_STREAM_NAME:?Either ROUTE_MAP or KINESIS_STREAM_NAME is required}"
    cat >> "$CONFIG_FILE" <<EOF

[transforms.clean]
type = "remap"
inputs = ["nginx_events"]
source = '''
del(._path)
del(.partition_key)
del(.path)
del(.source_type)
del(.timestamp)
'''

[sinks.kinesis]
type = "aws_kinesis_streams"
inputs = ["clean"]
region = "${region}"
stream_name = "${stream}"
encoding.codec = "json"
compression = "none"

  [sinks.kinesis.buffer]
  type = "disk"
  max_size = ${buffer_max_size}
  when_full = "block"

  [sinks.kinesis.batch]
  max_events = 500
  max_bytes = 5000000
  timeout_secs = 1
EOF
    echo "vector: single-stream mode -> ${stream}"
    return
  fi

  # ── Multi-stream routing mode ──
  # Count routes for buffer size allocation
  local num_routes=0
  local IFS=','
  for _ in $route_map; do
    num_routes=$((num_routes + 1))
  done

  local per_sink_buffer=$((buffer_max_size / num_routes))

  # Generate route transform
  printf '\n[transforms.route_by_path]\ntype = "route"\ninputs = ["nginx_events"]\n' >> "$CONFIG_FILE"

  # Each route condition (simple string format)
  IFS=','
  for entry in $route_map; do
    local path_prefix="${entry%%:*}"
    local sink_name=$(echo "$path_prefix" | tr -d '/' | tr '-' '_')
    printf 'route.%s = '\''starts_with(to_string!(._path), "%s")'\''\n' "$sink_name" "$path_prefix" >> "$CONFIG_FILE"
  done

  # Generate clean transform + kinesis sink for each route
  IFS=','
  for entry in $route_map; do
    local path_prefix="${entry%%:*}"
    local stream_name="${entry#*:}"
    local sink_name=$(echo "$path_prefix" | tr -d '/' | tr '-' '_')

    cat >> "$CONFIG_FILE" <<EOF

[transforms.clean_${sink_name}]
type = "remap"
inputs = ["route_by_path.${sink_name}"]
source = '''
del(._path)
del(.partition_key)
del(.path)
del(.source_type)
del(.timestamp)
'''

[sinks.kinesis_${sink_name}]
type = "aws_kinesis_streams"
inputs = ["clean_${sink_name}"]
region = "${region}"
stream_name = "${stream_name}"
encoding.codec = "json"
compression = "none"

  [sinks.kinesis_${sink_name}.buffer]
  type = "disk"
  max_size = ${per_sink_buffer}
  when_full = "block"

  [sinks.kinesis_${sink_name}.batch]
  max_events = 500
  max_bytes = 5000000
  timeout_secs = 1
EOF
    echo "vector: route ${path_prefix} -> ${stream_name}"
  done

  # Unmatched requests go to _unmatched — drop them
  cat >> "$CONFIG_FILE" <<'EOF'

[transforms.drop_unmatched]
type = "remap"
inputs = ["route_by_path._unmatched"]
source = 'log("unmatched path: " + to_string(._path) ?? "unknown", level: "warn"); abort'
EOF
}

# Generate config
generate_config
echo "vector: generated config:"
cat "$CONFIG_FILE"
echo ""

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
exec vector --config "$CONFIG_FILE"
