# mopidy-docker: A Docker image for mopidy
[An extensible music server that plays music from local disk, Spotify, SoundCloud, TuneIn, and more.](https://mopidy.com/)

## Links
Source: [GitHub](https://github.com/jojo141185/mopidy-docker)  
Docker-Images: [DockerHub](https://hub.docker.com/r/jojo141185/mopidy

## About
Using Docker images built on top of this repo, mopidy with its extensions can be easily run on multiple machines with different architectures (amd64, arm).
Besides the music server mopidy, the image includes the great web interface [IRIS](https://github.com/jaedb/Iris/)from jaedb and other useful extensions, like:
- DLNA Server
- MPD Server
- Youtube & YTMusic
- Jellyfin
- Podcast
- RadioNet
- Soundcloud
- TuneIn
- MusicBox & Party Webclient
## Prerequisites
You need to have Docker up and running on a Linux machine, and the current user must be allowed to run containers (this usually means that the current user belongs to the "docker" group).

You can verify whether your user belongs to the "docker" group with the following command:
`getent group | grep docker`
This command will output one line if the current user does belong to the "docker" group, otherwise there will be no output.

## Get the image

Here is the [repository](https://hub.docker.com/repository/docker/jojo141185/mopidy) on DockerHub.

Getting the image from DockerHub is as simple as typing:

`docker pull jojo141185/mopidy:nightly`

You may want to pull the more stable "edge" image as opposed to the "nightly".

## Usage

Start mopidy from the directory where your mopidy config file (mopidy.conf) is placed by typing:

    docker run -d \
        --device /dev/snd \
        --user $UID:$GID \
        -v "$PWD/media:/var/lib/mopidy/media:ro" \
        -v "$PWD/local:/var/lib/mopidy/local" \
        -v "$PWD/mopidy.conf:/config/mopidy.conf" \
        -p 6600:6600 -p 6680:6680 \
        jojo141185/mopidy


The following table describes the docker arguments and environment variables:
ARGUMENT|DEFAULT|DESCRIPTION
---|---|---|
--device | /dev/snd | audio device of host machine to play sound on your system's audio output
--user | root | (optional) You may run as any UID/GID, by default it'll run as UID/GID 84044 (mopidy:audio within the container).
-v | $PWD:/var/lib/mopidy/media:ro | (optional) Cange $PWD path to directory with local media files (ro=read only).
-v | $PWD:/var/lib/mopidy/local | (optional) Cange $PWD path to directory to store local metadata, libraries and playlists.
-p | 6600:6600 | (optional) Exposes MPD server to port 6600 on host (if you use for example ncmpcpp client).
-p | 6680:6680 | (optional) Exposes HTTP server to port 6680 on host (if you use your browser as client).
-p | 5555:5555/udp | (optional) Exposes UDP streaming on port 5555 for FIFE sink (e.g. for visualizers).
    
Note: If you have issues, try first as --user root.
## Build

You can build (or rebuild) the image by opening a terminal from the root of the repository and issuing the following command:

`docker build . -t jojo141185/mopidy`

It will take a long time espacialy on a Raspberry Pi. When it's finished, you can run the container following the previous instructions.  
Just be careful to use the tag you have built.

## References
The Dockerfile is also based on the work of jaedb but includes some patches and bugfixes.
