################################################################################
# Stage 1: Build GStreamer plugins written in Rust
#
# This stage uses a Rust environment to compile the custom GStreamer plugins
# from source. The only output is the compiled shared library (.so file).
################################################################################
FROM rust:slim-bullseye AS rust-builder

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
    && printf "and  uname -m : " && uname -mm \
    && printf "\n --------------------------- \n" \
    && printf "Build Image in version: ${IMG_VERSION}"

# Install build dependencies for the Rust plugin
RUN apt-get update && apt-get install -yq --no-install-recommends \
        build-essential \
        cmake \
        curl \
        jq \
        git \
        patch \
        libgstreamer-plugins-base1.0-dev \
        libgstreamer1.0-dev \
        libcsound64-dev \
        libclang-11-dev \
        libpango1.0-dev  \
        libdav1d-dev \
        # libgtk-4-dev \ Only in bookworm
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
# # - EXPERIMENTAL: For gstreamer-spotify set upgraded version number of dependency librespot to 0.4.2 
# RUN sed -i 's/librespot = { version = "0.4", default-features = false }/librespot = { version = "0.4.2", default-features = false }/g' audio/spotify/Cargo.toml

# We currently require a forked version of gstreamer-spotify plugin which supports token-based login
RUN GST_PLUGINS_RS_TAG="spotify-logging-librespot-ba3d501b" \
    && echo "Selected branch or tag for gst-plugins-rs: $GST_PLUGINS_RS_TAG" \
    # - Clone repository of gst-plugins-rs to workdir
    && git clone -c advice.detachedHead=false \
        --single-branch --depth 1 \
        --branch ${GST_PLUGINS_RS_TAG} \
        https://gitlab.freedesktop.org/kingosticks/gst-plugins-rs.git ./


# Build GStreamer plugins written in Rust
#
# Set Cargo environment variables
# Enabling cargo's sparse registry protocol is the easiest fix for 
# Error "Value too large for defined data type;" on arm/v7 and linux/386
# https://github.com/rust-lang/cargo/issues/8719
#ENV CARGO_REGISTRIES_CRATES_IO_PROTOCOL sparse
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
    && install -v -m 755 target/release/*.${SO_SUFFIX} ${DEST_DIR}/${PLUGINS_DIR} \
    && cargo clean

# ---------------------------------
#
#################################################################

################################################################################
# Stage 2: Build Iris Web UI frontend
#
# This stage uses a Node.js environment to build the static assets (JS/CSS)
# for the Iris web interface.
################################################################################
FROM node:18-slim AS frontend-builder

ARG IMG_VERSION

# Install dependencies needed for this stage
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        curl \
        jq \
        ca-certificates \
        python3 \
        python3-setuptools \
        python3-wheel \
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
    && git clone --depth 1 --single-branch -b "$IRIS_BRANCH_OR_TAG" https://github.com/jaedb/Iris.git /iris

# Now, set the working directory to the newly created /iris folder
WORKDIR /iris

# Build the frontend assets
RUN npm install && npm run prod

# This is the corrected command:
# Build a Python wheel instead of running a full installation.
# This packages the Iris python code without installing its dependencies here.
RUN python3 setup.py bdist_wheel

# Cleanup for a clean copy
RUN rm -rf node_modules .git build

################################################################################
# Stage 3: Build Python dependencies
#
# This stage installs all Python packages, including Mopidy and its extensions
# from source, into a virtual environment. This keeps build tools and dev
# libraries out of the final image.
################################################################################
FROM python:3.11-slim-bookworm AS python-builder

ARG IMG_VERSION

# Install build-time dependencies needed for Python packages.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        git \
        curl \
        jq \
        graphviz-dev \
        pkg-config \
        gobject-introspection \
        libgirepository1.0-dev \
        libglib2.0-dev \
        libffi-dev \
        libcairo2-dev \
        libasound2-dev \
        libdbus-glib-1-dev \
        meson \
        ninja-build \
    && rm -rf /var/lib/apt/lists/*

# Create and activate a virtual environment
ENV VENV_PATH=/opt/venv
RUN python3 -m venv $VENV_PATH
ENV PATH="$VENV_PATH/bin:$PATH"

# --- Install Mopidy from source ---
# # Install Mopidy from apt repository
# # see https://docs.mopidy.com/en/latest/installation/debian/
# RUN echo "Installing Mopidy from APT for release version" \
# && mkdir -p /etc/apt/keyrings \
# && wget -q -O /etc/apt/keyrings/mopidy-archive-keyring.gpg https://apt.mopidy.com/mopidy.gpg \
# && wget -q -O /etc/apt/sources.list.d/mopidy.list https://apt.mopidy.com/bookworm.list \
# && apt-get update \
# && apt-get install -y mopidy \
# && rm -rf /var/lib/apt/lists/*; \
RUN \
    # Step 1: Determine the correct branch or tag based on IMG_VERSION
    if [ "$IMG_VERSION" = "release" ]; then \
        echo "Determining latest stable release tag from GitHub..." \
        && MOPIDY_BRANCH_OR_TAG=$(curl -s https://api.github.com/repos/mopidy/mopidy/releases/latest | jq -r '.tag_name'); \
    elif [ "$IMG_VERSION" = "latest" ]; then \
        echo "Determining latest pre-release tag from GitHub..." \
        # Pre-install pygobject in a version compatible with Mopidy's pyproject.toml
        # This prevents pip from trying to install a newer, incompatible version.
        && python3 -m pip install "pygobject<=3.50.0" \
        && MOPIDY_BRANCH_OR_TAG=$(curl -s https://api.github.com/repos/mopidy/mopidy/releases | jq -r 'map(select(.draft == false)) | .[0].tag_name'); \
    elif [ "$IMG_VERSION" = "develop" ]; then \
        echo "Using main branch from GitHub..." \
        && MOPIDY_BRANCH_OR_TAG=main; \
    else \
        echo "Invalid version info for Mopidy: $IMG_VERSION" \
        && exit 1; \
    fi \
    \
    # Step 2: Install Mopidy using the determined branch or tag
    && echo "Selected branch or tag for Mopidy: $MOPIDY_BRANCH_OR_TAG" \
    && git clone --depth 1 --single-branch -b ${MOPIDY_BRANCH_OR_TAG} https://github.com/mopidy/mopidy.git /mopidy \
    && python3 -m pip install /mopidy

# --- Install Mopidy-Spotify plugin from source ---
RUN \
    if [ "$IMG_VERSION" = "release" ]; then \
        # Get latest pre-release v5.0.0a3 (last compatible version with stable mopidy release, needed for iris webui compatibility)
        MOPSPOT_BRANCH_OR_TAG="v5.0.0a3"; \
    elif [ "$IMG_VERSION" = "latest" ]; then \
        MOPSPOT_BRANCH_OR_TAG=$(curl -s https://api.github.com/repos/mopidy/mopidy-spotify/releases | jq -r 'map(select(.draft == false)) | .[0].tag_name'); \
    elif [ "$IMG_VERSION" = "develop" ]; then \
        MOPSPOT_BRANCH_OR_TAG=main; \
    else \
        echo "Invalid version info for Mopidy-Spotify: $IMG_VERSION" && exit 1; \
    fi \
    && echo "Selected branch or tag for Mopidy-Spotify: $MOPSPOT_BRANCH_OR_TAG" \
    && git clone --depth 1 --single-branch -b ${MOPSPOT_BRANCH_OR_TAG} https://github.com/mopidy/mopidy-spotify.git /mopidy-spotify \
    && python3 -m pip install /mopidy-spotify

# --- Install other Python dependencies ---
COPY requirements.txt .
RUN python3 -m pip install -r requirements.txt

# --- Install the Iris wheel that was built in frontend stage ---
COPY --from=frontend-builder /iris/dist/*.whl /tmp/
RUN python3 -m pip install /tmp/*.whl

################################################################################
# Stage 4: Final Release Image
#
# This is the final, optimized image. It only contains runtime dependencies
# and copies pre-built artifacts from the builder stages.
################################################################################
FROM debian:bookworm-slim AS release

ARG IMG_VERSION

WORKDIR /

# Install only essential runtime packages
RUN apt-get update && apt-get install -y --no-install-recommends \
        sudo \
        dumb-init \
        graphviz \
        # Python and GStreamer integration
        python3 \
        python3-gst-1.0 \
        # GStreamer runtime plugins
        gstreamer1.0-pulseaudio \
        gstreamer1.0-alsa \
        gstreamer1.0-tools \
        gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad \
        gstreamer1.0-plugins-ugly \
        gstreamer1.0-libav \
        # Audio
        pulseaudio \
    && rm -rf /var/lib/apt/lists/*

# Copy the pre-built Python virtual environment
ENV VENV_PATH=/opt/venv
COPY --from=python-builder ${VENV_PATH} ${VENV_PATH}

# Copy the pre-built GStreamer plugin
COPY --from=rust-builder /target/gst-plugins-rs/ /

# Copy the pre-built Iris frontend and its Python backend parts
COPY --from=frontend-builder /iris /iris

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

# Copy Default configuration for mopidy
COPY docker/mopidy/mopidy.example.conf /mopidy/config/mopidy.conf

# Copy the pulse-client configuration
COPY docker/mopidy/pulse-client.conf /etc/pulse/client.conf

# Set environment variables for Home and local music directory
ENV HOME=/var/lib/mopidy
ENV XDG_MUSIC_DIR=/media

# Create user, set permissions and create necessary directories
RUN set -ex \
    # Create docker user and add to required groups
    && (getent group $DOCKER_GROUP || groupadd -r $DOCKER_GROUP) \
    && useradd -r -ms /bin/bash -g $DOCKER_GROUP -d $HOME $DOCKER_USER \
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
    # Allow docker user to run system commands (restart, local scan, etc) with sudo
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