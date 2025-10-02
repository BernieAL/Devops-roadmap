#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="${1:-}"
if [[ -z "${SRC_DIR}" ]]; then
  read -r -p "Enter the Dir you want to compress: " SRC_DIR
fi
SRC_DIR="${SRC_DIR%/}"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "Error: '$SRC_DIR' is not a directory" >&2
  exit 1
fi

DATE="$(date +%F)"
DEST_PARENT="${HOME}/archives"
mkdir -p "$DEST_PARENT"

BASENAME="$(basename "$SRC_DIR")"
ARCHIVE="${DEST_PARENT}/${BASENAME}_${DATE}.tar.gz"

TAR="tar"
[[ "$SRC_DIR" == /var/* || "$SRC_DIR" == /etc/* || "$SRC_DIR" == /root/* ]] && TAR="sudo tar"

# Archive the contents (no parent folder)
$TAR -czf "$ARCHIVE" -C "$SRC_DIR" . --ignore-failed-read
# If you prefer archiving the folder itself, use this instead:
# $TAR -czf "$ARCHIVE" -C "$(dirname "$SRC_DIR")" "$BASENAME" --ignore-failed-read

echo "Archive created at: $ARCHIVE"
