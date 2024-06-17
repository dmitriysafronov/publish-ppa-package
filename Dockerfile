FROM ubuntu:focal

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update && \
    apt-get install -y \
        gpg \
        debmake \
        debhelper \
        devscripts \
        equivs \
        distro-info-data \
        distro-info \
        rsync \
        software-properties-common

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
