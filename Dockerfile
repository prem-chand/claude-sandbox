FROM node:22-slim

# Tools Claude Code relies on or commonly uses
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates curl ripgrep jq less procps openssh-client \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code && npm cache clean --force

# Run as the non-root "node" user (uid 1000) so files written to mounted
# volumes keep host ownership and --dangerously-skip-permissions is allowed
USER node
RUN mkdir -p /home/node/.claude /home/node/workspace
WORKDIR /home/node/workspace

ENV DISABLE_AUTOUPDATER=1 \
    CLAUDE_CONFIG_DIR=/home/node/.claude

ENTRYPOINT ["claude"]
