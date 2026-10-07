FROM node:22-slim

# Tools Claude Code relies on or commonly uses
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates curl ripgrep jq less procps openssh-client \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code && npm cache clean --force

# Run as the non-root "node" user so --dangerously-skip-permissions is allowed.
# On Linux, cc.sh passes the host uid and gid so files in the workspace keep
# host ownership. Docker Desktop on macOS maps ownership itself.
ARG UID=1000
ARG GID=1000
RUN if [ "$UID:$GID" != 1000:1000 ]; then \
        groupmod -o -g "$GID" node && usermod -o -u "$UID" -g "$GID" node \
        && chown -R node:node /home/node; \
    fi
LABEL claude-sandbox.uid="$UID:$GID"
USER node
RUN mkdir -p /home/node/.claude /home/node/workspace
WORKDIR /home/node/workspace

ENV DISABLE_AUTOUPDATER=1 \
    CLAUDE_CONFIG_DIR=/home/node/.claude

ENTRYPOINT ["claude"]
