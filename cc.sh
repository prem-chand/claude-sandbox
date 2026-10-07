#!/usr/bin/env bash
# Claude Code in Docker, talking to OpenCode models through a LiteLLM proxy.
set -euo pipefail

DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG="$DIR/litellm/config.yaml"
ENV_FILE="$DIR/.env"
CALLER_PWD="$(pwd -P)"
ZEN_BASE="https://opencode.ai/zen"

# The image runs as uid 1000 unless the host is Linux with another non-root uid.
if [ "$(uname -s)" = Linux ] && [ "$(id -u)" != 0 ]; then
  export HOST_UID="$(id -u)" HOST_GID="$(id -g)"
fi
GO_BASE="$ZEN_BASE/go/v1"

compose() {
  update_env </dev/null
  docker compose --project-directory "$DIR" -f "$DIR/docker-compose.yml" "$@"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [args]

  run [model] [-- claude args]   Start Claude Code in the current directory (default command)
  shell                          Bash shell in the Claude Code container
  test [model]                   Send a one-line prompt and print the reply
  models                         List models configured in the proxy
  available                      List OpenCode Go and Zen models
  add <alias> <opencode-id>      Add an OpenCode model to the proxy
  remove <alias>                 Remove a model from the proxy
  key                            Set or change your OpenCode API key
  logs                           Follow proxy logs
  restart                        Restart the proxy (after editing the config)
  update                         Rebuild the image with the latest Claude Code
  stop                           Stop the proxy

Examples:
  $(basename "$0")                       # Claude Code with the default model, in \$PWD
  $(basename "$0") run ling-3.1-flash
  $(basename "$0") run kimi-k3 -- --dangerously-skip-permissions
  $(basename "$0") add glm-5.3 glm-5.3
EOF
}

# The only writer of .env. Takes KEY=VALUE lines on stdin (kept out of argv),
# fills generated values that are missing, and replaces the file in one step
# under a lock, so an interrupt or a second cc.sh cannot lose or fork a key.
update_env() {
  python3 -c '
import fcntl, os, secrets, sys, tempfile, uuid

path = sys.argv[1]
# key: (make a value, values that count as missing)
GENERATED = {
    "OPENCODE_SESSION_ID": (lambda: str(uuid.uuid4()), {""}),
    "LITELLM_MASTER_KEY": (lambda: "sk-local-" + secrets.token_hex(12), {"", "sk-local-change-me"}),
    "LITELLM_CLIENT_KEY": (lambda: "sk-local-" + secrets.token_hex(12), {""}),
}
updates = dict(line.split("=", 1) for line in sys.stdin.read().splitlines() if line)

with open(path + ".lock", "a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    lines = open(path).read().splitlines() if os.path.exists(path) else []
    current = {}
    for line in lines:
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            current[k] = v
    for key, (make, missing) in GENERATED.items():
        if key not in updates and current.get(key, "") in missing:
            updates[key] = make()
    updates = {k: v for k, v in updates.items() if current.get(k) != v}
    if not updates:
        sys.exit()
    out, seen = [], set()
    for line in lines:
        key = line.split("=", 1)[0]
        if "=" in line and key in updates:
            out.append(f"{key}={updates[key]}")
            seen.add(key)
        else:
            out.append(line)
    out += [f"{k}={v}" for k, v in updates.items() if k not in seen]
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".env.tmp.")
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(out) + "\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
' "$ENV_FILE"
}

env_value() { sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | tail -1; }

set_key() {
  local key
  read -rsp "OpenCode API key: " key; echo
  [ -n "$key" ] || { echo "No key entered." >&2; exit 1; }
  printf 'OPENCODE_API_KEY=%s\n' "$key" | update_env
  echo "Saved to $ENV_FILE"
}

ensure_setup() {
  local key; key="$(env_value OPENCODE_API_KEY)"
  if [ -z "$key" ] || [ "$key" = your-opencode-key ]; then
    set_key
  fi
  local built
  built="$(docker image inspect -f '{{index .Config.Labels "claude-sandbox.uid"}}' claude-code 2>/dev/null || true)"
  if [ "$built" != "${HOST_UID:-1000}:${HOST_GID:-1000}" ]; then
    compose build claude
    # Named volumes keep the owner they had when Docker created them
    WORKSPACE= compose --progress quiet run --rm --no-deps -T --user root --entrypoint chown \
      claude -R node:node /home/node/.claude /home/node/workspace
  fi
}

start_proxy() {
  compose --progress quiet up -d --wait litellm
}

# Mounting the repo, an ancestor of it, or $HOME would let Claude Code read .env.
guard_workspace() {
  case "$DIR/" in
    "${CALLER_PWD%/}"/*)
      echo "Refusing to mount $CALLER_PWD: it contains $ENV_FILE with your API key." >&2
      echo "cd into a project folder and run this command again." >&2
      exit 1 ;;
  esac
  if [ "$CALLER_PWD" = "$(cd "$HOME" && pwd -P)" ]; then
    echo "Refusing to mount your home folder. cd into a project folder." >&2
    exit 1
  fi
}

opencode_models() { curl -fsS -m 20 "$1/models" | jq -r '.data[].id'; }

configured_models() { sed -n 's/^  - model_name: //p' "$CONFIG"; }

require_model() {
  configured_models | grep -Fqx "$1" || {
    echo "Unknown model '$1'. Configured models:" >&2
    configured_models | sed 's/^/  /' >&2
    exit 1
  }
}

restart_proxy() {
  compose --progress quiet up -d --wait --force-recreate litellm
  echo "Proxy restarted."
}

cmd="${1:-run}"
[ $# -gt 0 ] && shift

case "$cmd" in
  run)
    guard_workspace
    ensure_setup
    model_env=()
    if [ $# -gt 0 ] && [ "$1" != "--" ]; then
      require_model "$1"
      model_env=(-e "ANTHROPIC_MODEL=$1")
      shift
    fi
    [ "${1:-}" = "--" ] && shift
    start_proxy
    WORKSPACE="$CALLER_PWD" compose --progress quiet run --rm ${model_env[@]+"${model_env[@]}"} claude "$@"
    ;;
  shell)
    guard_workspace
    ensure_setup
    start_proxy
    WORKSPACE="$CALLER_PWD" compose --progress quiet run --rm --entrypoint bash claude
    ;;
  test)
    ensure_setup
    model="${1:-$(env_value MAIN_MODEL)}"
    model="${model:-deepseek-v4-pro}"
    require_model "$model"
    start_proxy
    echo "Asking $model..."
    WORKSPACE= compose --progress quiet run --rm -T -e "ANTHROPIC_MODEL=$model" claude -p "Reply with exactly: hello from $model" 2>&1 \
      | { grep -v -e unrecognized_model -e 'auto mode' -e "isn't described by" || true; }
    ;;
  models)
    configured_models
    ;;
  available)
    { opencode_models "$GO_BASE" | sed 's/^/go  /'
      opencode_models "$ZEN_BASE/v1" | sed 's/^/zen /'; }
    ;;
  add)
    [ $# -eq 2 ] || { echo "Usage: $(basename "$0") add <alias> <opencode-id>" >&2; exit 1; }
    alias="$1" id="$2" valid='^[A-Za-z0-9._-]+$'
    [[ $alias =~ $valid && $id =~ $valid ]] || {
      echo "Alias and id may only use letters, digits, '.', '_' and '-'." >&2; exit 1
    }
    if configured_models | grep -Fqx "$alias"; then
      echo "Model '$alias' already exists." >&2; exit 1
    fi
    if [[ "$id" == claude-* ]]; then
      provider="anthropic" base="$ZEN_BASE"
    elif opencode_models "$GO_BASE" | grep -Fqx "$id"; then
      provider="openai" base="$GO_BASE"
    elif opencode_models "$ZEN_BASE/v1" | grep -Fqx "$id"; then
      provider="openai" base="$ZEN_BASE/v1"
    else
      echo "OpenCode does not serve '$id'. Run: $(basename "$0") available" >&2; exit 1
    fi
    python3 - "$CONFIG" "$alias" "$provider/$id" "$base" <<'EOF'
import sys
path, alias, model, base = sys.argv[1:]
text = open(path).read()
entry = (f"  - model_name: {alias}\n"
         f"    litellm_params:\n"
         f"      <<: *opencode\n"
         f"      model: {model}\n"
         f"      api_base: {base}\n")
marker = "\nlitellm_settings:"
head, tail = text.split(marker, 1)
open(path, "w").write(head.rstrip("\n") + "\n" + entry + "\n" + marker.lstrip("\n") + tail)
EOF
    echo "Added $alias -> $id"
    restart_proxy
    ;;
  remove)
    [ $# -eq 1 ] || { echo "Usage: $(basename "$0") remove <alias>" >&2; exit 1; }
    require_model "$1"
    python3 - "$CONFIG" "$1" <<'EOF'
import sys
path, alias = sys.argv[1:]
lines = open(path).read().split("\n")
out, skip = [], False
for line in lines:
    if line.startswith("  - model_name: "):
        skip = line == f"  - model_name: {alias}"
    elif skip and not line.startswith("    "):
        skip = False
    if not skip:
        out.append(line)
open(path, "w").write("\n".join(out))
EOF
    echo "Removed $1"
    restart_proxy
    ;;
  key)
    set_key
    restart_proxy
    ;;
  logs)
    compose logs -f litellm
    ;;
  restart)
    restart_proxy
    ;;
  update)
    compose build --no-cache --pull claude
    ;;
  stop)
    compose down
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 1
    ;;
esac
