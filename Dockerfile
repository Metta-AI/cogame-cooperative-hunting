# Build Docker. Staghunt's two-stage recipe (nimby 0.1.26, Nim 2.2.4,
# -d:release -d:useMalloc --opt:speed), extended to emit BOTH binaries.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/cogame-cooperative-hunting
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .

# The committed nim.cfg (if any) pins the author's machine paths; rebuild it
# from this container's synced package tree so the build is reproducible.
RUN rm -f nim.cfg && \
  for pkg in /root/.nimby/pkgs/*; do \
    if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg; \
    else echo "--path:\"$pkg\"" >> nim.cfg; fi; \
  done && \
  echo '--path:"src"' >> nim.cfg

# The bitworld package ships the static player/global client pages the
# certification runner probes on /client/player and /client/global
# (lantern 0.1.1). nimby's layout has moved between releases, so search.
RUN set -eu; \
  src=""; \
  for candidate in \
      /root/.nimby/pkgs/bitworld/client \
      /root/.nimby/pkgs/bitworld*/client \
      ./bitworld/client; do \
    if [ -f "$candidate/player_client.html" ]; then src="$candidate"; break; fi; \
  done; \
  if [ -z "$src" ]; then \
    echo "could not locate the bitworld static client directory" >&2; \
    ls -la /root/.nimby/pkgs >&2 || true; \
    exit 1; \
  fi; \
  mkdir -p /workspace/bitworld-assets; \
  cp -R "$src" /workspace/bitworld-assets/client; \
  ls /workspace/bitworld-assets/client

ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
RUN nim c $NimFlags --path:src --nimcache:/tmp/nimcache-game \
      --out:/bin/cooperative-hunting src/cooperative_hunting.nim && \
    nim c $NimFlags --path:src --nimcache:/tmp/nimcache-player \
      --out:/bin/cooperative-hunting-player src/cooperative_hunting_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    ca-certificates \
    curl && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/cogame-cooperative-hunting
COPY --from=build /bin/cooperative-hunting /bin/cooperative-hunting
COPY --from=build /bin/cooperative-hunting-player /bin/cooperative-hunting-player
COPY --from=build /workspace/bitworld-assets/client ./client
COPY coworld_manifest_template.json .
COPY sprites ./sprites

EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=2s --start-period=5s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1
CMD ["/bin/cooperative-hunting", "--address:0.0.0.0", "--port:8080"]
