# Bauumgebung fuer die eigenen Fassungen von Debian-Paketen (build/pakete.sh).
# Zwei Images aus derselben Datei: lisbon-pakete-bau-<suite>-arm64 (Paketbau, --platform linux/arm64 ueber
# qemu-binfmt) und lisbon-pakete-repo-<suite> (Repo-Pflege mit reprepro und Abfragen der Debian-Quellen, nativ).
# Die Bauabhaengigkeiten eines Pakets holt jeder Bau frisch (apt-get build-dep), das Image bringt nur Werkzeuge mit.
ARG SUITE=forky
FROM debian:${SUITE}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential dpkg-dev fakeroot quilt patch ca-certificates curl xz-utils \
    reprepro gnupg gpgv debian-archive-keyring \
    && rm -rf /var/lib/apt/lists/*
