# Samsung's Emscripten fork ships Linux x86-64 only; this image is just the compiler.
FROM --platform=linux/amd64 ubuntu:22.04
RUN apt-get update && apt-get install -y python2 unzip ca-certificates curl default-jre-headless \
 && ln -sf /usr/bin/python2 /usr/bin/python && rm -rf /var/lib/apt/lists/*
WORKDIR /opt
RUN curl -fsSL -o e.zip 'https://developer.samsung.com/smarttv/file/a5013a65-af11-4b59-844f-2d34f14d19a9' \
 && unzip -q e.zip && rm e.zip && cd emscripten-release-bundle/emsdk && ./emsdk activate latest-fastcomp
ENV EMSDK=/opt/emscripten-release-bundle/emsdk
