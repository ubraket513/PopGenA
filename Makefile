# PopGenA Linux build. `make` builds every native dependency from the vendored
# sources in third_party/src, then the popgen application, offline, using every core.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DELETE_ON_ERROR:

NPROC := $(shell nproc)
ifeq (,$(filter -j%,$(MAKEFLAGS)))
  MAKEFLAGS += -j$(NPROC)
endif

CC  := gcc
CXX := g++

.PHONY: all app format test verify check run plan workflow genotype-plan genotype reads-plan reads benchmark validation-tools doctor clean compile-commands help
all: deps app compile-commands

include mk/deps.mk

# ---- application ---------------------------------------------------------------

CXXFLAGS := -std=c++20 -O2 -Wall -Wextra -Wpedantic -Isrc -isystem third_party -isystem $(HTSDIR) -MMD -MP
LDLIBS   := $(HTSDIR)/libhts.a $(PREFIX)/lib/libdeflate.a -lz -lbz2 -llzma -lcrypto -lpthread -lm

CORE_OBJS := build/stats.o build/platform.o build/process.o
APP_OBJS  := build/main.o $(CORE_OBJS) build/workflow.o build/genotype.o build/genotype_mask.o build/reads.o
BINARIES  := build/popgen build/tests build/process-helper build/benchmark-fixture build/region-ranges

app: build/popgen

build/%.o: src/%.cpp $(STAMP)/htslib | build/.dir
	$(CXX) $(CXXFLAGS) -c $< -o $@
build/test.o build/process_helper.o build/benchmark_fixture.o: build/%.o: tests/%.cpp $(STAMP)/htslib | build/.dir
	$(CXX) $(CXXFLAGS) -c $< -o $@
build/region_ranges.o: tools/region_ranges.cpp $(STAMP)/htslib | build/.dir
	$(CXX) $(CXXFLAGS) -c $< -o $@
build/.dir:
	@mkdir -p build && touch $@

build/popgen: $(APP_OBJS)
	$(CXX) $^ -o $@ $(LDLIBS)
build/tests: build/test.o $(CORE_OBJS)
	$(CXX) $^ -o $@ $(LDLIBS)
build/process-helper: build/process_helper.o $(CORE_OBJS)
	$(CXX) $^ -o $@ $(LDLIBS)
build/benchmark-fixture: build/benchmark_fixture.o $(CORE_OBJS)
	$(CXX) $^ -o $@ $(LDLIBS)
build/region-ranges: build/region_ranges.o $(CORE_OBJS)
	$(CXX) $^ -o $@ $(LDLIBS)

-include $(wildcard build/*.d)

test: build/tests build/process-helper
	build/tests

# Offline integration suites (bash + vendored tools); each prints its artifact directory.
INTEGRATION := integration workflow mask genotype acquisition reads
verify: deps app build/process-helper
	@for suite in $(INTEGRATION); do echo "== $$suite"; bash tests/$$suite.sh || exit 1; done
# Sequential: the workflow suite measures pool overlap, so it should not share the CPU with unit tests.
check:
	@$(MAKE) --no-print-directory test
	@$(MAKE) --no-print-directory verify

# Offline demos; CONFIG selects another workflow for plan/workflow.
OUT    ?= out/demo
CONFIG ?= config/workflow-demo.json
run: app
	build/popgen stats --input tests/fixtures/cohort.vcf --samples tests/fixtures/samples.tsv --out "$(OUT)" --replace
plan: deps app
	build/popgen plan --config "$(CONFIG)"
workflow: deps app
	build/popgen run --config "$(CONFIG)"
genotype-plan genotype reads-plan reads: deps app
	build/popgen $(if $(findstring plan,$@),plan,run) --config config/$(firstword $(subst -, ,$@))-demo.json

# SAMPLES/SITES default to a small run; 100000/10000 is the recorded scale measurement.
SAMPLES ?= 1000
SITES   ?= 1000
benchmark: deps app build/benchmark-fixture
	tools/benchmark.sh --samples $(SAMPLES) --sites $(SITES)
validation-tools: build/benchmark-fixture build/region-ranges

# clangd/Serena compile database for every C++ source, regenerated when this file changes.
compile-commands: compile_commands.json
compile_commands.json: Makefile
	@{ printf '['; sep=''; \
	   for f in src/*.cpp tests/*.cpp tools/*.cpp; do \
	     printf '%s\n  {"directory": "%s", "file": "%s", "command": "%s %s -c %s"}' "$$sep" "$(CURDIR)" "$$f" "$(CXX)" "$(CXXFLAGS)" "$$f"; sep=','; \
	   done; printf '\n]\n'; } > $@

# Optional: apply .clang-format when clang-format is installed (not a build dependency).
format:
	@command -v clang-format >/dev/null || { echo 'clang-format not found (e.g. uvx clang-format)' >&2; exit 1; }
	clang-format -i src/*.cpp src/*.hpp tests/*.cpp tools/*.cpp

doctor: deps app
	@for t in $(TOOLS); do printf '%-24s ' "$${t##*/}"; "$$t" --version 2>&1 | head -1; done
	@build/popgen doctor

clean:
	rm -f $(BINARIES) build/*.o build/*.d build/.dir

help:
	@echo 'make                   build vendored dependencies and build/popgen (offline)'
	@echo 'make test              unit tests'
	@echo 'make check             unit tests + all offline integration suites'
	@echo 'make run               statistics demo into OUT=out/demo'
	@echo 'make plan|workflow     review / execute CONFIG=config/workflow-demo.json'
	@echo 'make genotype[-plan]   synthetic genotype QC/PCA demo'
	@echo 'make reads[-plan]      synthetic FASTQ-to-genotype demo'
	@echo 'make benchmark         streaming statistics benchmark (SAMPLES=, SITES=)'
	@echo 'make doctor            dependency versions and popgen tool resolution'
	@echo 'make format            apply .clang-format (optional, needs clang-format)'
	@echo 'make clean             remove application build outputs (not .deps, work or out)'
	@echo 'make deps-clean        remove .deps/linux (rebuilt by the next make)'
