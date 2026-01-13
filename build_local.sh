#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

IMAGE_NAME="mopidy-local"

echo -e "${BLUE}=== Local Docker Build (Native) ===${NC}"

# --- AUTO-DETECT ARCHITECTURE ---
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        PLATFORM="linux/amd64"
        ;;
    aarch64|arm64)
        PLATFORM="linux/arm64"
        ;;
    armv7l)
        PLATFORM="linux/arm/v7"
        ;;
    *)
        echo -e "${YELLOW}Unknown architecture '$ARCH'. Defaulting to linux/amd64.${NC}"
        PLATFORM="linux/amd64"
        ;;
esac
echo -e "Detected System Architecture: ${GREEN}$PLATFORM${NC}"

# --- INPUTS ---

# Custom selection for version with "release" as default
echo -e "Select Image Version to build (latest, develop, ${GREEN}release${NC}):"
read -p "[Default: release]: " INPUT_VERSION

# Set default if input is empty
IMG_VERSION=${INPUT_VERSION:-release}
echo -e "Selected version: ${GREEN}$IMG_VERSION${NC}"

FULL_TAG="${IMAGE_NAME}:${IMG_VERSION}"

# --- BUILDER DETECTION ---

# We extract the active builder name and strip the '*' character if present
ACTIVE_BUILDER=$(docker buildx ls | grep '*' | awk '{print $1}' | tr -d '*')

if [ -z "$ACTIVE_BUILDER" ]; then
    echo -e "${YELLOW}No active buildx builder found. Using default docker driver.${NC}"
    BUILD_FLAGS=""
else
    # Inspect the builder to find the driver type
    BUILDER_DRIVER=$(docker buildx inspect "$ACTIVE_BUILDER" | grep "Driver:" | awk '{print $2}')
    
    if [ "$BUILDER_DRIVER" == "docker-container" ]; then
        echo -e "${YELLOW}Active builder '$ACTIVE_BUILDER' uses '$BUILDER_DRIVER' driver. Adding --load flag.${NC}"
        BUILD_FLAGS="--load"
    else
        echo -e "${GREEN}Active builder '$ACTIVE_BUILDER' uses native driver. No extra flags needed.${NC}"
        BUILD_FLAGS=""
    fi
fi

# --- BUILD ---

echo -e "${BLUE}Building $FULL_TAG ...${NC}"

# Using buildx build with conditional flags to ensure visibility in 'docker images'
docker buildx build \
    --platform "$PLATFORM" \
    --build-arg IMG_VERSION="$IMG_VERSION" \
    -t "$FULL_TAG" \
    $BUILD_FLAGS \
    .

echo -e "${GREEN}✓ Build successful!${NC}"
echo "Image available as: $FULL_TAG"

# --- IMAGE DETAILS ---

echo -e "${BLUE}--- Image Details ---${NC}"
# We use the full tag as reference to get exactly one result
docker images --filter "reference=$FULL_TAG" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.ID}}"

echo ""

# --- TEST RUN ---

echo ""
# Default is [N/y] which means Enter = No
read -p "Do you want to run this image strictly locally (docker run)? [N/y]: " RUN_REPLY

# Only run if user explicitly enters 'y' or 'Y'
if [[ "$RUN_REPLY" =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}Starting container on port 6680...${NC}"
    echo "Press Ctrl+C to stop."
    
    docker run --rm -it \
        -p 6680:6680 \
        -p 6600:6600 \
        --name mopidy_local_test \
        "$FULL_TAG"
else
    echo -e "${YELLOW}Test run skipped.${NC}"
fi