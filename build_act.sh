#!/bin/bash
set -e

# --- CONFIGURATION ---
WORKFLOW_FILE=".github/workflows/build-docker.yml"
EVENT_FILE="event.json"
SECRET_FILE=".secrets"
# Directory to store artifacts (like digests) locally if needed
ARTIFACT_DIR="/tmp/act-artifacts"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Mopidy CI Simulation (via act) ===${NC}"

# --- PREREQUISITES ---

if ! command -v act &> /dev/null; then
    echo -e "${RED}Error: 'act' is not installed.${NC}"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: 'jq' is not installed (required for JSON generation).${NC}"
    exit 1
fi

if [ ! -f "$SECRET_FILE" ]; then
    echo -e "${RED}Error: '$SECRET_FILE' not found.${NC}"
    echo "Please create it with DOCKERHUB_USERNAME, DOCKERHUB_TOKEN, and GITHUB_TOKEN."
    exit 1
fi

# --- INPUTS ---

echo -e "${YELLOW}--- Configure Workflow Inputs ---${NC}"

# Image Version
echo "Select Image Version:"
select IMG_VERSION in "latest" "develop" "release" "all"; do
    [ -n "$IMG_VERSION" ] && break
done

# Platform
echo "Select Platform:"
select PLATFORM in "linux/amd64" "linux/arm64" "linux/arm/v7" "all"; do
    [ -n "$PLATFORM" ] && break
done

# Log Level
LOG_LEVEL="info"
read -p "Enable Debug Logging? [y/N]: " DEBUG_REPLY
if [[ "$DEBUG_REPLY" =~ ^[Yy]$ ]]; then
    LOG_LEVEL="debug"
fi

# --- GENERATE EVENT JSON ---

echo -e "${BLUE}Generating $EVENT_FILE...${NC}"

jq -n \
    --arg log "$LOG_LEVEL" \
    --arg img "$IMG_VERSION" \
    --arg plat "$PLATFORM" \
    '{
        inputs: {
            logLevel: $log,
            image: $img,
            platform: $plat
        }
    }' > "$EVENT_FILE"

# --- RUN ACT ---

echo -e "${BLUE}>> Starting act...${NC}"
echo "Note: This will perform logins and PUSH images if the workflow succeeds!"

# We use --container-daemon-socket to ensure Docker-in-Docker works.
# We mount the secrets file.
act workflow_dispatch \
    -W "$WORKFLOW_FILE" \
    --container-daemon-socket /var/run/docker.sock \
    --secret-file "$SECRET_FILE" \
    --artifact-server-path "$ARTIFACT_DIR" \
    -e "$EVENT_FILE" \
    --rm

echo -e "${GREEN}Act finished.${NC}"
rm -f "$EVENT_FILE"