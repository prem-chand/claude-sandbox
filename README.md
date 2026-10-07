# Claude Code in Docker with Command Code models

Run the Claude Code CLI in a container, backed by models from [Command Code](https://commandcode.ai) (DeepSeek, Kimi, Ling, Claude and others) instead of an Anthropic account.

Claude Code only speaks Anthropic's `/v1/messages` API. Most Command Code models only serve the OpenAI-style `/chat/completions` API, so a [LiteLLM](https://github.com/BerriAI/litellm) proxy sits in between and translates.

```
claude container  ──/v1/messages──▶  litellm proxy  ──/chat/completions──▶  Command Code
(Claude Code CLI)                    (localhost:4000)  ──/v1/messages─────▶  (claude-* models)
```

## Requirements

- Docker with Compose v2 (`docker compose version`)
- A Command Code API key
- For some `cc.sh` commands: `curl`, `jq` and `column` (`available`), and `python3` (`add`, `remove`, and writes to `.env`)

## Quick start

```bash
cd ~/projects/claude-sandbox
cp .env.example .env
# Edit .env and set COMMANDCODE_API_KEY (no quotes)

./cc.sh test ling-3.1-flash   # check that a model answers
./cc.sh                       # start Claude Code in the current folder
```

If you skip the `.env` step, `cc.sh` asks for the key on first run, saves it to `.env` and generates the proxy password for you. The first run also builds the `claude-code` image.

To call the script from any folder, link it onto your `PATH` as `ccs`. Do not name the link `cc`. On macOS and Linux, `cc` is the C compiler (`clang` or `gcc`).

```bash
ln -sf ~/projects/claude-sandbox/cc.sh ~/.local/bin/ccs
cd ~/some/project && ccs
```

## Using cc.sh

`cc.sh` mounts the folder you run it from at `/home/node/workspace` in the container. Claude Code can read and write only that folder.

| Command | What it does |
| --- | --- |
| `cc.sh` or `cc.sh run [model] [-- args]` | Start Claude Code. Arguments after `--` go to `claude`. |
| `cc.sh shell` | Open a bash shell in the container. |
| `cc.sh test [model]` | Send a one-line prompt and print the reply. |
| `cc.sh models` | List the models configured in the proxy. |
| `cc.sh available` | List every Command Code model and the endpoints it supports. |
| `cc.sh add <alias> <command-code-id>` | Add a model to the proxy and restart it. |
| `cc.sh remove <alias>` | Remove a model from the proxy and restart it. |
| `cc.sh key` | Change your Command Code API key and restart the proxy. |
| `cc.sh logs` | Follow the proxy logs. |
| `cc.sh restart` | Restart the proxy, for example after editing its config by hand. |
| `cc.sh update` | Rebuild the image with the latest Claude Code release. |
| `cc.sh stop` | Stop the proxy. |

Examples:

```bash
cc.sh run kimi-k3
cc.sh run ling-3.1-flash -- --dangerously-skip-permissions
cc.sh add glm-5.3 zai-org/GLM-5.3
```

Inside Claude Code, `/model <alias>` switches to any model from `cc.sh models`.

Claude Code prints a few notices that you can ignore with these models: `[claude-code:unrecognized_model]`, a note that a model "isn't described by this version's model catalog", and a note about auto mode billing through `litellm:4000`.

## The LiteLLM proxy

The proxy runs as the `litellm` service in `docker-compose.yml`. It listens on `localhost:4000` on your machine and on `http://litellm:4000` inside the Compose network. `cc.sh` starts it when needed, and it keeps running in the background until `cc.sh stop`.

The LiteLLM image is pinned by digest in `docker-compose.yml` to the version this setup was tested with (1.104.0). `cc.sh update` does not change it. To upgrade, replace the digest and run `cc.sh test`.

Its config is `litellm/config.yaml`. Each entry maps an alias that Claude Code uses to a Command Code model:

```yaml
- model_name: kimi-k3                     # the name you pass to cc.sh or /model
  litellm_params:
    model: openai/moonshotai/Kimi-K3      # provider prefix + Command Code model ID
    api_base: https://api.commandcode.ai/provider/v1
    api_key: os.environ/COMMANDCODE_API_KEY
```

The provider prefix decides how the proxy calls Command Code:

- `openai/<id>` with `api_base: https://api.commandcode.ai/provider/v1` for models that list `/chat/completions` in `cc.sh available`. This covers DeepSeek, Kimi, Ling, GLM, Qwen and most others.
- `anthropic/<id>` with `api_base: https://api.commandcode.ai/provider` for models that list `/messages`. These are the `claude-*` models, and the proxy passes their requests through unchanged.

`cc.sh add` picks the prefix for you: IDs starting with `claude-` get `anthropic/`, everything else gets `openai/`.

The setting `use_chat_completions_url_for_anthropic_messages: true` is required. Without it, LiteLLM sends `openai/` models to Command Code's `/responses` endpoint, which some models (such as `inclusionai/ling-3.1-flash:free`) reject.

Configured models:

| Alias | Command Code model |
| --- | --- |
| `deepseek-v4-pro` | `deepseek/deepseek-v4-pro` |
| `deepseek-v4-flash` | `deepseek/deepseek-v4-flash` |
| `deepseek-v4.1-flash` | `deepseek/deepseek-v4.1-flash` |
| `kimi-k3` | `moonshotai/Kimi-K3` |
| `kimi-k2.7-code` | `moonshotai/Kimi-K2.7-Code` |
| `ling-3.1-flash` | `inclusionai/ling-3.1-flash:free` |
| `claude-opus-5-5` | `claude-opus-5-5` |
| `claude-sonnet-5-5` | `claude-sonnet-5-5` |

## Env files

`.env`, `.env.*` (except `.env.example`) and `*.env` are listed in `.gitignore` and `.dockerignore`, so keys stay out of git and out of the image build. The `.example` files are templates and are not ignored. Never put a real key in them.

### .env (used by docker compose and cc.sh)

Docker Compose reads `.env` automatically. Copy it from `.env.example`.

| Variable | Required | Default | Purpose |
| --- | --- | --- | --- |
| `COMMANDCODE_API_KEY` | Yes | | Your Command Code key. Only the proxy sees it. |
| `LITELLM_MASTER_KEY` | Yes | | Password Claude Code uses to talk to the proxy. Any string works. `cc.sh` generates one if it is missing. |
| `MAIN_MODEL` | No | `deepseek-v4-pro` | Model Claude Code starts with. |
| `OPUS_MODEL` | No | `kimi-k3` | Model used when Claude Code asks for Opus. |
| `SONNET_MODEL` | No | `deepseek-v4-pro` | Model used when Claude Code asks for Sonnet. |
| `HAIKU_MODEL` | No | `deepseek-v4.1-flash` | Model used for Claude Code's small background tasks. |
| `SUBAGENT_MODEL` | No | `deepseek-v4-pro` | Model used by subagents. |
| `WORKSPACE` | No | this folder | Folder mounted into the container with plain `docker compose`. `cc.sh` ignores it and always mounts the folder you run it from. |

Model values must be aliases from `litellm/config.yaml`. Values must not be quoted.

### commandcode.env and deepseek.env (without the proxy)

These connect Claude Code straight to one provider's Anthropic-compatible endpoint, with no proxy. Copy the matching `.example` file, fill in the key, and run the image directly:

```bash
cp commandcode.env.example commandcode.env   # or deepseek.env.example
docker run -it --rm \
  --env-file commandcode.env \
  -v "$PWD":/home/node/workspace \
  -v claude-config:/home/node/.claude \
  claude-code
```

- `commandcode.env` reaches only Command Code's `claude-*` models, because only they serve `/messages`.
- `deepseek.env` uses DeepSeek's own API (`https://api.deepseek.com/anthropic`) with a DeepSeek key, not a Command Code key.

`docker run --env-file` keeps quotes as part of the value, so do not quote values in these files.

## Files

| File | Purpose |
| --- | --- |
| `cc.sh` | Helper script for everything above. |
| `Dockerfile` | `claude-code` image: Node 22, Claude Code CLI, git, ripgrep, jq. Runs as the non-root `node` user. |
| `docker-compose.yml` | The `litellm` proxy and `claude` services. |
| `litellm/config.yaml` | Proxy model list and settings. |
| `.env.example` | Template for `.env`. |
| `commandcode.env.example`, `deepseek.env.example` | Templates for running without the proxy. |

Claude Code's settings, login state and history live in the `claude-config` Docker volume, so they persist between runs. To start fresh, run `cc.sh stop` and then `docker volume rm claude-sandbox_claude-config`. Use `claude-config` instead if you only ever started the container with `docker run`.

## Troubleshooting

- **`insufficient credits`**: your Command Code account has no credits for that model. Free models such as `ling-3.1-flash` still work.
- **`MODEL_NOT_IN_PLAN`**: the `claude-*` models need a higher Command Code plan or on-demand usage.
- **`429 Upstream model provider is temporarily unavailable`**: the model is busy, which happens often with free models. Retry after a few seconds.
- **`is not available on this endpoint`**: the model does not support the endpoint the proxy used. Check `cc.sh available`, and check that `use_chat_completions_url_for_anthropic_messages: true` is still in `litellm/config.yaml`.
- **`Unknown model`** from `cc.sh`: the alias is not in `litellm/config.yaml`. Run `cc.sh models`, or add it with `cc.sh add`.
- **Any other proxy error**: run `cc.sh logs` to see the full upstream response.

## Gotchas

### `clang: error: no input files` from `cc`

macOS and Linux already ship `cc` as the C compiler (`/usr/bin/cc`). A link named `cc` either loses to `/usr/bin/cc` or replaces the compiler.

Use `ccs` (see Quick start). If you linked `cc` while a shell was open, that shell can keep a hashed path to clang. Run `rehash`, then call `ccs`.

### Host projects

`cc.sh` mounts only the directory you run it from, at `/home/node/workspace`. Claude Code cannot see other host folders.

To work on a project, `cd` into that project and run `ccs` or `./cc.sh`. `cc.sh shell` from this repo mounts this repo, not your other work.

### `/plugin marketplace add owner/repo` fails in the container

Typical errors:

```
Cloning into '.../owner-repo..clone'...
.../owner-repo..clone/.git/: No such file or directory

fatal: destination path '.../owner-repo..clone' already exists and is not an empty directory.
```

Claude Code clones the marketplace through its git sandbox to `~/.claude/plugins/marketplaces/<owner>-<repo>.<ref>.clone`. An empty ref becomes `..clone`. That sandbox cannot create `.git` in this image. The SSH retry uses the leftover directory. The container has no SSH keys.

Clone the marketplace yourself, then register it. Example for pstack:

```bash
docker ps --filter ancestor=claude-code --format '{{.Names}}'

docker exec -u node CONTAINER git clone --depth 1 \
  https://github.com/michael-denyer/pstack-claude.git \
  /home/node/.claude/plugins/marketplaces/pstack-claude
```

Add a `pstack-claude` entry to `/home/node/.claude/plugins/known_marketplaces.json` with `installLocation` set to that path. Enable the plugin in `/home/node/.claude/settings.json` under `enabledPlugins` (`pstack@pstack-claude`: true). Copy `plugins/pstack` from the clone into `/home/node/.claude/plugins/cache/pstack-claude/pstack/<version>/` if you want it loaded without `/plugin install`. Restart Claude Code.

Do not run `/plugin marketplace add` in this container. Remove leftover `*.clone` directories under `/home/node/.claude/plugins/marketplaces/` after a failed add.

### `400` missing `x-opencode-session`

OpenCode Go requires an `x-opencode-session` header on every request. Claude Code sends `X-Claude-Code-Session-Id`. LiteLLM calls Go as an OpenAI client and drops that header, so Go returns 400.

On each Go model in `litellm/config.yaml`, set:

```yaml
extra_headers:
  x-opencode-session: <stable-uuid>
  User-Agent: claude-sandbox/1.0
```

Then run `cc.sh restart`. A static id unblocks the 400. Go uses the id for routing and prompt cache. One id per conversation is better. This proxy does not map Claude's session header yet.
