# One entrypoint, so the git hooks, the humans and the agents all run the same
# commands. The Linux toolchain (Rust, GTK) joins here when linux/ has code
# (docs/plans/001_native_clients_on_system_git.md) -- a target with no code
# behind it is a promise nobody is keeping.

PRETTIER ?= npx --yes --prefer-offline prettier@latest
# swift-format ships with Xcode, so the Mac app adds no tool of its own.
SWIFT_SRC = macos/Package.swift macos/make-icon.swift macos/Sources macos/Tests
SWIFT_FORMAT = xcrun swift-format

.PHONY: help init fmt lint test check mac fixtures lint-docs lint-macos test-macos

help:
	@echo 'init      install git hooks, verify the agent symlink, point agent memory at docs/memory'
	@echo 'fmt       rewrite files -- the only target that edits anything'
	@echo 'lint      prettier --check, swift-format'
	@echo 'test      the macOS unit tests'
	@echo 'check     lint test -- what pre-push and CI run'
	@echo 'mac       build Upstream.app (arm64), signed ad hoc, and archive it in local/'
	@echo 'fixtures  regenerate fixtures/git/ from the installed git'

# Writes the one setting that cannot be committed: autoMemoryDirectory takes an
# absolute path, so it lives in the git-ignored settings.local.json while the
# directory it points at is tracked and reviewed like any other doc. An
# existing file is never overwritten -- the maintainer's other local settings
# are theirs.
init:
	git config core.hooksPath .githooks
	@[ -L CLAUDE.md ] || ln -sf AGENTS.md CLAUDE.md
	@echo 'agent symlink verified (CLAUDE.md)'
	@if [ -f .claude/settings.local.json ]; then \
		echo 'note: .claude/settings.local.json exists, leaving it alone'; \
		echo '      it must set "autoMemoryDirectory" to $(CURDIR)/docs/memory'; \
	else \
		printf '{\n  "autoMemoryDirectory": "%s/docs/memory"\n}\n' '$(CURDIR)' \
			> .claude/settings.local.json; \
		echo 'wrote .claude/settings.local.json -> docs/memory'; \
	fi
	@echo 'hooks installed -> .githooks'

fmt:
	$(PRETTIER) --write .
	$(SWIFT_FORMAT) format -i -r $(SWIFT_SRC)

lint: lint-docs lint-macos

lint-docs:
	$(PRETTIER) --check .

lint-macos:
	$(SWIFT_FORMAT) lint --strict -r $(SWIFT_SRC)

test: test-macos

test-macos:
	cd macos && swift test

check: lint test

mac:
	scripts/build-mac.sh

fixtures:
	scripts/make-fixtures.sh
