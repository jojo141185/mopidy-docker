################################################################################
# Stage 1: Build GStreamer plugins written in Rust
#
# This stage uses a Rust environment to compile the custom GStreamer plugins.
################################################################################
FROM rust:slim-bookworm AS rust-builder

LABEL org.opencontainers.image.authors="jojo141185"
LABEL org.opencontainers.image.source="https://github.com/jojo141185/mopidy-docker/"

# Automatic platform ARGs for BuildKit
# This feature is only available when using the BuildKit backend.
ARG TARGETPLATFORM
ARG TARGETARCH
ARG TARGETVARIANT
# Define Image version [latest, develop, release]
ARG IMG_VERSION

# Print Info about current build
RUN printf "I'm building for TARGETPLATFORM=${TARGETPLATFORM}" \
    && printf ", TARGETARCH=${TARGETARCH}" \
    && printf ", TARGETVARIANT=${TARGETVARIANT} \n" \
    && printf "With uname -s : " && uname -s \
    && printf "and  uname -m : " && uname -m \
    && printf "\n --------------------------- \n" \
    && printf "Build Image in version: ${IMG_VERSION}"

# Install build dependencies for the Rust plugin
# Added 'binutils' to provide the 'strip' command for size optimization
RUN apt-get update && apt-get install -yq --no-install-recommends \
        build-essential \
        cmake \
        curl \
        jq \
        git \
        patch \
        binutils \
        libgstreamer-plugins-base1.0-dev \
        libgstreamer1.0-dev \
        libcsound64-dev \
        libclang-dev \
        libpango1.0-dev  \
        libdav1d-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/gst-plugins-rs

# ---------------------------------
# ---  GStreamer Plugins        ---
#
# Get source of gst-plugins-rs
#
# # - Select the branch or tag to use
# RUN if [ "$IMG_VERSION" = "latest" ]; then \
#         GST_PLUGINS_RS_TAG=main; \
#     elif [ "$IMG_VERSION" = "develop" ]; then \
#         GST_PLUGINS_RS_TAG=main; \
#     elif [ "$IMG_VERSION" = "release" ]; then \
#         GST_PLUGINS_RS_TAG=$(curl -s https://gitlab.freedesktop.org/api/v4/projects/gstreamer%2Fgst-plugins-rs/repository/tags | jq -r '.[0].name'); \
#     else \
#         echo "Invalid version info for gst-plugins-rs: $IMG_VERSION"; \
#         exit 1; \
#     fi \ 
#     && echo "Selected branch or tag for gst-plugins-rs: $GST_PLUGINS_RS_TAG" \
#     # - Clone repository of gst-plugins-rs to workdir
#     && git clone -c advice.detachedHead=false \
# 	--single-branch --depth 1 \
# 	--branch ${GST_PLUGINS_RS_TAG} \
# 	https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs.git ./
#

# Use forked version of gstreamer-spotify plugin from Nick Steel with better logging support. Using specific commit hash 3aab0473
# Waiting for https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs/-/merge_requests/1877 to be merged.
RUN GST_PLUGINS_RS_TAG="3aab0473" \
    && echo "Selected commit hash for gst-plugins-rs: $GST_PLUGINS_RS_TAG" \
    # - Clone repository of gst-plugins-rs to workdir
    # Note: We clone the branch first, then checkout the specific hash to be safe
    && git clone -c advice.detachedHead=false \
        --single-branch \
        --branch spotify-logging \
        https://gitlab.freedesktop.org/kingosticks/gst-plugins-rs.git ./ \
    && git checkout "$GST_PLUGINS_RS_TAG"


# Build GStreamer plugins written in Rust
#
# Set Cargo environment variables
ENV DEST_DIR="/target/gst-plugins-rs"
ENV CARGO_PROFILE_RELEASE_DEBUG="false"
# Cargo Build, with options:
# --release: do a release (not dev) build
# --no-default-features: disables the default features of the package (optional)
# --config net.git-fetch-with-cli=true: Uses command-line git instead of  built-in libgit2 to fix OOM Problem (exit code: 137) 
RUN export CSOUND_LIB_DIR="/usr/lib/$(uname -m)-linux-gnu" \
    && export PLUGINS_DIR=$(pkg-config --variable=pluginsdir gstreamer-1.0) \
    && export SO_SUFFIX=so \
    && cargo build --release --no-default-features --config net.git-fetch-with-cli=true \
        # List of packages to build
        --package gst-plugin-spotify \
    # Use install command to create directory (-d), copy and print filenames (-v), and set attributes/permissions (-m)
    && install -v -d ${DEST_DIR}/${PLUGINS_DIR} \
    # OPTIMIZATION: Strip debug symbols from the library to significantly reduce size
    && strip --strip-all target/release/*.${SO_SUFFIX} \
    && install -v -m 755 target/release/*.${SO_SUFFIX} ${DEST_DIR}/${PLUGINS_DIR} \
    && cargo clean

# ---------------------------------
#
#################################################################

################################################################################
# Stage 2: Build Iris Web UI frontend
#
# This stage only builds the static assets (JS/CSS) for the Iris web interface.
################################################################################
FROM node:18-slim AS frontend-builder

ARG IMG_VERSION

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl jq ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# --- Install Iris WebUI from source ---

# ADD a remote file to act as a cache invalidator. Its content is not important,
# but if the remote file changes, this layer's cache will break.
# We place it in /tmp so it doesn't interfere with the git clone command.
ADD https://api.github.com/repos/jaedb/Iris/git/refs/heads/master /tmp/version.json

# Clone the Iris repository into a new directory named /iris
RUN \
    # Step 1: Determine the correct branch or tag based on IMG_VERSION
    if [ "$IMG_VERSION" = "latest" ]; then \
        IRIS_BRANCH_OR_TAG=master; \
    elif [ "$IMG_VERSION" = "develop" ]; then \
        IRIS_BRANCH_OR_TAG=develop; \
    elif [ "$IMG_VERSION" = "release" ]; then \
        IRIS_BRANCH_OR_TAG=$(curl -s https://api.github.com/repos/jaedb/Iris/releases/latest | jq -r .tag_name); \
    else \
        echo "Invalid version info for Iris: $IMG_VERSION"; \
        exit 1; \
    fi \
    && echo "Selected branch or tag for Iris: $IRIS_BRANCH_OR_TAG" \
    # Step 2: Clone Iris into a new directory /iris
    && git clone --depth 1 --single-branch -b "$IRIS_BRANCH_OR_TAG" https://github.com/jaedb/Iris.git /iris;

# Now, set the working directory to the newly created /iris folder
WORKDIR /iris

# Build the frontend assets and then remove build dependencies
RUN npm install && npm run prod && rm -rf node_modules

################################################################################
# Stage 3: Build Python wheels
#
# This stage acts as a "wheel factory". It downloads and builds all Python
# packages and their dependencies into a single folder of .whl files.
# CHANGED: Switched to debian:trixie-slim (Testing) to provide Python >=3.13
# and newer system libraries required by Mopidy 4.0 alpha.
################################################################################
FROM debian:trixie-slim AS python-builder

ARG IMG_VERSION

# Install build-time dependencies needed for Python packages.
# We include python3-full to ensure venv and all stdlibs are available.
# We also include development headers (libgirepository1.0-dev AND 2.0-dev) to allow
# building PyGObject >= 3.50.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        git \
        curl \
        jq \
        python3-full \
        python3-pip \
        python3-dev \
        graphviz-dev \
        pkg-config \
        gobject-introspection \
        libgirepository1.0-dev \
        libgirepository-2.0-dev \
        libglib2.0-dev \
        libffi-dev \
        libcairo2-dev \
        libasound2-dev \
        libdbus-glib-1-dev \
        meson \
        ninja-build \
    && rm -rf /var/lib/apt/lists/*

# Create a directory to store all our wheels
WORKDIR /wheels

# --- Collect all Python sources ---

# --- Mopidy source ---
RUN \
    # Step 1: Determine the correct branch or tag based on IMG_VERSION
    if [ "$IMG_VERSION" = "release" ]; then \
        echo "Determining latest stable release tag from GitHub..." \
        && MOPIDY_BRANCH_OR_TAG=$(curl -s https://api.github.com/repos/mopidy/mopidy/releases/latest | jq -r '.tag_name'); \
    elif [ "$IMG_VERSION" = "latest" ]; then \
        echo "Determining latest pre-release tag from GitHub..." \
        && MOPIDY_BRANCH_OR_TAG=$(curl -s https://api.github.com/repos/mopidy/mopidy/releases | jq -r 'map(select(.draft == false)) | .[0].tag_name'); \
    elif [ "$IMG_VERSION" = "develop" ]; then \
        MOPIDY_BRANCH_OR_TAG=main; \
    else \
        echo "Invalid version info for Mopidy: $IMG_VERSION" && exit 1; \
    fi \
    && echo "Cloning Mopidy tag: $MOPIDY_BRANCH_OR_TAG" \
    && git clone --single-branch -b ${MOPIDY_BRANCH_OR_TAG} https://github.com/mopidy/mopidy.git /src/mopidy \
    && if [ "$IMG_VERSION" = "release" ]; then \
        # -------------------------------------------------------------------------
        # FIX: GStreamer 1.24+ Compatibility Patch (Manual Sed for v3.4.2)
        #
        # Mopidy v3.4.2 uses older code than the 'develop' branch.
        # Issue: GStreamer 1.24+ returns a StructureWrapper which lacks .get_name()
        # and .to_string().
        # Fix: We use Python's builtin str() function to convert the object to string,
        # then split at the comma to get the MIME type.
        # -------------------------------------------------------------
        echo "Applying Patch for GStreamer 1.24 compatibility (Manual Sed)..." \
        # Fix 1: Line ~224 in v3.4.2 audio/scan.py
        # Replaces: mime = msg.get_structure().get_value("caps").get_name()
        # With:     mime = str(msg.get_structure().get_value("caps")).split(",")[0]
        && sed -i 's/mime = msg.get_structure().get_value("caps").get_name()/mime = str(msg.get_structure().get_value("caps")).split(",")[0]/' /src/mopidy/mopidy/audio/scan.py \
        # Fix 2: Line ~233 in v3.4.2 audio/scan.py (inside error handling)
        # Replaces: mime = caps.get_structure(0).get_name()
        # With:     mime = str(caps.get_structure(0)).split(",")[0]
        && sed -i 's/mime = caps.get_structure(0).get_name()/mime = str(caps.get_structure(0)).split(",")[0]/' /src/mopidy/mopidy/audio/scan.py; \
        # -------------------------------------------------------------
        # FIX END
        # -------------------------------------------------------------------------
    fi \
    && cd /wheels

# --- Mopidy-Spotify source ---
RUN \
    if [ "$IMG_VERSION" = "release" ]; then \
        MOPSPOT_BRANCH_OR_TAG="v5.0.0a3"; \
    elif [ "$IMG_VERSION" = "latest" ]; then \
        echo "Determining latest pre-release tag from GitHub..." \
        && MOPSPOT_BRANCH_OR_TAG=$(curl -s https://api.github.com/repos/mopidy/mopidy-spotify/releases | jq -r 'map(select(.draft == false)) | .[0].tag_name'); \
    elif [ "$IMG_VERSION" = "develop" ]; then \
        MOPSPOT_BRANCH_OR_TAG=main; \
    else \
        echo "Invalid version info for Mopidy-Spotify: $IMG_VERSION" && exit 1; \
    fi \
    && echo "Cloning Mopidy-Spotify tag: $MOPSPOT_BRANCH_OR_TAG" \
    && git clone --single-branch -b ${MOPSPOT_BRANCH_OR_TAG} https://github.com/mopidy/mopidy-spotify.git /src/mopidy-spotify

# --- Iris source ---
COPY --from=frontend-builder /iris /src/iris

# --- Other Python dependencies source ---
COPY requirements.txt /src/requirements.txt

# --- Build wheels ---
RUN \
    MOPIDY_SOURCE="/src/mopidy" \
    # CHANGED: Cleared constraints. 
    # Mopidy 4 needs PyGObject >= 3.50. Trixie provides the environment to build this.
    # We let pip resolve the best version automatically.
    && echo "" > /src/constraints.txt \
    # --- Build ALL packages and dependencies as wheels in a single step ---
    # We use 'pip wheel' to build .whl files from the local source directories.
    && python3 -m pip wheel \
        --no-cache-dir \
        --wheel-dir=/wheels \
        --constraint /src/constraints.txt \
        --requirement /src/requirements.txt \
        PyGObject \
        $MOPIDY_SOURCE \
        /src/mopidy-spotify \
        /src/iris

################################################################################
# Stage 4: Final Release Image
#
# CRITICAL CHANGE: Switched to debian:trixie-slim (Testing).
# This provides the Python version (3.13+) required by Mopidy 4.0.
################################################################################
FROM debian:trixie-slim AS release

ARG IMG_VERSION
WORKDIR /

# Install only essential runtime packages
# OPTIMIZATION: 
# 1. Removed 'python3-full' which includes many unnecessary components (GUI libs, tests).
#    Replaced with 'python3', 'python3-venv', 'python3-pip'.
# 2. Removed build/dev tools like 'git' or 'graphviz'.
RUN apt-get update && apt-get install -y --no-install-recommends \
        sudo \
        dumb-init \
        # Python Components
        python3 \
        python3-venv \
        python3-pip \
        # Python GObject bindings (crucial)
        python3-gi \
        python3-gst-1.0 \
        python3-cairo \
        # GStreamer Core & Plugins
        gir1.2-glib-2.0 \
        gir1.2-gstreamer-1.0 \
        gir1.2-gst-plugins-base-1.0 \
        gir1.2-gst-plugins-bad-1.0 \
        gstreamer1.0-pulseaudio \
        gstreamer1.0-alsa \
        gstreamer1.0-tools \
        gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad \
        gstreamer1.0-plugins-ugly \
        gstreamer1.0-libav \
        pulseaudio \
        # Add git to install Mopidy extensions from repositories if needed
        git \
    && rm -rf /var/lib/apt/lists/*

# --- Create a portable venv and install packages from local wheels ---
ENV VENV_PATH=/opt/venv
# 1. Create a fresh venv IN the final image.
# We use --system-site-packages so that if the system provides a recent enough
# PyGObject, we can use it.
RUN python3 -m venv --system-site-packages ${VENV_PATH}

# 2. Copy the pre-built wheels from our "wheel factory"
COPY --from=python-builder /wheels /wheels
COPY --from=python-builder /src/requirements.txt /wheels/requirements.txt

# 3. Install ALL required packages from the local wheels folder.
RUN ${VENV_PATH}/bin/pip install --no-index --find-links=/wheels \
    -r /wheels/requirements.txt \
    mopidy \
    mopidy-spotify \
    mopidy-iris \
    # OPTIMIZATION: Clean up artifacts immediately to save space
    && rm -rf /wheels \
    && rm -rf /root/.cache/pip

# Copy the pre-built GStreamer plugin
COPY --from=rust-builder /target/gst-plugins-rs/ /

# Copy the Iris directory which contains the static web assets
COPY --from=frontend-builder /iris /iris

# OPTIMIZATION: Remove compiled python cache files to reduce image size
RUN find ${VENV_PATH} -type d -name "__pycache__" -exec rm -rf {} +

# Set the PATH to use the virtual environment
ENV PATH="${VENV_PATH}/bin:$PATH"

# --- Final Setup and Configuration ---

# Enable container mode for Iris and copy version file
RUN echo "1" >> /iris/IS_CONTAINER \
    && cp /iris/VERSION /

# Define user and group to run mopidy
ENV DOCKER_USER=mopidy
ENV DOCKER_GROUP=audio

# Start helper script.
COPY docker/entrypoint.sh /entrypoint.sh
COPY docker/mopidy/mopidy.example.conf /mopidy/config/mopidy.conf
COPY docker/mopidy/pulse-client.conf /etc/pulse/client.conf

# Set environment variables for Home and local music directory
ENV HOME=/var/lib/mopidy
ENV XDG_MUSIC_DIR=/media

# Create user, set permissions and create necessary directories
RUN set -ex \
    # Create the group only if it does not already exist
    && (getent group $DOCKER_GROUP || groupadd -r $DOCKER_GROUP) \
    # Create the user
    && useradd -r -ms /bin/bash -g $DOCKER_GROUP -d $HOME $DOCKER_USER \
    # Add user to supplementary groups
    && usermod -aG audio,sudo,pulse-access $DOCKER_USER \
    # Create volume mount points so we can set permissions on them
    && mkdir -p /config /media "$HOME/local" \
    # Create mopidy config directory and symlink it
    && mkdir -p "$HOME/.config" \
    && ln -s /config "$HOME/.config/mopidy" \
    # Create local music directory
    && mkdir -p "$HOME/local" \
    # Add XDG_MUSIC_DIR to user-dirs to make it available for user
    && echo "XDG_MUSIC_DIR=\"$XDG_MUSIC_DIR\"" >> "$HOME/.config/user-dirs.dirs" \
    # Allow docker user to run system commands with sudo
    && echo "$DOCKER_USER ALL=NOPASSWD: /iris/mopidy_iris/system.sh" >> /etc/sudoers \
    # Configure sudo to keep XDG_MUSIC_DIR
    && echo "Defaults env_keep += \"XDG_MUSIC_DIR\"" >> /etc/sudoers \
    # Set ownership and permissions
    && chmod +x /entrypoint.sh \
    && chown -R $DOCKER_USER:$DOCKER_GROUP $HOME /config /media \
    # Set permissions that allows any user to run mopidy
    && chmod go+rwx -R /iris /VERSION

# Switch to the non-root user
USER $DOCKER_USER:$DOCKER_GROUP

# Define volumes
VOLUME ["/config", "/var/lib/mopidy/local", "/media"]

# Port-List to expose:
# 6600 - (optional) Exposes MPD server (if you use for example ncmpcpp client).
# 6680 - (optional) Exposes HTTP server (if you use your browser as client).
# 5555/udp - (optional) Exposes UDP streaming for FIFE sink (e.g. for visualizers).
EXPOSE 6600 6680 5555/udp

# Set the entrypoint to use dumb-init for proper signal handling
ENTRYPOINT ["/usr/bin/dumb-init", "/entrypoint.sh"]
CMD ["/opt/venv/bin/mopidy"]

#
#################################################################