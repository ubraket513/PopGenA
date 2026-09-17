SHELL := cmd.exe
.SHELLFLAGS := /c
NPROC ?= 4
OUT ?= out/demo
CONFIG ?= config/workflow-demo.json
NINJA := .deps/ucrt64/bin/ninja.exe
.PHONY: all bootstrap test verify check run doctor plan workflow genotype-plan genotype clean help compile-commands
all:
	@"$(NINJA)" -j$(NPROC)
bootstrap:
	@powershell -NoProfile -ExecutionPolicy Bypass -File tools/bootstrap.ps1
test: all
	@"$(NINJA)" -j$(NPROC) build/tests.exe
	@build\tests.exe
verify: all
	@"$(NINJA)" -j$(NPROC) build/process-helper.exe
	@powershell -NoProfile -ExecutionPolicy Bypass -File tests/integration.ps1
	@powershell -NoProfile -ExecutionPolicy Bypass -File tests/workflow.ps1
	@powershell -NoProfile -ExecutionPolicy Bypass -File tests/mask.ps1
	@powershell -NoProfile -ExecutionPolicy Bypass -File tests/genotype.ps1
	@powershell -NoProfile -ExecutionPolicy Bypass -File tests/acquisition.ps1
check: test verify
run: all
	@build\popgen.exe stats --input tests/fixtures/cohort.vcf --samples tests/fixtures/samples.tsv --out "$(OUT)" --replace
doctor: all
	@build\popgen.exe doctor
plan: all
	@build\popgen.exe plan --config "$(CONFIG)"
workflow: all
	@build\popgen.exe run --config "$(CONFIG)"
genotype-plan: all
	@build\popgen.exe plan --config config/genotype-demo.json
genotype: all
	@build\popgen.exe run --config config/genotype-demo.json
clean:
	@"$(NINJA)" -t clean
compile-commands:
	@powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$(NINJA)' -t compdb cxx | Set-Content -Encoding utf8 compile_commands.json"
help:
	@echo make: build; check: unit and integration tests; run: offline demo
	@echo plan: review workflow; workflow: execute/resume; CONFIG=path/to/config.json
	@echo genotype-plan: review offline QC/PCA demo; genotype: execute/resume it
	@echo bootstrap: explicit dependency download; doctor: tool report
	@echo clean: compilation outputs only; compile-commands: editor metadata
