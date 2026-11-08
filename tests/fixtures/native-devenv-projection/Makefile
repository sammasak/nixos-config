.PHONY: check
check:
	printf '%s\n' "guest-check:$(PROJECT_NATIVE_MARKER):$(PROJECT_NATIVE_IMPORT)" > check.result
	grep -q 'guest-check:generated-devenv-environment:generated-devenv-import' check.result
