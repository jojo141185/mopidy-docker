# mopidy-docker: A Docker image for mopidy

[Mopidy](https://mopidy.com/) an extensible music server that plays music from local disk, Spotify, Tidal, Youtube, SoundCloud, TuneIn, and more.

## Links

Source: [GitHub](https://github.com/jojo141185/mopidy-docker)  
Docker-Images: [DockerHub](https://hub.docker.com/r/jojo141185/mopidy)

## About

Using Docker images built on top of this repo, mopidy with its extensions can be easily run on multiple machines with different architectures (amd64, arm).
Besides the music server mopidy, the image includes the great web interface [IRIS](https://github.com/jaedb/Iris/) from jaedb.
Please note that the image only includes a minimal set of the basic mopidy extensions:

- Mopidy-Local
- Mopidy-MPD

Other useful extensions can be installed and keep updated by pip on container startup. Simply add them to the environment variable **PIP_PACKAGES** as a list of package names.

## Prerequisites

You need to have Docker up and running on a Linux machine.
See the official documentation to [install the Docker Engine](https://docs.docker.com/engine/install/)

## Get the image

Here is the [repository](https://hub.docker.com/repository/docker/jojo141185/mopidy) on DockerHub.

Getting the image from DockerHub is as simple as typing:

`docker pull jojo141185/mopidy:release`

You can pull other, probably less stable image builds by the following tags
TAG|DESCRIPTION
---|---
latest | Image build from main / master branches
develop | Image build from develop branches (probably untested)

## Usage

You can start the mopidy container by simply using the command [`docker run`](https://docs.docker.com/engine/reference/commandline/run/) or the [docker compose](https://docs.docker.com/compose/) tool where you can store your docker configuration in a seperate yaml file.

In both ways you need to adapt the command or docker-compose.yaml file to your specific host environment.

### Manage Docker as a non-root user

If you need to run docker as non-root user then you need to add it to the docker group.

1. Create the docker group, if it does not already exist  
`sudo groupadd docker`
2. Add your user to the docker group  
`sudo usermod -aG docker $USER`
3. Log in to the new docker group (should avoid having to log out & log in again):  
`newgrp docker`
4. Check if docker can be run without root  
`docker run hello-world`  
Try to reboot if you still get permission error!

**Warning:**
The docker group grants privileges equivalent to the root user. For details on how this impacts security in your system, see [Docker Daemon Attack Surface](https://docs.docker.com/engine/security/#docker-daemon-attack-surface)

### docker run

Start the mopidy docker container with the docker run command:

    docker run -d \
        --name mopidy \
        --device /dev/snd \
        --user $UID:$GID \
        -v "$PWD/config:/config" \
        -v "$PWD/media:/var/lib/mopidy/media:ro" \
        -v "$PWD/local:/var/lib/mopidy/local" \
        -p 6600:6600 -p 6680:6680 \
        jojo141185/mopidy:release

The following table describes the docker arguments and environment variables:
ARGUMENT|DEFAULT|DESCRIPTION
---|---|---|
--device | /dev/snd | For ALSA share the hosts sound device /dev/snd. For pulseaudio see this [guide](https://github.com/mviereck/x11docker/wiki/Container-sound:-ALSA-or-Pulseaudio) or use [snapcast](https://github.com/badaix/snapcast) for network / multiroom audio solution.
--user | root | (optional) You may run as any UID/GID, by default it'll run as UID/GID 84044 (mopidy:audio within the container).
-v | $PWD/config:/config | (essential) Cange $PWD/config path to the directory on host where your mopidy.conf is located.
-v | $PWD/media:/var/lib/mopidy/media:ro | (optional) Cange $PWD/media path to directory with local media files (ro=read only).
-v | $PWD/local:/var/lib/mopidy/local | (optional) Cange $PWD/local path to directory to store local metadata, libraries and playlists.
-p | 6600:6600 | (optional) Exposes MPD server to port 6600 on host (if you use for example ncmpcpp client).
-p | 6680:6680 | (optional) Exposes HTTP server to port 6680 on host (if you use your browser as client).
-p | 5555:5555/udp | (optional) Exposes UDP streaming on port 5555 for FIFE sink (e.g. for visualizers).
-e | PIP_PACKAGES= | (optional) Environment variable to inject some pip packages and mopidy extensions (i.e. Mopidy-Tidal) on upstart of container.

Note:  

- Depending on the number ans size of PIP_PACKAGES you have, it may take a while to start on first run. Please be patient and look at the logs.
- If you have problems with permission errors, try --user root first.
- On problems accessing the web interface, check mopidy.conf using the correct IP address. Try "hostname: 0.0.0.0" to listen to any and with no (=empty) access restrictions in "allowed_origins = ".

### docker compose

First check that Docker compose is already [installed](https://docs.docker.com/compose/install/) on your host.

1. Copy the [docker-compose.yml](https://github.com/jojo141185/mopidy-docker/blob/main/docker/docker-compose.yml) file from this repository to the current directory.
2. Make sure that your mopidy config file (mopidy.conf) is placed in a subfolder named "config".  
You can also add / modify the volume paths in the yaml file, i.e. to your local media folder or the directory where the metadata information will be stored on host (see table above).
3. Start the mopidy container with the following command  
Compose V1: `docker-compose up -d`  
Compose V2: `docker compose up -d`

## Build

You can build (or rebuild) the image by opening a terminal from the root of the repository and issuing the following command:

`docker build . -t jojo141185/mopidy`

It will take a long time, espacialy on a Raspberry Pi. When it's finished, you can run the container following the previous instructions.  
Just be careful to use the tag from your own built.

## References

Spotify disabled access to libspotify on May 16 2022. To be able to use Spotify as audio source, the mopidy-Spotify-Plugin was tweaked by @kingosticks. It now uses the GStreamer plugin "gst-plugins-spotify" in the background to play Spotify songs.  
For this reason this mopidy container should be seen as an alpha version with limited features in interaction with Spotify (i.e. no seeking support).
