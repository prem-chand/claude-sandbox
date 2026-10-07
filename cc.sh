#!/usr/bin/env bash
# Claude Code in Docker, talking to Command Code models through a LiteLLM proxy.
set -euo pipefail

DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG="$DIR/litellm/config.yaml"
ENV_FILE="$DIR/.env"
CALLER_PWD="$PWD"

compose() { docker compose --project-directory "$DIR" -f "$DIR/docker-compose.yml" "$@"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [args]

  run [model] [-- claude args]   Start Claude Code in the current directory (default command)
  shell                          Bash shell in the Claude Code container
  test [model]                   Send a one-line prompt and print the reply
  models                         List models configured in the proxy
  available                      List Command Code models usable via the proxy
  add <alias> <command-code-id>  Add a Command Code model to the proxy
  remove <alias>                 Remove a model from the proxy
  key                            Set or change your Command Code API key
  logs                           Follow proxy logs
  restart                        Restart the proxy (after editing the config)
  update                         Rebuild the image with the latest Claude Code
  stop                           Stop the proxy

Examples:
  $(basename "$0")                       # Claude Code with the default model, in \$PWD
  $(basename "$0") run ling-3.1-flash
  $(basename "$0") run kimi-k3 -- --dangerously-skip-permissions
  $(basename "$0") add glm-5.3 zai-org/GLM-5.3
EOF
}

set_env_var() {
  local k="$1" v="$2"
  touch "$ENV_FILE"
  if grep -q "^$k=" "$ENV_FILE"; then
    sed -i "s|^$k=.*|$k=$v|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$k" "$v" >>"$ENV_FILE"
  fi
}

env_value() { sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | tail -1; }

set_key() {
  local key
  read -rsp "Command Code API key: " key; echo
  [ -n "$key" ] || { echo "No key entered." >&2; exit 1; }
  set_env_var COMMANDCODE_API_KEY "$key"
  echo "Saved to $ENV_FILE"
}

ensure_setup() {
  local key; key="$(env_value COMMANDCODE_API_KEY)"
  if [ -z "$key" ] || [ "$key" = your-command-code-key ]; then
    set_key
  fi
  local master; master="$(env_value LITELLM_MASTER_KEY)"
  if [ -z "$master" ] || [ "$master" = sk-local-change-me ]; then
    set_env_var LITELLM_MASTER_KEY "sk-local-$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi
  if ! docker image inspect claude-code >/dev/null 2>&1; then
    compose build claude
  fi
}

start_proxy() {
  compose --progress quiet up -d --wait litellm
}

configured_models() { sed -n 's/^  - model_name: //p' "$CONFIG"; }

require_model() {
  configured_models | grep -qx "$1" || {
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
    ensure_setup
    model_env=()
    if [ $# -gt 0 ] && [ "$1" != "--" ]; then
      require_model "$1"
      model_env=(-e "ANTHROPIC_MODEL=$1")
      shift
    fi
    [ "${1:-}" = "--" ] && shift
    start_proxy
    WORKSPACE="$CALLER_PWD" compose --progress quiet run --rm "${model_env[@]}" claude "$@"
    ;;
  shell)
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
    compose --progress quiet run --rm -T -e "ANTHROPIC_MODEL=$model" claude -p "Reply with exactly: hello from $model" 2>&1 \
      | grep -v -e unrecognized_model -e 'auto mode' -e "isn't described by"
    ;;
  models)
    configured_models
    ;;
  available)
    curl -fsS -m 20 https://api.commandcode.ai/provider/v1/models \
      | jq -r '.data[] | "\(.id)\t\(.supported_endpoints | join(","))"' \
      | column -t
    ;;
  add)
    [ $# -eq 2 ] || { echo "Usage: $(basename "$0") add <alias> <command-code-id>" >&2; exit 1; }
    alias="$1" id="$2"
    if configured_models | grep -qx "$alias"; then
      echo "Model '$alias' already exists." >&2; exit 1
    fi
    if [[ "$id" == claude-* ]]; then
      provider="anthropic" base="https://api.commandcode.ai/provider"
    else
      provider="openai" base="https://api.commandcode.ai/provider/v1"
    fi
    python3 - "$CONFIG" "$alias" "$provider/$id" "$base" <<'EOF'
import sys
path, alias, model, base = sys.argv[1:]
entry = (f"  - model_name: {alias}\n"
         f"    litellm_params:\n"
         f"      model: {model}\n"
         f"      api_base: {base}\n"
         f"      api_key: os.environ/COMMANDCODE_API_KEY\n")
text = open(path).read()
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
