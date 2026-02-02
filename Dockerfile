FROM alpine:latest

# Install qemu, downloader and a small init to handle signals, plus python/git and
# the distribution websockify package (pin to the requested package/version).
RUN apk add --no-cache \
    qemu-img qemu-system-x86_64 \
    bash curl ca-certificates \
    dumb-init \
    git \
    websockify \
  && update-ca-certificates \
  && rm -rf /var/cache/apk/*

# Clone noVNC into the image so the web UI is available 
RUN git clone --depth=1 https://github.com/novnc/noVNC.git /opt/noVNC \ 
  || (echo "Failed to clone noVNC" && exit 1)

# Cleanup of git repo
RUN rm -rf /opt/noVNC/.git* || true

# Copying the modded index.html so the user does not stare at a fileindex
COPY ./assets/index.html /opt/noVNC/index.html

# Remove git from the container
RUN apk del git

# Add entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /work
ENTRYPOINT ["/usr/bin/dumb-init", "--", "/usr/local/bin/entrypoint.sh"]
