# tmbox - a private Time Machine destination on Hetzner.
#
# Everything here runs with the tools a stock Mac already has. If a target needs
# something from Homebrew it says so and degrades rather than failing.

SHELL := /bin/zsh
ROOT  := $(CURDIR)

# The Mac half of the product runs under /bin/zsh, so the tooling runs it too.
# A check that passes under a Homebrew zsh and fails under Apple's 5.9 is a
# check that did not run. The appliance half is bash on Debian and is linted
# separately, by extension - see tools/lint.zsh.
ZSH := /bin/zsh

VERSION := $(shell cat VERSION)

.DEFAULT_GOAL := help

.PHONY: help lint test check dist demo demo-tty clean version \
        test-tty check-all vm-up vm-serve vm-ssh vm-down

help: ## Show this help
	@printf '\033[1mtmbox %s\033[0m\n\n' '$(VERSION)'
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@printf '\n'

version: ## Print the version
	@echo '$(VERSION)'

# --- static and unit --------------------------------------------------------

lint: ## Syntax and pattern checks, per interpreter
	@$(ZSH) $(ROOT)/tools/lint.zsh

test: ## Unit tests, under /bin/zsh
	@$(ZSH) $(ROOT)/test/run-tests.zsh

test-tty: ## Interactive tests, driven through a real pty
	@$(ZSH) $(ROOT)/test/run-tty-tests.zsh

check: lint test ## lint + unit tests (fast; the loop you run while editing)

check-all: check test-tty ## everything, including the pty tests

# --- distribution -----------------------------------------------------------

dist: check-all ## Build the single-file dist/tmbox.zsh and its SHA-256
	@$(ZSH) $(ROOT)/tools/build.zsh

demo: ## Render every TUI widget, to review the interface without provisioning
	@$(ZSH) $(ROOT)/tools/ui-demo.zsh

demo-tty: ## The same, with real prompts, for checking the interactive path
	@$(ZSH) $(ROOT)/tools/ui-demo.zsh --interactive

clean: ## Remove build output
	@rm -f $(ROOT)/dist/tmbox.zsh $(ROOT)/dist/tmbox.zsh.sha256
	@echo "cleaned"

# --- the macOS guest --------------------------------------------------------
#
# The real proof that this works on a stock Mac: no Homebrew, no Xcode tools,
# Apple's own zsh, and a Full Disk Access grant that cannot be scripted - which
# is why the guest is reused and never deleted.

vm-up: ## Boot the Tart macOS guest
	@$(ZSH) $(ROOT)/tools/vm.zsh up

vm-serve: dist ## Serve dist/ over HTTP so the guest can curl | zsh it
	@$(ZSH) $(ROOT)/tools/vm.zsh serve

vm-ssh: ## Shell into the guest
	@$(ZSH) $(ROOT)/tools/vm.zsh ssh

vm-down: ## Stop the guest (never delete it - it is a 27 GB pull)
	@$(ZSH) $(ROOT)/tools/vm.zsh down
