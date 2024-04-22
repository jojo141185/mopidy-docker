# --- Build Node ---
FROM rust:slim-bullseye AS Builder
LABEL org.opencontainers.image.authors="jojo141185"
LABEL org.opencontainers.image.source="https://github.com/jojo141185/mopidy-docker/"
# Automatic platform ARGs in the global scope
# This feature is only available when using the BuildKit backend.
ARG TARGETPLATFORM
ARG TARGETARCH
ARG TARGETVARIANT
# Define Image version [latest, develop, release]
ARG IMG_VERSION 

# Print Info about current build Target
RUN printf "I'm building for TARGETPLATFORM=${TARGETPLATFORM}" \
    && printf ", TARGETARCH=${TARGETARCH}" \
    && printf ", TARGETVARIANT=${TARGETVARIANT} \n" \
    && printf "With uname -s : " && uname -s \
    && printf "and  uname -m : " && uname -mm

RUN echo "Build Image in version: $IMG_VERSION"

# Switch to the root user while we do our changes
USER root

# Install all libraries and needs
RUN apt update \
    && apt install -yq --no-install-recommends \
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

# Workaround for CSound-sys to compile on ARM64
# COPY build/gst-plugins-rs/csound-sys.patch csound-sys.patch
# RUN case ${TARGETPLATFORM} in \
#         "linux/arm/v8") patch -ruN < ./csound-sys.patch ;; \
#         "linux/arm64")  patch -ruN < ./csound-sys.patch ;; \
#         *) 		 echo "No patch needed for ${TARGETPLATFORM}.";; \
#    esac

# Get source of GStreamer Plugins gst-plugins-rs
# - Select the branch or tag to use
RUN if [ "$IMG_VERSION" = "latest" ]; then \
        GST_PLUGINS_RS_TAG=main; \
    elif [ "$IMG_VERSION" = "develop" ]; then \
        GST_PLUGINS_RS_TAG=main; \
    elif [ "$IMG_VERSION" = "release" ]; then \
        GST_PLUGINS_RS_TAG=$(curl -s https://gitlab.freedesktop.org/api/v4/projects/gstreamer%2Fgst-plugins-rs/repository/tags | jq -r '.[0].name'); \
    else \
        echo "Invalid version info for gst-plugins-rs: $IMG_VERSION"; \
        exit 1; \
    fi \ 
    && echo "Selected branch or tag for gst-plugins-rs: $GST_PLUGINS_RS_TAG" \
    # - Clone repository of gst-plugins-rs to workdir
    && git clone -c advice.detachedHead=false \
	--single-branch --depth 1 \
	--branch ${GST_PLUGINS_RS_TAG} \
	https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs.git ./

# - EXPERIMENTAL: For gstreamer-spotify set upgraded version number of dependency librespot to 0.4.2 
RUN sed -i 's/librespot = { version = "0.4", default-features = false }/librespot = { version = "0.4.2", default-features = false }/g' audio/spotify/Cargo.toml

# Build GStreamer plugins written in Rust

# Set Cargo environment variables
# Enabling cargo's sparse registry protocol is the easiest fix for 
# Error "Value too large for defined data type;" on arm/v7 and linux/386
# https://github.com/rust-lang/cargo/issues/8719
#ENV CARGO_REGISTRIES_CRATES_IO_PROTOCOL sparse
ENV DEST_DIR /target/gst-plugins-rs
ENV CARGO_PROFILE_RELEASE_DEBUG false
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

# --- Release Node ---
FROM debian:bookworm-slim as Release
# Define Image version [latest, develop, release]
ARG IMG_VERSION 

# Switch to the root user while we do our changes
USER root
WORKDIR /

# Install GStreamer and other required Debian packages
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        sudo \
        build-essential \
        nodejs \
        npm \
        curl \
        jq \
        git \
        wget \
        gnupg2 \
        dumb-init \
        graphviz-dev \
        pulseaudio \
        libasound2-dev \
        libdbus-glib-1-dev \
        libgirepository1.0-dev \
        libcairo2-dev \
        pkg-config \
        # Install Python
        python3-dev \
        python3-gst-1.0 \
        python3-setuptools \
        python3-pip \
        # GStreamer (Plugins)
        gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad \
        gstreamer1.0-plugins-ugly \
        gstreamer1.0-libav \
        gstreamer1.0-pulseaudio \
    && rm -rf /var/lib/apt/lists/*

# Adjust pip configuration to ensure compatibility with Bookworm and forthcoming Debian images with this Dockerfile
# PEP 668 introduces a method for Linux distributions to inform pip about restricting package installations outside a virtual environment.
# This can be globally disabled, eliminating the need to append '--break-system-packages' to every pip command.
RUN pip3 config set global.break-system-packages true \
    && cp $HOME/.config/pip/pip.conf /etc/pip.conf

# Copy builded target data from Builder DEST_DIR to root
# Note: target directory tree links directly to $GST_PLUGIN_PATH
COPY --from=Builder /target/gst-plugins-rs/ /

# # Install Node, to build Iris JS application
# RUN curl -fsSL https://deb.nodesource.com/setup_14.x | bash - && \
#     apt-get install -y nodejs

# Install mopidy and (optional) DLNA-server dleyna from apt.mopidy.com
# see https://docs.mopidy.com/en/latest/installation/debian/
RUN mkdir -p /etc/apt/keyrings \
    && wget -q -O /etc/apt/keyrings/mopidy-archive-keyring.gpg https://apt.mopidy.com/mopidy.gpg \
    && wget -q -O /etc/apt/sources.list.d/mopidy.list https://apt.mopidy.com/bookworm.list \
    && apt-get update \
    && apt-get install -y \ 
        mopidy \
    && rm -rf /var/lib/apt/lists/*

# Clone Iris from the repository and install in development mode.
# This allows a binding at "/iris" to map to your local folder for development, rather than
# installing using pip.
# Note: ADD helps prevent RUN caching issues. When HEAD changes in repo, our cache will be invalidated!
ADD https://api.github.com/repos/jaedb/Iris/git/refs/heads/master version.json

RUN if [ "$IMG_VERSION" = "latest" ]; then \
        IRIS_BRANCH_OR_TAG=master; \
    elif [ "$IMG_VERSION" = "develop" ]; then \
        IRIS_BRANCH_OR_TAG=develop; \
    elif [ "$IMG_VERSION" = "release" ]; then \
        IRIS_BRANCH_OR_TAG=$(curl -s https://api.github.com/repos/jaedb/Iris/releases/latest | jq -r .tag_name); \
    else \
        echo "Invalid version info for Iris: $IMG_VERSION"; \
        exit 1; \
    fi \
    && echo "Selected branch or tag for iris: $IRIS_BRANCH_OR_TAG" \
    # Clone Iris to workdir and install in development mode
    && git clone --depth 1 --single-branch -b ${IRIS_BRANCH_OR_TAG} https://github.com/jaedb/Iris.git /iris \
    && cd /iris \
    && npm install \
    && npm run prod \
    && python3 setup.py develop \
    && mkdir -p /var/lib/mopidy/.config \
    && ln -s /config /var/lib/mopidy/.config/mopidy \
    # Allow mopidy user to run system commands (restart, local scan, etc)
    && echo "mopidy ALL=NOPASSWD: /iris/mopidy_iris/system.sh" >> /etc/sudoers \
    # Enable container mode (disable restart option, etc.)
    && echo "1" >> /IS_CONTAINER \
    # Copy Version file
    && cp /iris/VERSION /

# Install Mopidy-Spotify
RUN git clone --depth 1 --single-branch -b main https://github.com/mopidy/mopidy-spotify.git mopidy-spotify \
    && cd mopidy-spotify \
    && python3 -m pip install . \
    && cd .. \
    && rm -rf mopidy-spotify

# Install mopidy-radionet
RUN git clone --depth 1 --single-branch -b master https://github.com/plintx/mopidy-radionet.git mopidy-radionet \
    && cd mopidy-radionet \
    && python3 -m pip install . \
    && cd .. \
    && rm -rf mopidy-radionet

# Install additional mopidy extensions and Python dependencies via pip
COPY requirements.txt .
RUN python3 -m pip install -r requirements.txt

# Cleanup
RUN apt-get clean all \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /root/.cache \
    && rm -rf /iris/node_modules

# Start helper script.
COPY docker/entrypoint.sh /entrypoint.sh

# Copy Default configuration for mopidy
COPY docker/mopidy/mopidy.example.conf /config/mopidy.conf

# Copy the pulse-client configuratrion
COPY docker/mopidy/pulse-client.conf /etc/pulse/client.conf

# Allows any user to run mopidy, but runs by default as a randomly generated UID/GID.
# RUN useradd -ms /bin/bash mopidy
ENV HOME=/var/lib/mopidy
RUN set -ex \
    && usermod -G audio,sudo,pulse-access mopidy \
    && mkdir /var/lib/mopidy/local \
    && chown mopidy:audio -R $HOME /entrypoint.sh /iris \
    && chmod go+rwx -R $HOME /entrypoint.sh /iris

# Runs as mopidy user by default.
USER mopidy:audio

# Disable PEP 668 for user mopidy globally
# RUN pip3 config set global.break-system-packages true

VOLUME ["/var/lib/mopidy/local"]

EXPOSE 6600 6680 1704 1705 5555/udp

ENTRYPOINT ["/usr/bin/dumb-init", "/entrypoint.sh"]
CMD ["mopidy"]
