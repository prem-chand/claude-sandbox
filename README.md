# Claude Code in Docker with OpenCode models

Run the Claude Code CLI in a container, backed by models from [OpenCode](https://opencode.ai) Go and Zen (DeepSeek, Kimi, Ling, Claude and others) instead of an Anthropic account.

Claude Code only speaks Anthropic's `/v1/messages` API. Most OpenCode models only serve the OpenAI-style `/chat/completions` API, so a [LiteLLM](https://github.com/BerriAI/litellm) proxy sits in between and translates.

```
claude container  ──/v1/messages──▶  litellm proxy  ──/chat/completions──▶  OpenCode Go / Zen
(Claude Code CLI)                    (localhost:4000)  ──/v1/messages─────▶  (claude-* models on Zen)
```

## Requirements

- Docker with Compose v2 (`docker compose version`)
- An OpenCode API key
- For some `cc.sh` commands: `curl`, `jq` and `column` (`available`), and `python3` (`add`, `remove`, and writes to `.env`)

## Quick start

```bash
cd ~/projects/claude-sandbox
cp .env.example .env
# Edit .env and set OPENCODE_API_KEY (no quotes)

./cc.sh test deepseek-v4.1-flash   # check that a model answers
cd ~/some/project && ~/projects/claude-sandbox/cc.sh   # start Claude Code in that project
```

`cc.sh` does not start Claude Code in this repo folder, in a folder above it, or in your home folder. Those folders contain `.env`, and Claude Code could read your API key from it.

If you skip the `.env` step, `cc.sh` asks for the key on first run, saves it to `.env` and generates the proxy password for you. The first run also builds the `claude-code` image.

To call the script from any folder, link it onto your `PATH` as `ccs`. Do not name the link `cc`. On macOS and Linux, `cc` is the C compiler (`clang` or `gcc`).

```bash
ln -sf ~/projects/claude-sandbox/cc.sh ~/.local/bin/ccs
cd ~/some/project && ccs
```

## Using cc.sh

`cc.sh` mounts the folder you run it from at `/home/node/workspace` in the container. Claude Code can read and write only that folder. `cc.sh test` mounts an empty volume.

| Command | What it does |
| --- | --- |
| `cc.sh` or `cc.sh run [model] [-- args]` | Start Claude Code. Arguments after `--` go to `claude`. |
| `cc.sh shell` | Open a bash shell in the container. |
| `cc.sh test [model]` | Send a one-line prompt and print the reply. |
| `cc.sh models` | List the models configured in the proxy. |
| `cc.sh available` | List every OpenCode model, prefixed with `go` or `zen`. |
| `cc.sh add <alias> <opencode-id>` | Add a model to the proxy and restart it. |
| `cc.sh remove <alias>` | Remove a model from the proxy and restart it. |
| `cc.sh key` | Change your OpenCode API key and restart the proxy. |
| `cc.sh logs` | Follow the proxy logs. |
| `cc.sh restart` | Restart the proxy, for example after editing its config by hand. |
| `cc.sh update` | Rebuild the image with the latest Claude Code release. |
| `cc.sh stop` | Stop the proxy. |

Examples:

```bash
cc.sh run kimi-k3
cc.sh run ling-3.1-flash -- --dangerously-skip-permissions
cc.sh add glm-5.3 glm-5.3
```

Inside Claude Code, `/model <alias>` switches to any model from `cc.sh models`.

Claude Code prints a few notices that you can ignore with these models: `[claude-code:unrecognized_model]`, a note that a model "isn't described by this version's model catalog", and a note about auto mode billing through `litellm:4000`.

## The LiteLLM proxy

The proxy runs as the `litellm` service in `docker-compose.yml`. It listens on `localhost:4000` on your machine and on `http://litellm:4000` inside the Compose network. `cc.sh` starts it when needed, and it keeps running in the background until `cc.sh stop`.

The LiteLLM image is pinned by digest in `docker-compose.yml` to the version this setup was tested with (1.104.0). `cc.sh update` does not change it. To upgrade, replace the digest and run `cc.sh test`.

Claude Code authenticates with `LITELLM_CLIENT_KEY`, not the master key. The hook in `litellm/client_auth.py` lets that key call only `/v1/messages`, `/v1/messages/count_tokens` and `/v1/models`. Admin routes such as `/model/info`, `/key/generate` and `/config/update` return 403 for it. LiteLLM virtual keys would do the same job, but they need a Postgres database.

Its config is `litellm/config.yaml`. The `x-opencode` block at the top holds the API key and headers that all entries share. Each entry merges it with `<<: *opencode` and maps an alias that Claude Code uses to an OpenCode model:

```yaml
- model_name: kimi-k3                     # the name you pass to cc.sh or /model
  litellm_params:
    <<: *opencode                         # api_key and extra_headers
    model: openai/kimi-k3                 # provider prefix + OpenCode model ID
    api_base: https://opencode.ai/zen/go/v1
```

The prefix and `api_base` decide how the proxy calls OpenCode:

- `openai/<id>` with `https://opencode.ai/zen/go/v1` for models on the Go plan. This covers DeepSeek, Kimi, GLM, Qwen and others.
- `openai/<id>` with `https://opencode.ai/zen/v1` for models only on Zen, such as `ling-3.1-flash-free`.
- `anthropic/<id>` with `https://opencode.ai/zen` for the `claude-*` models. The proxy passes their requests through unchanged.

`cc.sh add` picks the route for you. IDs that start with `claude-` get `anthropic/` on Zen. Other IDs go to Go when Go serves them, and to Zen if not. `add` stops when neither serves the ID. New entries merge the shared `x-opencode` block.

The shared block sets `extra_headers` (see [`400` missing `x-opencode-session`](#400-missing-x-opencode-session)).

The setting `use_chat_completions_url_for_anthropic_messages: true` is required. Without it, LiteLLM sends `openai/` models to the `/responses` endpoint, which some models reject.

Configured models:

| Alias | OpenCode model |
| --- | --- |
| `deepseek-v4-pro` | `deepseek-v4-pro` (Go) |
| `deepseek-v4-flash` | `deepseek-v4-flash` (Go) |
| `deepseek-v4.1-flash` | `deepseek-v4.1-flash` (Go) |
| `kimi-k3` | `kimi-k3` (Go) |
| `kimi-k2.7-code` | `kimi-k2.7-code` (Go) |
| `ling-3.1-flash` | `ling-3.1-flash-free` (Zen) |
| `claude-opus-5-5` | `claude-opus-5-5` (Zen) |
| `claude-sonnet-5-5` | `claude-sonnet-5` (Zen) |

## Env files

`.env`, `.env.*` (except `.env.example`) and `*.env` are listed in `.gitignore` and `.dockerignore`, so keys stay out of git and out of the image build. The `.example` files are templates and are not ignored. Never put a real key in them.

### .env (used by docker compose and cc.sh)

Docker Compose reads `.env` automatically. Copy it from `.env.example`. `cc.sh` writes `.env` with mode `600`, so other users on the machine cannot read your key.

| Variable | Required | Default | Purpose |
| --- | --- | --- | --- |
| `OPENCODE_API_KEY` | Yes | | Your OpenCode key. Only the proxy gets it as an environment variable. |
| `LITELLM_MASTER_KEY` | Yes | | Full-access proxy password, for the host only. Any string works. `cc.sh` generates one if it is missing. |
| `LITELLM_CLIENT_KEY` | Yes | | Proxy password Claude Code uses. It can only call the model routes. `cc.sh` generates one if it is missing. |
| `OPENCODE_SESSION_ID` | Yes | | Value of the `x-opencode-session` header. `cc.sh` generates a UUID if it is empty. With plain `docker compose`, set it yourself, for example with `uuidgen`. |
| `MAIN_MODEL` | No | `deepseek-v4-pro` | Model Claude Code starts with. |
| `OPUS_MODEL` | No | `kimi-k3` | Model used when Claude Code asks for Opus. |
| `SONNET_MODEL` | No | `deepseek-v4-pro` | Model used when Claude Code asks for Sonnet. |
| `HAIKU_MODEL` | No | `deepseek-v4.1-flash` | Model used for Claude Code's small background tasks. |
| `SUBAGENT_MODEL` | No | `deepseek-v4-pro` | Model used by subagents. |
| `HOST_UID`, `HOST_GID` | No | `1000` | User and group the image runs as. On Linux, `cc.sh` sets them to your own ids and rebuilds the image when they change, so workspace files keep your ownership. With plain `docker compose` on Linux, set them yourself. If you used an older image with another uid, run `cc.sh stop` and `docker volume rm claude-sandbox_claude-config` once. |
| `WORKSPACE` | No | empty `claude-workspace` volume | Folder mounted into the container with plain `docker compose` and `cc.sh test`. `cc.sh run` and `cc.sh shell` ignore it and mount the folder you run them from. Do not set it to this repo. |

Model values must be aliases from `litellm/config.yaml`. Values must not be quoted.

### commandcode.env and deepseek.env (without the proxy)

These connect Claude Code straight to one provider's Anthropic-compatible endpoint, with no proxy and no OpenCode key. Copy the matching `.example` file, fill in the key, and run the image directly:

```bash
cp commandcode.env.example commandcode.env   # or deepseek.env.example
docker run -it --rm \
  --env-file commandcode.env \
  -v "$PWD":/home/node/workspace \
  -v claude-config:/home/node/.claude \
  claude-code
```

- `commandcode.env` uses [Command Code](https://commandcode.ai) with a Command Code key. It reaches only their `claude-*` models, because only they serve `/messages`.
- `deepseek.env` uses DeepSeek's own API (`https://api.deepseek.com/anthropic`) with a DeepSeek key.

`docker run --env-file` keeps quotes as part of the value, so do not quote values in these files.

## Files

| File | Purpose |
| --- | --- |
| `cc.sh` | Helper script for everything above. |
| `Dockerfile` | `claude-code` image: Node 22, Claude Code CLI, git, ripgrep, jq. Runs as the non-root `node` user, with your uid on Linux. |
| `docker-compose.yml` | The `litellm` proxy and `claude` services. |
| `litellm/config.yaml` | Proxy model list and settings. |
| `litellm/client_auth.py` | Proxy auth hook. It limits `LITELLM_CLIENT_KEY` to the model routes. |
| `.env.example` | Template for `.env`. |
| `commandcode.env.example`, `deepseek.env.example` | Templates for running without the proxy. |

Claude Code's settings, login state and history live in the `claude-config` Docker volume, so they persist between runs. To start fresh, run `cc.sh stop` and then `docker volume rm claude-sandbox_claude-config`. Use `claude-config` instead if you only ever started the container with `docker run`.

## Troubleshooting

- **`Refusing to mount`** from `cc.sh`: you ran `cc.sh` in this repo, above it, or in your home folder. `cd` into a project folder.
- **`401` or `403` from OpenCode**: check `OPENCODE_API_KEY` with `cc.sh key`. Go models need the Go plan.
- **`OpenCode's free tier can only be used from within OpenCode`**: free Zen models such as `ling-3.1-flash` refuse requests from this proxy. Use a Go model.
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

To work on a project, `cd` into that project and run `ccs`. `cc.sh` refuses to run in this repo, so `.env` never gets mounted.

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

The shared `x-opencode` block in `litellm/config.yaml` sends this header on every request:

```yaml
extra_headers:
  x-opencode-session: os.environ/OPENCODE_SESSION_ID
  User-Agent: claude-sandbox/1.0
```

`cc.sh` writes a new UUID to `OPENCODE_SESSION_ID` in `.env` the first time it runs, so each install has its own id. Go uses the id for routing and prompt cache. All conversations on one install share it. One id per conversation is better, but this proxy does not map Claude's session header yet.
