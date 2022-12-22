# --- Build Node ---
FROM rust:slim-bullseye AS Builder
LABEL org.opencontainers.image.authors="https://github.com/seppi91"
ARG TARGETPLATFORM
ARG TARGETARCH
ARG TARGETVARIANT

# Print Info about current build Target
RUN printf "I'm building for TARGETPLATFORM=${TARGETPLATFORM}" \
    && printf ", TARGETARCH=${TARGETARCH}" \
    && printf ", TARGETVARIANT=${TARGETVARIANT} \n" \
    && printf "With uname -s : " && uname -s \
    && printf "and  uname -m : " && uname -mm

# Switch to the root user while we do our changes
USER root

# Install all libraries and needs
RUN apt update \
    && apt install -yq --no-install-recommends \
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
#COPY build/gst-plugins-rs/csound-sys.patch csound-sys.patch
#RUN case ${TARGETPLATFORM} in \
#         "linux/arm/v8") patch -ruN < ./csound-sys.patch ;; \
#         "linux/arm64")  patch -ruN < ./csound-sys.patch ;; \
#         *) 		 echo "No patch needed for ${TARGETPLATFORM}.";; \
#    esac

# Clone source of gst-plugins-rs to workdir
ARG GST_PLUGINS_RS_TAG=main
RUN git clone -c advice.detachedHead=false \
	--single-branch --depth 1 \
	--branch ${GST_PLUGINS_RS_TAG} \
	https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs.git ./
# EXPERIMENTAL: For gstreamer-spotify set upgraded version number of dependency librespot to 0.4.2 
RUN sed -i 's/librespot = { version = "0.4", default-features = false }/librespot = { version = "0.4.2", default-features = false }/g' audio/spotify/Cargo.toml

# Build GStreamer plugins written in Rust (optional with --no-default-features)
ENV DEST_DIR /target/gst-plugins-rs
ENV CARGO_PROFILE_RELEASE_DEBUG false
RUN export CSOUND_LIB_DIR="/usr/lib/$(uname -m)-linux-gnu" \
 && export PLUGINS_DIR=$(pkg-config --variable=pluginsdir gstreamer-1.0) \
 && export SO_SUFFIX=so \
 && cargo build --release --no-default-features \
 # List of packages to build
    --package gst-plugin-spotify \
 # Use install command to create directory (-d), copy and print filenames (-v), and set attributes/permissions (-m)
 && install -v -d ${DEST_DIR}/${PLUGINS_DIR} \
 && install -v -m 755 target/release/*.${SO_SUFFIX} ${DEST_DIR}/${PLUGINS_DIR}


# --- Release Node ---
FROM debian:bullseye-slim as Release

# Switch to the root user while we do our changes
USER root
WORKDIR /

# Install GStreamer and other required Debian packages
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    sudo \
    wget \
    gnupg2 \
    git \
    python3-setuptools \
    python3-pip \
    dumb-init \
    graphviz-dev \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-pulseaudio \
    libasound2-dev \
    python3-dev \
    python3-gst-1.0 \
    build-essential \
    libdbus-glib-1-dev \
    libgirepository1.0-dev \
  && rm -rf /var/lib/apt/lists/*

# Copy builded target data from Builder DEST_DIR to root
# Note: target directory tree links directly to $GST_PLUGIN_PATH
COPY --from=Builder /target/gst-plugins-rs/ /
# Place or link plugin library to any $GST_PLUGIN_PATH library
#RUN MULTIARCHTUPLE=$(dpkg-architecture -qDEB_HOST_MULTIARCH) \
# && cp ./target/release/libgstspotify.so /usr/lib/$MULTIARCHTUPLE/gstreamer-1.0/
# #&& ln -s /usr/lib/$MULTIARCHTUPLE/gstreamer-1.0/libgstspotify.so /usr/lib64/$MULTIARCHTUPLE/gstreamer-1.0/libgstspotify.so || true \
#RUN rm -rf target

# Install mopidy and (optional) DLNA-server dleyna from apt.mopidy.com
# see https://docs.mopidy.com/en/latest/installation/debian/
RUN mkdir -p /usr/local/share/keyrings \
 && wget -q -O /usr/local/share/keyrings/mopidy-archive-keyring.gpg https://apt.mopidy.com/mopidy.gpg \
 && wget -q -O /etc/apt/sources.list.d/mopidy.list https://apt.mopidy.com/buster.list \
 && apt-get update \
 && apt-get install -y \ 
 	mopidy \
	mopidy-dleyna \
 && rm -rf /var/lib/apt/lists/*

# Upgrade Python package manager pip
# https://pypi.org/project/pip/
RUN python3 -m pip install --upgrade pip

# Clone Iris from the repository and install in development mode.
# This allows a binding at "/iris" to map to your local folder for development, rather than
# installing using pip.
# Note: ADD helps prevent RUN caching issues. When HEAD changes in repo, our cache will be invalidated!
ADD https://api.github.com/repos/jaedb/Iris/git/refs/heads/master version.json
ENV IRIS_VERSION=3.64.0
RUN git clone --depth 1 --single-branch -b ${IRIS_VERSION} https://github.com/jaedb/Iris.git /iris \
 && cd /iris \
 && python3 setup.py develop \
 && mkdir -p /var/lib/mopidy/.config \
 && ln -s /config /var/lib/mopidy/.config/mopidy \
 # Allow mopidy user to run system commands (restart, local scan, etc)
 && echo "mopidy ALL=NOPASSWD: /iris/mopidy_iris/system.sh" >> /etc/sudoers

# Install minimal set of pip packages for mopidy 
RUN python3 -m pip install --no-cache \
    tox \
    mopidy-mpd \
    mopidy-local

# Install mopidy-spotify-gstspotify (Hack, not released yet!)
# (https://github.com/kingosticks/mopidy-spotify/tree/gstspotifysrc-hack)
RUN git clone --depth 1 -b gstspotifysrc-hack https://github.com/kingosticks/mopidy-spotify.git mopidy-spotify \
 && cd mopidy-spotify \
 && python3 setup.py install \
 && cd .. \
 && rm -rf mopidy-spotify

# Install mopidy-radionet (PR API-Fixed)
# (https://github.com/plintx/mopidy-radionet/pull/18)
RUN git clone --depth 1 -b master https://github.com/Emrvb/mopidy-radionet.git mopidy-radionet \
 && cd mopidy-radionet \
 && python3 setup.py install \
 && cd .. \
 && rm -rf mopidy-radionet

# Install additional mopidy extensions and Python dependencies via pip
COPY requirements.txt .
RUN python3 -m pip install -r requirements.txt

# Start helper script.
COPY docker/entrypoint.sh /entrypoint.sh

# Default configuration.
COPY docker/mopidy/mopidy.example.conf /config/mopidy.conf

# Copy the pulse-client configuratrion.
COPY docker/mopidy/pulse-client.conf /etc/pulse/client.conf

# Allows any user to run mopidy, but runs by default as a randomly generated UID/GID.
# RUN useradd -ms /bin/bash mopidy
ENV HOME=/var/lib/mopidy
RUN set -ex \
 && usermod -G audio,sudo mopidy \
 && mkdir /var/lib/mopidy/local \
 && chown mopidy:audio -R $HOME /entrypoint.sh /iris \
 && chmod go+rwx -R $HOME /entrypoint.sh /iris

## IRIS MODIFICATIONS
RUN PYTHON_VERSION=`python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))'` \
 && sed -i 's/upgrade_available = upgrade_available == 1/upgrade_available = False/g' /iris/mopidy_iris/core.py
## Disable restart option in container mode
## https://github.com/jaedb/Iris/blob/master/mopidy_iris/system.sh#L3-L7
RUN echo "1" >> /IS_CONTAINER
## Other special settings
## - Disable service worker (cache)
#RUN PYTHON_VERSION=`python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))'` \
# && rm -f ${MOPIDY_INSTALL_DIR}/lib/python$PYTHON_VERSION/site-packages/mopidy_iris/static/service-worker.js
## - Disable update check
# && sed -i 's/upgrade_available = upgrade_available == 1/upgrade_available = False/g' ${MOPIDY_INSTALL_DIR}/lib/python$PYTHON_VERSION/site-packages/mopidy_iris/core.py
## - Web-UI Settings
## .button--destructive: restart server and reset settings button
## .flag--dark: uptodate label
## .sub-tabs--servers: server configuration
# && sed -i 's/<style>/<style> .progress .slider {cursor: not-allowed !important;} .progress .slider__input {pointer-events: none !important;} .button--destructive {display: none !important} .flag--dark {display: none !important} .sub-tabs--servers {display: none !important}/g' ${MOPIDY_INSTALL_DIR}/lib/python$PYTHON_VERSION/site-packages/mopidy_iris/static/index.html
## - Patch system.sh with PATH and disable hardcoded _USE_SUDO!
# && sed -i "2i export PATH=${PATH}" ${MOPIDY_INSTALL_DIR}/lib/python$PYTHON_VERSION/site-packages/mopidy_iris/system.sh \
# && sed -i 's/_USE_SUDO = True/_USE_SUDO = False/g' ${MOPIDY_INSTALL_DIR}/lib/python$PYTHON_VERSION/site-packages/mopidy_iris/system.py

# Runs as mopidy user by default.
USER mopidy:audio

VOLUME ["/var/lib/mopidy/local"]

EXPOSE 6600 6680 1704 1705 5555/udp

ENTRYPOINT ["/usr/bin/dumb-init", "/entrypoint.sh"]
CMD ["mopidy"]
