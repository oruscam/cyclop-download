#!/bin/bash

set -euo pipefail

# ── Detect real user ────────────────────────────────────────────────
REAL_USER="${SUDO_USER:-$(whoami)}"
if [[ "$REAL_USER" == "root" ]]; then
    # If run as root directly and SUDO_USER is empty, fallback to getent
    REAL_USER=$(logname 2>/dev/null || echo "root")
fi
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
CYCLOP_PATH="${CYCLOPS_HOME:-$REAL_HOME/cyclop}"
TEMP_DIR="/tmp/cyclop_download"
API_URL="https://api.dataview.orus.cam/"

echo "=== Cyclop Downloader ==="
echo "Target directory: $CYCLOP_PATH"
echo ""

# Ask for Basic Auth credentials
if [[ -z "${AUTH_USER:-}" ]]; then
    read -r -p "Enter Username: " AUTH_USER
    if [[ -z "$AUTH_USER" ]]; then
        echo "Error: Username cannot be empty"
        exit 1
    fi
fi

if [[ -z "${AUTH_PASS:-}" ]]; then
    read -r -s -p "Enter Password: " AUTH_PASS
    echo
    if [[ -z "$AUTH_PASS" ]]; then
        echo "Error: Password cannot be empty"
        exit 1
    fi
fi

# Ensure required commands are available and install them if missing
for cmd in curl jq tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Command '$cmd' is not installed. Installing..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update && sudo apt-get install -y "$cmd"
        else
            echo "Error: apt-get not found. Please install $cmd manually."
            exit 1
        fi
    fi
done

# The firmware routes take a JWT, so the credentials entered above are first
# exchanged for an access token. The trailing slash on the token path matters:
# with APPEND_SLASH Django cannot redirect a POST and answers 500 instead.
echo "Authenticating..."
TOKEN_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg u "$AUTH_USER" --arg p "$AUTH_PASS" \
          '{username: $u, password: $p}')" \
    "${API_URL}api/token/")

HTTP_CODE=$(echo "$TOKEN_RESPONSE" | tail -n1)
BODY=$(echo "$TOKEN_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
    echo "Error: Authentication failed (HTTP $HTTP_CODE)"
    echo "Response: $BODY"
    exit 1
fi

JWT=$(echo "$BODY" | jq -r '.access // empty')
if [ -z "$JWT" ]; then
    echo "Error: the token response carried no access token"
    exit 1
fi

echo "Fetching latest version information..."
API_ENDPOINT="${API_URL}api/v1/firmware/new_version/"
RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer $JWT" \
    "$API_ENDPOINT")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
    echo "Error: Failed to fetch version info (HTTP $HTTP_CODE)"
    echo "Response: $BODY"
    exit 1
fi

VERSION=$(echo "$BODY" | jq -r '.version')
PRESIGNED_URL=$(echo "$BODY" | jq -r '.url_presign')

if [ -z "$VERSION" ] || [ "$VERSION" = "null" ] || [ -z "$PRESIGNED_URL" ] || [ "$PRESIGNED_URL" = "null" ]; then
    echo "Error: Invalid response from server"
    exit 1
fi

echo "Latest version found: $VERSION"

mkdir -p "$TEMP_DIR"

echo "Downloading version $VERSION from S3..."
if ! curl -# -o "$TEMP_DIR/cyclop.tar.gz" "$PRESIGNED_URL"; then
    echo "Error: Failed to download archive"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "Extracting archive..."
cd "$TEMP_DIR"
if ! tar -xzf cyclop.tar.gz; then
    echo "Error: Failed to extract archive"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "Placing files in $CYCLOP_PATH..."
if [ ! -d "$CYCLOP_PATH" ]; then
    mkdir -p "$CYCLOP_PATH"
fi

# Move files into the target directory
if command -v rsync >/dev/null 2>&1; then
    rsync -a "$TEMP_DIR/cyclop/" "$CYCLOP_PATH/"
else
    cp -R "$TEMP_DIR/cyclop/"* "$CYCLOP_PATH/"
    cp -R "$TEMP_DIR/cyclop/".[!.]* "$CYCLOP_PATH/" 2>/dev/null || true
fi

# Save the version downloaded
echo "$VERSION" > "$CYCLOP_PATH/version.txt"

echo "Cleaning up..."
rm -rf "$TEMP_DIR"

echo "Download complete! Cyclop is now located at $CYCLOP_PATH."
echo "To continue with the installation, run:"
echo "  cd $CYCLOP_PATH"
echo "  bash install.sh"
