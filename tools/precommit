#!/bin/bash

# Pre-commit hook to increment version number in build.zig.zon
# Increments the dev version number (e.g., dev.10 -> dev.11)

BUILD_ZON_FILE="build.zig.zon"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ZON_PATH="$PROJECT_ROOT/$BUILD_ZON_FILE"

# Check if file exists
if [ ! -f "$BUILD_ZON_PATH" ]; then
    echo "Error: $BUILD_ZON_FILE not found at $BUILD_ZON_PATH"
    exit 1
fi

# Extract current version
CURRENT_VERSION=$(grep -E '^\s*\.version\s*=' "$BUILD_ZON_PATH" | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "$CURRENT_VERSION" ]; then
    echo "Error: Could not find version in $BUILD_ZON_FILE"
    exit 1
fi

# Extract the dev number (e.g., extract 10 from "0.0.1-dev.10")
DEV_NUMBER=$(echo "$CURRENT_VERSION" | grep -oE 'dev\.([0-9]+)' | grep -oE '[0-9]+')

if [ -z "$DEV_NUMBER" ]; then
    echo "Error: Could not extract dev number from version: $CURRENT_VERSION"
    exit 1
fi

# Increment the dev number
NEW_DEV_NUMBER=$((DEV_NUMBER + 1))

# Create new version string (replace dev.XX with dev.NEW_NUMBER)
NEW_VERSION=$(echo "$CURRENT_VERSION" | sed -E "s/dev\.$DEV_NUMBER/dev.$NEW_DEV_NUMBER/")

# Update the file - replace the version string directly
# Escape dots in NEW_VERSION for sed
ESCAPED_NEW_VERSION=$(echo "$NEW_VERSION" | sed 's/\./\\./g')
ESCAPED_CURRENT_VERSION=$(echo "$CURRENT_VERSION" | sed 's/\./\\./g')
sed -i.bak "s/$ESCAPED_CURRENT_VERSION/$ESCAPED_NEW_VERSION/" "$BUILD_ZON_PATH"

# Remove backup file (created by sed -i.bak)
rm -f "$BUILD_ZON_PATH.bak"

echo "Version incremented: $CURRENT_VERSION -> $NEW_VERSION"
echo "Updated $BUILD_ZON_FILE"

# Stage the updated file for commit
git add "$BUILD_ZON_PATH"

exit 0

