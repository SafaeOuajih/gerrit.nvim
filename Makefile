.PHONY: test lint fmt

# The suites stub out git and ssh, so they run offline and touch no server.
test:
	@for spec in tests/*_spec.lua; do \
		echo "--- $$spec"; \
		nvim --clean --headless -l $$spec || exit 1; \
	done

lint:
	selene lua plugin tests

fmt:
	stylua lua plugin tests
