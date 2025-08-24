#!/bin/bash

# Function to print section headers
print_section() {
    echo -e "\n\033[1;34m=== $1 ===\033[0m"  # Blue bold header
}

print_section "Starting Entrypoint Script"
echo "The entrypoint script is being run as user \"$(whoami)\"."

# The precreated user account "mopidy" and the group "audio" has a randomly generated UID/GID by default.
# If the environment variables PGID and PUID are set, this will change the UID/GID of the container's user.
# This helps matching the container's UID/GID with the host's to avoid permission issues on the mounted volume.
# Note: To do the user id mapping, the container needs to be run as root

# Only proceed with user and group mapping if the script is run as root
if [ -n "$PGID" ] || [ -n "$PUID" ]; then
    print_section "Mapping UID/GID"
    if [ "$(whoami)" = "root" ]; then
        echo "Mapping UID/GID of user \"$DOCKER_USER\"."
        
        # Check and change user and group if necessary
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

            # Change ownership of all relevant directories
            echo "Changing ownership of all relevant directories."
            chown -R $DOCKER_USER:$DOCKER_GROUP $HOME /iris /VERSION /entrypoint.sh 
    else
        # If not root, skip user and group mapping
        echo "Skipping UID/GID mapping, because running as non-root user."
    fi
fi

# Update PulseAudio client.conf with PULSE_SERVER
if [ -n "$PULSE_SERVER" ]; then
    print_section "Configuring PulseAudio"
    export PULSE_SERVER="$PULSE_SERVER"
    if [ "$(whoami)" = "root" ]; then
        echo "Setting default PulseAudio server to \"$PULSE_SERVER\" in /etc/pulse/client.conf"
        # Ensure the PULSE_SERVER line exists in the file, and replace it
        sed -i.bak "s|^default-server = .*|default-server = $PULSE_SERVER|" /etc/pulse/client.conf
    else
        # If not root, skip user and group mapping
        echo "Skipping default server setting in PulseAudio client config, because running as non-root user."
    fi
fi

# Set PULSE_COOKIE_DATA only if PULSE_COOKIE_DATA is not empty
if [ -n "$PULSE_COOKIE_DATA" ]; then
    print_section "Setting Pulse Cookie"
    echo "Setting PULSE_COOKIE_DATA to \"$HOME/pulse.cookie\""
    echo -ne $(echo $PULSE_COOKIE_DATA | sed -e 's/../\\x&/g') > $HOME/pulse.cookie
    chown $DOCKER_USER:$DOCKER_GROUP $HOME/pulse.cookie
    export PULSE_COOKIE="$HOME/pulse.cookie"
elif [ -n "$PULSE_COOKIE" ]; then
    export PULSE_COOKIE="$PULSE_COOKIE"
fi

# Install additional PIP packages
if [ -n "$PIP_PACKAGES" ]; then
    print_section "Installing Additional PIP-Packages"
    echo "-- INSTALLING PIP PACKAGES: $PIP_PACKAGES --"
    /opt/venv/bin/python3 -m pip install --no-cache $PIP_PACKAGES
fi

# Execute the passed command as the specified user
print_section "Executing Main Process"
if [ "$(whoami)" = "root" ]; then
    echo "Executing main process \"$@\" as non-root user \"$DOCKER_USER\" with UID $(id -u $DOCKER_USER)"
    if [[ $# -gt 0 ]]; then
        exec sudo -u $DOCKER_USER -H "$@"
    else
        exec sudo -u $DOCKER_USER -H bash
    fi
else
    echo "Executing main process \"$@\" as docker user \"$(whoami)\" with UID $(id -u $DOCKER_USER)"
    if [[ $# -gt 0 ]]; then
        exec "$@"
    else
        exec bash
    fi
fi