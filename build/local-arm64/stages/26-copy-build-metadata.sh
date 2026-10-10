#!/usr/bin/env bash
# Original workflow step: Copy build metadata
# REVIEW REQUIRED: not yet adapted for local execution.

RELEASE_DIR="$TARGET_DIR/release-v1.2"

for file in \
  config.buildinfo \
  feeds.buildinfo \
  version.buildinfo \
  profiles.json; do

  if [ -f "$TARGET_DIR/$file" ]; then
    cp \
      "$TARGET_DIR/$file" \
      "$RELEASE_DIR/"

fi
done

find \
  "$TARGET_DIR" \
  -maxdepth 1 \
  -type f \
  -name '*friendlyarm_nanopi-r76s*.manifest' \
  -exec cp {} "$RELEASE_DIR/" \; \
  || true
