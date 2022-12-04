FROM rust:slim-bullseye
LABEL org.opencontainers.image.authors="https://github.com/seppi91"
ARG TARGETPLATFORM
ARG TARGETARCH
ARG TARGETVARIANT
RUN printf "I'm building for TARGETPLATFORM=${TARGETPLATFORM}" \
    && printf ", TARGETARCH=${TARGETARCH}" \
    && printf ", TARGETVARIANT=${TARGETVARIANT} \n" \
    && printf "With uname -s : " && uname -s \
    && printf "and  uname -m : " && uname -mm

# Switch to the root user while we do our changes
USER root

# Install all libraries and needs
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    sudo \
    build-essential \
    curl \
    git \
    wget \
    gnupg2 \
    tar \
    dumb-init \
    graphviz-dev \
    pulseaudio \
    libasound2-dev \
    libdbus-glib-1-dev \
    libgirepository1.0-dev \
    # DLNA Server
    dleyna-server \
    # Install Python
    python3-dev \
    python3-gst-1.0 \
    python3-setuptools \
    python3-pip \
    python3-venv \
    # GStreamer (Plugins)
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    libgstreamer-plugins-bad1.0-dev \
    libgstrtspserver-1.0-dev \
    gstreamer1.0-plugins-base \ 
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \ 
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    #gstreamer1.0-alsa \
    gstreamer1.0-pulseaudio \
    # GStreamer build dependencies see
    # https://github.com/Kynothon/gst-plugins-rs-docker/blob/master/XDockerfile
    llvm-dev \
    libclang-dev \
    clang \
    gcc \
    libssl-dev \
    libcsound64-dev \
    libpango1.0-dev \
    libdav1d-dev \
    libwebp-dev
    # libgtk-4-dev # Only in bookworm

# Install gstreamer-spotify (EXPERIMENTAL)
# Note: For spotify with upgraded version number of dependency librespot to 0.4.2
#RUN cargo install cargo-c
WORKDIR /build
RUN git clone --depth 1 --single-branch -b main https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs.git
WORKDIR /build/gst-plugins-rs
RUN sed -i 's/librespot = { version = "0.4", default-features = false }/librespot = { version = "0.4.2", default-features = false }/g' audio/spotify/Cargo.toml
RUN MULTIARCHTUPLE=$(dpkg-architecture -qDEB_HOST_MULTIARCH) \
 #&& cargo cbuild --no-default-features -p gst-plugin-spotify --prefix=/usr --libdir=/usr/lib/$MULTIARCHTUPLE/ -r \
 #&& cargo cinstall -p gst-plugin-spotify --prefix=/usr --libdir=/usr/lib/$MULTIARCHTUPLE/
 && cargo build --no-default-features -p gst-plugin-spotify -r \
 && cp ./target/release/libgstspotify.so /usr/lib/$MULTIARCHTUPLE/gstreamer-1.0/
 #&& ln -s /usr/lib/$MULTIARCHTUPLE/gstreamer-1.0/libgstspotify.so /usr/lib64/$MULTIARCHTUPLE/gstreamer-1.0/libgstspotify.so || true \
WORKDIR /build
RUN rm -rf gst-plugins-rs
WORKDIR /

# Install mopidy from apt.mopidy.com
# see https://docs.mopidy.com/en/latest/installation/debian/
RUN mkdir -p /usr/local/share/keyrings \
 && wget -q -O /usr/local/share/keyrings/mopidy-archive-keyring.gpg https://apt.mopidy.com/mopidy.gpg \
 && wget -q -O /etc/apt/sources.list.d/mopidy.list https://apt.mopidy.com/buster.list \
 && apt-get update \
 && apt-get install -y mopidy \
 && rm -rf /var/lib/apt/lists/*

# Upgrade Python package manager pip
# https://pypi.org/project/pip/
RUN python3 -m pip install --upgrade pip

# Install PyGObject
# https://pypi.org/project/PyGObject/
RUN python3 -m pip install pygobject

# Install cffi from source
# Note: In some distributions libffi-devel is too old, hardcoded stuff
# https://pypi.org/project/cffi/
RUN python3 -m pip install cffi
#ENV CFFI_VERSION=1.15.0
#RUN python3 -m pip install cffi==${CFFI_VERSION}
# Or install from source
#RUN curl -so cffi-${CFFI_VERSION}.tar.gz https://files.pythonhosted.org/packages/00/9e/92de7e1217ccc3d5f352ba21e52398372525765b2e0c4530e6eb2ba9282a/cffi-${CFFI_VERSION}.tar.gz \
# && tar -xzf cffi-${CFFI_VERSION}.tar.gz --strip-components=1 \
# && python3 setup.py install \
# && rm -rf *

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

# Install default pip packages
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

# Install additional Python dependencies
COPY requirements.txt .
RUN python3 -m pip install -r requirements.txt

# Cleanup
RUN apt-get clean all && rm -rf /var/lib/apt/lists/* && rm -rf /root/.cache

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
 && chown mopidy:audio -R $HOME /entrypoint.sh \
 && chmod go+rwx -R $HOME /entrypoint.sh

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
# &&  sed -i 's/_USE_SUDO = True/_USE_SUDO = False/g' ${MOPIDY_INSTALL_DIR}/lib/python$PYTHON_VERSION/site-packages/mopidy_iris/system.py

# Runs as mopidy user by default.
USER mopidy:audio

VOLUME ["/var/lib/mopidy/local"]

EXPOSE 6600 6680 1704 1705 5555/udp

ENTRYPOINT ["/usr/bin/dumb-init", "/entrypoint.sh"]
CMD ["mopidy"]
