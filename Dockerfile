# Bauumgebung fuer die eigenen Fassungen von Debian-Paketen (bau.sh).
# Zwei Images aus derselben Datei: pocket-debs-bau-<suite>-arm64 (Paketbau, --platform linux/arm64: auf amd64 ueber
# qemu-binfmt, auf arm64 nativ) und pocket-debs-repo-<suite> (Repo-Pflege mit reprepro und Abfragen der
# Debian-Quellen, Architektur des Rechners).
# Die Bauabhaengigkeiten eines Pakets holt jeder Bau frisch (apt-get build-dep), das Image bringt nur Werkzeuge mit.
# ccache: bau-innen.sh nutzt es, wenn bau.sh einen Cache-Ordner unter /ccache einhaengt.
ARG SUITE=forky
FROM debian:${SUITE}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential dpkg-dev fakeroot quilt patch ca-certificates curl xz-utils ccache \
    reprepro gnupg gpgv debian-archive-keyring \
    && rm -rf /var/lib/apt/lists/*
