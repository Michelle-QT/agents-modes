# agents-modes

Launchers that start Claude Code or Codex in an **agent permission mode**, so the agent's capabilities match the task.

## Modes

<!-- agents-modes:begin table -->

| Mode                  | read                | write                                   | egress                                      | mcp    | commands                                                 |
| --------------------- | ------------------- | --------------------------------------- | ------------------------------------------- | ------ | -------------------------------------------------------- |
| Research              | `workdir − secrets` | `workdir − secrets − forbidden`         | `*`                                         | zotero | `runbox` auto; no escapes; outside → prompt                 |
| Development           | `host − secrets`    | `workdir − secrets − forbidden`, `/tmp` | off, plus `fetch-all`, `ls-remote`, `gh-ro` | none   | sandboxed auto; escapes auto, unsandboxed; outside → prompt |
| Networked-development | `host − secrets`    | `workdir − secrets − forbidden`, `/tmp` | `*`                                         | none   | sandboxed auto; escapes auto, unsandboxed; outside → prompt |
| Sealed-development    | `host − secrets`    | `workdir − secrets − forbidden`, `/tmp` | off                                         | none   | sandboxed auto; escapes auto, unsandboxed; outside → prompt |

<!-- agents-modes:end table -->

### Entries

- `read`, `write`: what the mode may touch; the agent's own tools and its sandboxed commands get the same region.
- `host`: the whole filesystem; `workdir`: the launched project directory and below.
- `/tmp`: writable, and on macOS this means both `/tmp` and `/private/tmp`, which the sandbox resolves separately.
- `egress`: which outbound destinations the mode may reach, not the route it takes to reach them, where `off` pre-allows no destination and `*` allows any. The route is the `commands` cell's business: Networked-development reaches `*` through its own sandbox, so a plain `curl` works, while Research reaches `*` only through `runbox` and the web tools, so a plain `curl` does not.
- `mcp`: which mode-granted MCP servers the mode may reach; MCP is its own read and write surface, so neither `read` nor `egress` covers it. Claude loads exactly the generated per-mode server set; Codex loads that set, the always-prompt `run_as_user` command carrier, and temporarily trusted user-configured servers.
- `commands`: how a shell command is treated.
	- The intended rule is exhaustive: a command runs automatically only when the mode's sandbox or a named no-ask carrier permits it; every other command prompts the user; denial means it does not run; acceptance means the exact command runs as the user with the user's normal credentials and permissions.
	- `sandboxed auto`: runs without asking if it stays inside the mode's read/write/egress region.
	- `escapes auto, unsandboxed`: `sandbox-escape <name>` runs one direct non-symlink executable child of the project's `./sandbox-escapes/` outside the sandbox, without asking. An escape is user-authored code running unsandboxed, so an `off` egress cell binds the mode's own surfaces, not what a project escape chooses to do.
	- `runbox auto`: `runbox <cmd>` runs the command inside a per-session container whose only mount is the working directory, without asking; plain `docker` stays gated. Invoke it standalone, since a pipe or operator leaves later segments ungranted: `runbox sh -c 'a | b'`.
	- `outside → prompt`: Claude requests unsandboxed execution; Codex calls the always-prompt `run_as_user` MCP command carrier; both run the original command unchanged after acceptance.
<!-- agents-modes:begin secrets -->
- `secrets`: denied to automatic tools, sandboxed commands, and `runbox`; deliberate shell access follows the `outside → prompt` command rule.
	- `~/.aws`, `~/.ssh`, `~/.gnupg`, `~/.config/gcloud`, `~/.azure`, `~/.kube`, `~/.docker/config.json`, `~/.config/gh`, `~/.netrc`, `~/.npmrc`, `~/.pypirc`, `~/.git-credentials`, `~/.config/git/credentials`, `~/.terraform.d`, `~/.config/op`, `~/.password-store`, `~/.claude/.credentials.json`, `~/.codex/auth.json`, `~/.local/share/agents-modes/codex-sessions`
	- `**/.env`, `**/.env.*`, `**/*.pem`, `**/*.key`, `**/id_rsa`, `**/id_ed25519`: anchored at the launched project, not host-wide, since a host-wide pattern would deny the OS trust store (`/etc/ssl/cert.pem`) and break TLS.
<!-- agents-modes:end secrets -->
<!-- agents-modes:begin forbidden -->
- `forbidden`: readable, never writable without prompting, in any mode, because writing them changes what the agent is allowed to do.
	- `**/.git/config`, `**/.git/hooks/**`: a writable remote URL or hook redirects `fetch-all` or runs code; the rest of `.git` stays writable so `git commit` works.
	- `**/sandbox-escapes/**`, `**/container/**`: the escape surface and the box definition.
	- `**/.claude/settings.json`, `**/.claude/settings.local.json`, `**/.codex/**`, `**/.mcp.json`, `~/.codex/config.toml`, `~/.local/share/agents-modes/**`, `~/.local/share/claude-modes/**`: the mode's own configuration.
<!-- agents-modes:end forbidden -->
<!-- agents-modes:begin integrations -->
- `integrations`: a permission mode aims to control every user-configurable native route that can read, write, execute, or reach an external service; target-specific exceptions are recorded as gaps.
	- Default: `closed` for `user and project settings`, `hooks`, `rules`, `plugins`, `apps and connectors`, `browser and computer use`, `native image generation`, `MCP servers not named by the mode or a target carrier`.
	- Caveat: Claude currently loads its default user, project, and local settings, and Codex loads its user config, so personal settings remain available; the user is responsible for ensuring that inherited settings contain no dangerous integrations.
	- Organization-managed policy remains authoritative on both targets and is outside the user-configurable mode matrix.
	- Runtime artifact-root, authentication, and invocation environment variables are trusted launch inputs set before the agent starts; custom roots are not authenticated by the launchers.
<!-- agents-modes:end integrations -->

## Awareness

- The launchers append a target-effective mode digest and the exact active enforcement to the agent prompt.
- Each target installs one generic launcher implementation under the four mode names; the basename selects a generated manifest, including whether that mode starts the container substrate.
- Claude also passes the digest through `--append-subagent-system-prompt`, since Task-tool subagents do not inherit `--append-system-prompt`.
- Claude loads user, project, and local settings, admits only the generated strict MCP config, and disables the Chrome integration.
- Codex creates a temporary `CODEX_HOME`, copies the incoming user `config.toml` into it, layers the generated mode profile and config above that base, and adds generated rules, a disposable SQLite index, and a mode-denied invocation-environment snapshot for `run_as_user`; it links its active conversations, archived conversations, and session-name index to the incoming `CODEX_HOME`, records the launched project as untrusted for config loading, disables known integration features and shell additional-permission approvals, and removes only the temporary configuration and index state on exit.
- Codex mode launchers support `resume` and `exec resume`; use the same mode launcher that created the conversation because Codex retains the original mode prompt when resuming, so cross-mode resume is unsupported.
- Claude mode launchers support `--resume`, `--continue`, `-r`, and `-c`; they add `--fork-session` so the selected conversation continues under the current mode without carrying approvals remembered by the old session.
- Both targets reject caller flags and management subcommands that replace or mutate permission, integration, project-root, helper, or mode configuration; use the plain CLI for a deliberately customized session.

## Prompt assembly

- `modes.json` is the source of truth for mode-specific prompt facts, including display names, read and write regions, egress, MCP grants, helpers, and target gaps.
- `prompts/text.json` owns the shared and target-specific wording; `prompts/helpers/*.md` owns each granted helper's paragraph.
- `tools/agents-modes-gen` function `prompt_text` selects and renders that wording from the mode facts.
- `python3 tools/agents-modes-gen prompt codex research` previews the generated Codex Research digest, and replacing `codex` with `claude` previews the Claude digest.
- `make prompts` installs the generated digests under the prompt directory described in [[#Install]].
- Claude's model input is assembled from Claude Code's internal prompt, Claude Code's discovered project instructions and capabilities, the launcher's generated mode digest plus rendered permission JSON through `--append-system-prompt`, the digest alone for subagents through `--append-subagent-system-prompt`, and the user message.
	- Claude Code owns its internal prompt and does not publish its exact text.
	- The launcher rejects caller system-prompt replacements so they cannot replace the mode contract.
- Codex's model input is assembled from Codex's built-in base instructions, the launcher's generated mode digest plus rendered mode profile and config template as `developer_instructions`, Codex-generated capability and permission blocks, the project `AGENTS.md` chain, environment context, and the user message.
	- The isolated Codex home deliberately omits the ordinary user-global `AGENTS.md`; project `AGENTS.md` files remain visible.
	- `codex-research debug prompt-input "example request"` prints the exact model-visible input list without starting a model turn.
	- The mode launcher permits only `debug prompt-input`; other Codex debug and management subcommands remain blocked.
- Editing permission JSON or TOML directly is not durable because `make claude` and `make codex` regenerate it from `modes.json` through `claude_settings`, `codex_profile`, and `codex_session_config`.

## Install

```sh
make install      # shared prompts plus Claude and Codex targets
make prompts      # target-effective prompts -> ~/.local/share/agents-modes/prompts
make claude       # Claude launchers, settings, session renderer
make codex        # Codex launchers, command carrier, dispatcher helpers, isolated config templates
```

- `make install` copies files; the repo is not needed at runtime.
- Override install targets with `BINDIR`, `SHAREDIR`, `CLAUDE_SHAREDIR`, `AGENTS_SHAREDIR`, or `CONTAINER_SHAREDIR`; `CODEXHOME` selects an old Codex home whose legacy managed rules should be removed during migration.
- Requires `~/.local/bin` on your `PATH`.
- Requires `jq` and Python 3.11 or newer at launcher runtime.
- Claude launchers honor `CLAUDE_MODES_DIR` for settings and `AGENTS_MODES_DIR` for prompts; `claude-research` also honors `AGENTS_CONTAINER_DIR`.
- Codex launchers use the incoming `CODEX_HOME` as the user-config, authentication, and persistent conversation-state source and preserve the invocation environment for approved `run_as_user` commands; generated templates and prompts come from `AGENTS_MODES_DIR`, isolated session homes default to `$AGENTS_MODES_DIR/codex-sessions`, and Research also honors `AGENTS_CONTAINER_DIR`.
- Codex authentication can instead come from `AGENTS_MODES_CODEX_AUTH_HOME`, and its session parent can instead come from `AGENTS_CODEX_SESSION_DIR`.
- `compatibility.*.last_verified` in `modes.json` records the most recently behaviorally reviewed Claude Code and Codex CLI versions; `make test` reports version differences without failing because parser and behavioral checks determine compatibility.

## Usage

| Mode                  | Claude                         | Codex                         |
| --------------------- | ------------------------------ | ----------------------------- |
| Research              | `claude-research`              | `codex-research`              |
| Development           | `claude-development`           | `codex-development`           |
| Networked-development | `claude-networked-development` | `codex-networked-development` |
| Sealed-development    | `claude-sealed-development`    | `codex-sealed-development`    |

- Research needs a running Docker daemon; the launcher starts Docker Desktop and waits, else fails clearly.
- A project may extend the Research image with its own `container/Dockerfile` (`FROM agents-box:base`).
- Resume a Codex conversation with the launcher for its original mode, such as `codex-development resume` or `codex-research resume <session-id>`.
- Resume a Claude conversation with `claude-development --resume`, `claude-research --resume <session-id>`, or the corresponding launcher for another mode.

## Tests

Each tier is a target, so what a run needs and what it costs are visible in the command you type. They are listed cheapest first; `make test-all` runs the automated tiers.

```sh
make test         # offline: syntax, composition, temp-prefix installs, helper guards, coverage lint
make test-live    # a real host sandbox and Docker: generated seatbelt and container cases
make test-build   # test-live, plus permission to build the agents-box:base image
make test-network # reaches the public internet: container egress, remote helpers, open egress
make test-agents  # starts real Claude/Codex sessions; needs CLI auth and SPENDS TOKENS
make test-witness # interactive: the by-hand approval checks; you answer the dialogs; SPENDS TOKENS
make test-approvals # experimental Codex TUI prompt driver; not part of test-all; SPENDS TOKENS
```

- `make test` needs no Docker, network, or agent session; it also checks Codex profile loading when `codex` is on `PATH`. Develop against this tier.
- `make test-live` spends no tokens. It runs Research container cases and commands inside Codex's own seatbelt. Seatbelt cannot be applied from inside another sandbox, so run this tier on a bare host.
- Any skipped live row makes its tier incomplete and fails by default; set `AGENTS_MODES_ALLOW_SKIP=1` only to inspect an intentionally incomplete run.
- `make test-agents` spends tokens by starting one real Claude or Codex session per indexed agent case, so a complete run takes time. Negative shell and file-tool cases require a matching structured tool-attempt event plus absence of the forbidden effect; the exception is a Codex noninteractive pre-execution block, which requires the exact blocked verdict, a clean completed turn, no command event, and absence of the effect, while `make test-witness` remains the authority for prompt behavior. A provider failure after a matching failed command preserves that observed evidence. An observed structured denial ends a negative Claude case without waiting for another model response. Positive MCP cases require the server-created marker. Narrow a run with `AGENTS_MODES_LIVE_ONLY="claude-sealed-development"` or `AGENTS_MODES_LIVE_ONLY="claude-sealed-development:network"`; after an interrupted run, `AGENTS_MODES_LIVE_SKIP` accepts the same selector forms for already-observed cases.
- `make test-witness` is the by-hand tier, fully staged: 8 short sessions, one deny and one accept for each of 4 target and base-policy carrier combinations. Claude requests an unsandboxed retry; Codex calls `run_as_user`, which presents Allow or Cancel before running the exact probe command. The harness verifies the dialog report, probe files, and file owner. Narrow with `AGENTS_MODES_LIVE_ONLY="codex-development:outside-write-accept"`.
- `make test-approvals` spends tokens and drives the real Codex `run_as_user` TUI approval with `expect`; it is experimental and is not the approval coverage authority. Narrow a run with `AGENTS_MODES_LIVE_ONLY="codex-development:outside-write-accept"`; if Codex changes its approval picker keys, set `AGENTS_MODES_CODEX_APPROVAL_ACCEPT_KEYS` or `AGENTS_MODES_CODEX_APPROVAL_DENY_KEYS`.
- Other knobs: `AGENTS_MODES_LIVE_REMOTE_URL`, `AGENTS_MODES_LIVE_CODEX_AUTH_HOME`, `AGENTS_MODES_LIVE_CLAUDE_FALLBACK_MODEL` (defaults to `sonnet,haiku`; set it empty to disable fallback), `AGENTS_MODES_LIVE_USE_INSTALLED=1`.

## Coverage and known gaps

Every target, mode, and axis is either witnessed or listed below; `modes.json` is the source of truth.

<!-- agents-modes:begin gaps -->

- **masked at launch only** (`secrets`; Claude and Codex; Research): runbox's unreadable overlays are computed once at box_start, so a file matching a secret pattern created after launch is readable inside the box; desired: in-tree secrets are unreadable inside the Research container for the whole session.
- **host minus home by design** (`read`; Claude; Research): the sandboxed leg denies the home tree and re-allows the project, because a command must read /bin/sh and the TLS trust store to run; literal workdir confinement is not implementable there; desired: sandboxed commands read only the launched project.
- **user, project, and local settings are trusted temporarily** (`integrations`; Claude; Research, Development, Networked-development, and Sealed-development): Claude's default user, project, and local setting sources are loaded so personal skills and interface settings remain available; desired: inherited user-configurable integrations are disabled unless explicitly admitted by the mode.
- **user settings are trusted temporarily** (`integrations`; Codex; Research, Development, Networked-development, and Sealed-development): Codex's user config is loaded so custom model providers and personal settings remain available; generated mode settings disable known integration features, but arbitrary user MCP servers remain loaded; desired: inherited Codex user integrations are disabled unless explicitly admitted by the mode.
- **nonexistent nested guards are omitted for Bubblewrap compatibility** (`forbidden`; Codex; Research, Development, Networked-development, and Sealed-development): the rendered profile omits a nested read-only guard when its parent directory does not exist, because Codex 0.144.0's Bubblewrap backend otherwise fails before starting the sandbox; an absent guarded path can therefore be created during that session; desired: project configuration and reserved paths are read-only whether or not their parent directories exist at launch.

<!-- agents-modes:end gaps -->

Inspect generated coverage with `behavior-matrix-json`, target conformance with `conformance-matrix-json`, and approval witnesses with `approval-witness-matrix-json`.
