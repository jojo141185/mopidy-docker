#!/bin/bash

# If PGID and PUID are set, this modifies the UID/GID of the precreated user account mopidy and the group audio
# This helps matching the container's UID/GID with the host's to avoid permission issues on the mounted volume.
if [ -n "$PGID" ] || [ -n "$PUID" ]; then
    if [ -n "$PGID" ] && [ -n "$PUID" ]; then
        echo "Requested change of UID: $PUID and GID: $PGID for running user."
    elif [ -n "$PGID" ]; then
        echo "Requested change of GID: $PGID for running group."
    elif [ -n "$PUID" ]; then
        echo "Requested change of UID: $PUID for running user."
    fi

    # Check and change mopidy user UID if necessary
    if [ -n "$PUID" ]; then
        if id -u mopidy > /dev/null 2>&1; then
            echo "mopidy UID $PUID already exists. No change made."
        else
            echo "Changing mopidy user to UID $PUID"
            usermod --uid $PUID mopidy
        fi
    fi

    # Check and change mopidy group GID if necessary
    if [ -n "$PGID" ]; then
        if id -g audio > /dev/null 2>&1; then
            echo "audio GID $PGID already exists. No change made."
        else
            echo "Changing audio group to GID $PGID"
            groupmod --gid $PGID audio
        fi
    fi

    # Change ownership of relevant directories
    if [ -n "$PUID" ] || [ -n "$PGID" ]; then
        chown -R mopidy:audio /var/lib/mopidy /entrypoint.sh /iris
    fi
fi

# Check and set PULSE_COOKIE_DATA
if [ -n "$PULSE_COOKIE_DATA" ]; then
    echo -ne $(echo $PULSE_COOKIE_DATA | sed -e 's/../\\x&/g') > $HOME/pulse.cookie
    export PULSE_COOKIE=$HOME/pulse.cookie
fi

# Check and install additional PIP packages
if [ -n "$PIP_PACKAGES" ]; then
    echo "-- INSTALLING PIP PACKAGES $PIP_PACKAGES --"
    python3 -m pip install --no-cache $PIP_PACKAGES
fi

# Execute the original Docker entrypoint script
# source /docker-entrypoint.sh

# Execute command passed to the container
exec "$@"
