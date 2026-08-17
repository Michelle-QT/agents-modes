# Install/uninstall agent permission modes.
#
# Launchers and Claude settings are COPIED to target directories. Codex profiles
# are installed by composing the mode profile with the shared Codex TUI fragment.
# After install the repo is no longer needed at runtime.

BINDIR   ?= $(HOME)/.local/bin
SHAREDIR ?= $(HOME)/.local/share/claude-modes
CLAUDE_SHAREDIR ?= $(SHAREDIR)
AGENTS_SHAREDIR ?= $(HOME)/.local/share/agents-modes
CONTAINER_SHAREDIR ?= $(AGENTS_SHAREDIR)/container
CODEXHOME ?= $(HOME)/.codex
CODEX_RULESDIR ?= $(CODEXHOME)/rules

# The capability table is stated once in modes.json; every settings file and profile is
# generated from it at install. Nothing generated is committed.
GEN := python3 tools/agents-modes-gen

MODES := $(shell $(GEN) mode-list)
TARGETS := claude codex
MODE_PROMPTS := $(foreach t,$(TARGETS),$(foreach m,$(MODES),$(t)/$(m).prompt.md))
CLAUDE_LAUNCHERS := $(addprefix claude-,$(MODES))
CLAUDE_LAUNCHER_SOURCE := claude/bin/claude-mode
CLAUDE_HELPERS   := claude-launcher-settings.sh
CLAUDE_SETTINGS  := $(addsuffix .json,$(MODES))
CLAUDE_MCP_CONFIGS := $(addsuffix .mcp.json,$(MODES))
RUNTIME_HELPER_SOURCES := $(shell $(GEN) runtime-helper-list)
RUNTIME_HELPERS := $(notdir $(RUNTIME_HELPER_SOURCES))
# Container-exec substrate (mode-agnostic; consumed by Research). `runbox`
# installs to BINDIR like a git helper; the base Dockerfile and lifecycle lib install to
# CONTAINER_SHAREDIR, which the launcher reads via AGENTS_CONTAINER_DIR.
CONTAINER_FILES  := Dockerfile boxlib.sh
CONTAINER_POLICY := policy.sh
CODEX_LAUNCHERS  := $(addprefix codex-,$(MODES))
CODEX_LAUNCHER_SOURCE := codex/bin/codex-mode
CODEX_RUN_AS_USER_SOURCE := $(shell $(GEN) codex-run-as-user-source)
CODEX_HELPERS    := codex-helper-dispatch codex-launcher-dispatch.sh codex-launcher-session.sh codex-dispatch-client.sh $(notdir $(CODEX_RUN_AS_USER_SOURCE))
CODEX_PROFILES   := $(addprefix agents-,$(addsuffix .config.toml,$(MODES)))
CODEX_SESSION_CONFIGS := $(addsuffix .config.toml,$(MODES))
CODEX_COMMON     := tui.config.toml
# Codex execpolicy rules are generated from modes.json for the helper cases that the
# profile policy cannot express by itself.
CODEX_RULES      := agents-modes.rules
CODEX_DEFAULT_RULES := default.rules

.PHONY: install uninstall reinstall list test test-live test-build test-network test-agents test-witness test-approvals test-all prompts uninstall-prompts list-prompts shared-runtime uninstall-shared-runtime list-shared-runtime claude uninstall-claude reinstall-claude list-claude codex uninstall-codex reinstall-codex list-codex

install: claude codex

uninstall: uninstall-claude uninstall-codex uninstall-shared-runtime uninstall-prompts

reinstall: uninstall install

list: list-prompts list-shared-runtime list-claude list-codex

# Test tiers, cheapest first. Each tier is a target, not a flag, so what a run needs and
# what it costs are visible in the command you type.
#   test          no host dependencies, no network, no tokens
#   test-live     a real host sandbox and Docker; no network, no tokens
#   test-build    test-live, plus permission to build the agents-box:base image
#   test-network  reaches the public internet; no tokens
#   test-agents   starts real Claude/Codex sessions; SPENDS TOKENS
#   test-witness  interactive by-hand approval witness; you answer the dialogs; SPENDS TOKENS
#   test-approvals experimental Codex TUI prompt driver; not part of test-all; SPENDS TOKENS
test:
	@tests/run.sh

test-live:
	@AGENTS_MODES_TIER="live host tests" tests/run-live.sh live-docker.sh live-codex-sandbox.sh

test-build:
	@AGENTS_MODES_TIER="live build tests" AGENTS_MODES_LIVE_BUILD=1 \
	  tests/run-live.sh live-docker.sh live-codex-sandbox.sh

test-network:
	@AGENTS_MODES_TIER="live network tests" AGENTS_MODES_LIVE_BUILD=1 \
	  tests/run-live.sh live-network.sh

# The full agent suite: if you are paying for real sessions, you get the network cases too.
test-agents:
	@AGENTS_MODES_TIER="live agent tests" AGENTS_MODES_LIVE_BUILD=1 AGENTS_MODES_LIVE_NETWORK=1 \
	  tests/run-live.sh agent-modes.sh

test-witness:
	@AGENTS_MODES_TIER="interactive approval witness" AGENTS_MODES_LIVE_BUILD=1 \
	  tests/run-live.sh live-witness.sh

test-approvals:
	@AGENTS_MODES_TIER="experimental live approval tests" AGENTS_MODES_LIVE_BUILD=1 \
	  tests/run-live.sh live-approvals.sh

test-all: test test-live test-network test-agents

prompts:
	@mkdir -p "$(AGENTS_SHAREDIR)/prompts/claude" "$(AGENTS_SHAREDIR)/prompts/codex" "$(AGENTS_SHAREDIR)/modes"
	@$(GEN) lint
	@for m in $(MODES); do \
	  for t in $(TARGETS); do \
	    $(GEN) prompt "$$t" "$$m" --output "$(AGENTS_SHAREDIR)/prompts/$$t/$$m.prompt.md" || exit 1; \
	    chmod 0644 "$(AGENTS_SHAREDIR)/prompts/$$t/$$m.prompt.md"; \
	    echo "prompt    -> $(AGENTS_SHAREDIR)/prompts/$$t/$$m.prompt.md (generated from modes.json + prompts/)"; \
	  done; \
	  $(GEN) manifest "$$m" --output "$(AGENTS_SHAREDIR)/modes/$$m.json" || exit 1; \
	  chmod 0644 "$(AGENTS_SHAREDIR)/modes/$$m.json"; \
	  echo "manifest  -> $(AGENTS_SHAREDIR)/modes/$$m.json (generated from modes.json)"; \
	done

uninstall-prompts:
	@for p in $(MODE_PROMPTS); do \
	  rm -f "$(AGENTS_SHAREDIR)/prompts/$$p" && echo "removed $(AGENTS_SHAREDIR)/prompts/$$p"; \
	done
	@for m in $(MODES); do \
	  rm -f "$(AGENTS_SHAREDIR)/modes/$$m.json" && echo "removed $(AGENTS_SHAREDIR)/modes/$$m.json"; \
	done
	@rmdir "$(AGENTS_SHAREDIR)/prompts/claude" "$(AGENTS_SHAREDIR)/prompts/codex" "$(AGENTS_SHAREDIR)/prompts" "$(AGENTS_SHAREDIR)/modes" "$(AGENTS_SHAREDIR)" 2>/dev/null || true

list-prompts:
	@echo "shared prompts (-> $(AGENTS_SHAREDIR)/prompts):" && printf '  %s\n' $(MODE_PROMPTS)
	@echo "mode manifests (-> $(AGENTS_SHAREDIR)/modes):" && printf '  %s.json\n' $(MODES)

shared-runtime:
	@mkdir -p "$(BINDIR)" "$(CONTAINER_SHAREDIR)"
	@for source in $(RUNTIME_HELPER_SOURCES); do \
	  name="$${source##*/}"; \
	  install -m 0755 "$$source" "$(BINDIR)/$$name"; \
	  echo "helper    -> $(BINDIR)/$$name"; \
	done
	@for f in $(CONTAINER_FILES); do \
	  install -m 0644 "container/$$f" "$(CONTAINER_SHAREDIR)/$$f"; \
	  echo "container -> $(CONTAINER_SHAREDIR)/$$f"; \
	done
	@$(GEN) container-policy-sh --output "$(CONTAINER_SHAREDIR)/$(CONTAINER_POLICY)" || exit 1
	@chmod 0644 "$(CONTAINER_SHAREDIR)/$(CONTAINER_POLICY)"
	@echo "container -> $(CONTAINER_SHAREDIR)/$(CONTAINER_POLICY) (generated from modes.json)"

uninstall-shared-runtime:
	@for h in $(RUNTIME_HELPERS); do \
	  rm -f "$(BINDIR)/$$h" && echo "removed $(BINDIR)/$$h"; \
	done
	@for f in $(CONTAINER_FILES); do \
	  rm -f "$(CONTAINER_SHAREDIR)/$$f" && echo "removed $(CONTAINER_SHAREDIR)/$$f"; \
	done
	@rm -f "$(CONTAINER_SHAREDIR)/$(CONTAINER_POLICY)" && echo "removed $(CONTAINER_SHAREDIR)/$(CONTAINER_POLICY)"
	@rmdir "$(CONTAINER_SHAREDIR)" 2>/dev/null || true

list-shared-runtime:
	@echo "shared helpers (-> $(BINDIR)):" && printf '  %s\n' $(RUNTIME_HELPERS)
	@echo "container (-> $(CONTAINER_SHAREDIR)):" && printf '  %s\n' $(CONTAINER_FILES) $(CONTAINER_POLICY)

claude: prompts shared-runtime
	@mkdir -p "$(CLAUDE_SHAREDIR)" "$(BINDIR)"
	@$(GEN) lint
	@for m in $(MODES); do \
	  $(GEN) claude-settings "$$m" --output "$(CLAUDE_SHAREDIR)/$$m.json" || exit 1; \
	  chmod 0644 "$(CLAUDE_SHAREDIR)/$$m.json"; \
	  echo "settings  -> $(CLAUDE_SHAREDIR)/$$m.json (generated from modes.json)"; \
	  $(GEN) claude-mcp-config "$$m" --output "$(CLAUDE_SHAREDIR)/$$m.mcp.json" || exit 1; \
	  chmod 0644 "$(CLAUDE_SHAREDIR)/$$m.mcp.json"; \
	  echo "mcp       -> $(CLAUDE_SHAREDIR)/$$m.mcp.json (generated from modes.json)"; \
	done
	@for l in $(CLAUDE_LAUNCHERS); do \
	  install -m 0755 "$(CLAUDE_LAUNCHER_SOURCE)" "$(BINDIR)/$$l"; \
	  echo "launcher  -> $(BINDIR)/$$l"; \
	done
	@for h in $(CLAUDE_HELPERS); do \
	  install -m 0755 "claude/helpers/$$h" "$(BINDIR)/$$h"; \
	  echo "helper    -> $(BINDIR)/$$h"; \
	done
	@echo "done. ensure $(BINDIR) is on your PATH."

uninstall-claude:
	@for l in $(CLAUDE_LAUNCHERS); do \
	  rm -f "$(BINDIR)/$$l" && echo "removed $(BINDIR)/$$l"; \
	done
	@for h in $(CLAUDE_HELPERS); do \
	  rm -f "$(BINDIR)/$$h" && echo "removed $(BINDIR)/$$h"; \
	done
	@for s in $(CLAUDE_SETTINGS); do \
	  rm -f "$(CLAUDE_SHAREDIR)/$$s" && echo "removed $(CLAUDE_SHAREDIR)/$$s"; \
	done
	@for s in $(CLAUDE_MCP_CONFIGS); do \
	  rm -f "$(CLAUDE_SHAREDIR)/$$s" && echo "removed $(CLAUDE_SHAREDIR)/$$s"; \
	done
	@rmdir "$(CLAUDE_SHAREDIR)" 2>/dev/null || true

reinstall-claude: uninstall-claude claude

list-claude:
	@echo "launchers (-> $(BINDIR)):" && printf '  %s\n' $(CLAUDE_LAUNCHERS)
	@echo "helpers   (-> $(BINDIR)):" && printf '  %s\n' $(CLAUDE_HELPERS)
	@echo "shared runtime: see list-shared-runtime"
	@echo "settings  (-> $(CLAUDE_SHAREDIR)):" && printf '  %s\n' $(CLAUDE_SETTINGS)
	@echo "mcp       (-> $(CLAUDE_SHAREDIR)):" && printf '  %s\n' $(CLAUDE_MCP_CONFIGS)

codex: prompts shared-runtime
	@mkdir -p "$(AGENTS_SHAREDIR)/codex/profiles" "$(AGENTS_SHAREDIR)/codex/config" "$(AGENTS_SHAREDIR)/codex/rules" "$(BINDIR)"
	@$(GEN) lint
	@for m in $(MODES); do \
	  $(GEN) codex-profile "$$m" --output "$(AGENTS_SHAREDIR)/codex/profiles/agents-$$m.config.toml" || exit 1; \
	  chmod 0644 "$(AGENTS_SHAREDIR)/codex/profiles/agents-$$m.config.toml"; \
	  echo "profile   -> $(AGENTS_SHAREDIR)/codex/profiles/agents-$$m.config.toml (generated from modes.json)"; \
	  $(GEN) codex-session-config "$$m" --output "$(AGENTS_SHAREDIR)/codex/config/$$m.config.toml" || exit 1; \
	  chmod 0644 "$(AGENTS_SHAREDIR)/codex/config/$$m.config.toml"; \
	  echo "config    -> $(AGENTS_SHAREDIR)/codex/config/$$m.config.toml (generated from modes.json)"; \
	done
	@$(GEN) codex-rules --output "$(AGENTS_SHAREDIR)/codex/rules/$(CODEX_RULES)" || exit 1
	@chmod 0644 "$(AGENTS_SHAREDIR)/codex/rules/$(CODEX_RULES)"
	@echo "rules     -> $(AGENTS_SHAREDIR)/codex/rules/$(CODEX_RULES) (generated from modes.json)"
	@if [ -f "$(CODEXHOME)/$(CODEX_DEFAULT_RULES)" ] && grep -q '^# BEGIN agents-modes managed rules$$' "$(CODEXHOME)/$(CODEX_DEFAULT_RULES)"; then \
	  tmp="$$(mktemp "$${TMPDIR:-/tmp}/agents-modes-rules.XXXXXX")" || exit 1; \
	  awk 'BEGIN { skip = 0 } /^# BEGIN agents-modes managed rules$$/ { skip = 1; next } /^# END agents-modes managed rules$$/ { skip = 0; next } skip == 0 { print }' "$(CODEXHOME)/$(CODEX_DEFAULT_RULES)" > "$$tmp" || exit 1; \
	  if grep -q '[^[:space:]]' "$$tmp"; then \
	    install -m 0644 "$$tmp" "$(CODEXHOME)/$(CODEX_DEFAULT_RULES)" || exit 1; \
	    echo "updated $(CODEXHOME)/$(CODEX_DEFAULT_RULES)"; \
	  else \
	    rm -f "$(CODEXHOME)/$(CODEX_DEFAULT_RULES)" && echo "removed $(CODEXHOME)/$(CODEX_DEFAULT_RULES)"; \
	  fi; \
	  rm -f "$$tmp"; \
	fi
	@for l in $(CODEX_LAUNCHERS); do \
	  install -m 0755 "$(CODEX_LAUNCHER_SOURCE)" "$(BINDIR)/$$l"; \
	  echo "launcher  -> $(BINDIR)/$$l"; \
	done
	@for h in $(CODEX_HELPERS); do \
	  install -m 0755 "codex/helpers/$$h" "$(BINDIR)/$$h"; \
	  echo "helper    -> $(BINDIR)/$$h"; \
	done
	@echo "done. ensure $(BINDIR) is on your PATH."

uninstall-codex:
	@for l in $(CODEX_LAUNCHERS); do \
	  rm -f "$(BINDIR)/$$l" && echo "removed $(BINDIR)/$$l"; \
	done
	@for h in $(CODEX_HELPERS); do \
	  rm -f "$(BINDIR)/$$h" && echo "removed $(BINDIR)/$$h"; \
	done
	@for p in $(CODEX_PROFILES); do \
	  rm -f "$(AGENTS_SHAREDIR)/codex/profiles/$$p" && echo "removed $(AGENTS_SHAREDIR)/codex/profiles/$$p"; \
	done
	@for c in $(CODEX_SESSION_CONFIGS); do \
	  rm -f "$(AGENTS_SHAREDIR)/codex/config/$$c" && echo "removed $(AGENTS_SHAREDIR)/codex/config/$$c"; \
	done
	@rm -f "$(AGENTS_SHAREDIR)/codex/rules/$(CODEX_RULES)" && echo "removed $(AGENTS_SHAREDIR)/codex/rules/$(CODEX_RULES)"
	@rm -f "$(CODEX_RULESDIR)/$(CODEX_RULES)" && echo "removed legacy $(CODEX_RULESDIR)/$(CODEX_RULES)"
	@if [ -f "$(CODEXHOME)/$(CODEX_DEFAULT_RULES)" ]; then \
	  tmp="$$(mktemp "$${TMPDIR:-/tmp}/agents-modes-rules.XXXXXX")" || exit 1; \
	  awk 'BEGIN { skip = 0 } /^# BEGIN agents-modes managed rules$$/ { skip = 1; next } /^# END agents-modes managed rules$$/ { skip = 0; next } skip == 0 { print }' "$(CODEXHOME)/$(CODEX_DEFAULT_RULES)" > "$$tmp" || exit 1; \
	  if grep -q '[^[:space:]]' "$$tmp"; then \
	    install -m 0644 "$$tmp" "$(CODEXHOME)/$(CODEX_DEFAULT_RULES)" || exit 1; \
	    echo "updated $(CODEXHOME)/$(CODEX_DEFAULT_RULES)"; \
	  else \
	    rm -f "$(CODEXHOME)/$(CODEX_DEFAULT_RULES)" && echo "removed $(CODEXHOME)/$(CODEX_DEFAULT_RULES)"; \
	  fi; \
	  rm -f "$$tmp"; \
	fi
	@rmdir "$(CODEX_RULESDIR)" "$(AGENTS_SHAREDIR)/codex/profiles" "$(AGENTS_SHAREDIR)/codex/config" "$(AGENTS_SHAREDIR)/codex/rules" "$(AGENTS_SHAREDIR)/codex" "$(AGENTS_SHAREDIR)" 2>/dev/null || true

reinstall-codex: uninstall-codex codex

list-codex:
	@echo "launchers (-> $(BINDIR)):" && printf '  %s\n' $(CODEX_LAUNCHERS)
	@echo "helpers   (-> $(BINDIR)):" && printf '  %s\n' $(CODEX_HELPERS)
	@echo "shared runtime: see list-shared-runtime"
	@echo "profiles  (-> $(AGENTS_SHAREDIR)/codex/profiles):" && printf '  %s\n' $(CODEX_PROFILES)
	@echo "configs   (-> $(AGENTS_SHAREDIR)/codex/config):" && printf '  %s\n' $(CODEX_SESSION_CONFIGS)
	@echo "profile fragment:" && printf '  codex/%s\n' $(CODEX_COMMON)
