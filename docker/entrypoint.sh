#!/bin/bash

# If PGID and PUID are set, this modifies the UID/GID of the precreated user account mopidy and the group audio
# This helps matching the container's UID/GID with the host's to avoid permission issues on the mounted volume.
# Note: To do the user id mapping, the container needs to be run as root
if [ -n "$PGID" ] || [ -n "$PUID" ]; then
    if [ -n "$PGID" ] && [ -n "$PUID" ]; then
        echo "Requested change of UID: $PUID and GID: $PGID for running user."
    elif [ -n "$PGID" ]; then
        echo "Requested change of GID: $PGID for running group."
    elif [ -n "$PUID" ]; then
        echo "Requested change of UID: $PUID for running user."
    fi

    # Check and change user UID if necessary
    DOCKER_USER_CURRENT_ID=$(id -u $DOCKER_USER)
    if [ -n "$PUID" ]; then
        if [ $DOCKER_USER_CURRENT_ID -eq $PUID ]; then
            echo "User $DOCKER_USER is already mapped to $DOCKER_USER_CURRENT_ID. Nice!"
        else
            DOCKER_USER_EXIST_NAME=$(getent passwd $PUID | cut -d: -f1)
            if [ -n "$DOCKER_USER_EXIST_NAME" ]; then
                echo "User ID is already taken by user: $DOCKER_USER_EXIST_NAME"
            else
                echo "Changing $DOCKER_USER user to UID $PUID"
                usermod --uid $PUID $DOCKER_USER
            fi
        fi
    fi

    # Check and change group GID if necessary
    if [ -n "$PGID" ]; then
        DOCKER_GROUP_CURRENT_ID=$(getent group $DOCKER_GROUP | cut -d: -f3)
        if [ $DOCKER_GROUP_CURRENT_ID -eq $PGID ]; then
            echo "Group $DOCKER_GROUP is already mapped to $DOCKER_GROUP_CURRENT_ID. Nice!"
        else
            DOCKER_GROUP_EXIST_NAME=$(getent group $PGID | cut -d: -f1)
            if [ -n "$DOCKER_GROUP_EXIST_NAME" ]; then
                echo "Group ID is already taken by group: $DOCKER_GROUP_EXIST_NAME"
            else
                echo "Changing $DOCKER_GROUP group to GID $PGID"
                groupmod --gid $PGID $DOCKER_GROUP
            fi
        fi
    fi

    # Change ownership of relevant directories
    if [ -n "$PUID" ] || [ -n "$PGID" ]; then
        chown -R $DOCKER_USER:$DOCKER_GROUP /var/lib/mopidy /entrypoint.sh /iris
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
    sudo -u $DOCKER_USER -H python3 -m pip install --no-cache $PIP_PACKAGES
fi

# Execute command passed to the container
if [[ $# -gt 0 ]]; then
    exec sudo -u $DOCKER_USER -H "$@"
else
    exec sudo -u $DOCKER_USER -H bash
fi
