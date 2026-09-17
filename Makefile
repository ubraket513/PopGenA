# PopGenA — Linux build.
#
# `make` builds every external tool from the pinned source archives in third_party/src
# (offline, see mk/deps.mk) and then the application, using every core.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DELETE_ON_ERROR:
.DEFAULT_GOAL := all

NPROC := $(shell nproc)
ifeq (,$(filter -j%,$(MAKEFLAGS)))
  MAKEFLAGS += -j$(NPROC)
endif

CC  := gcc
CXX := g++

include mk/deps.mk

# ---- application --------------------------------------------------------------------

BUILD    := build
OBJ      := $(BUILD)/obj
CXXFLAGS := -std=c++20 -O2 -Wall -Wextra -Wpedantic -Isrc -isystem third_party -isystem $(HTSDIR) -MMD -MP
LDLIBS   := $(HTSDIR)/libhts.a $(PREFIX)/lib/libdeflate.a -lz -lbz2 -llzma -lcrypto -lpthread -lm

LIB_SRCS  := $(filter-out src/app/main.cpp src/tools/%,$(wildcard src/*/*.cpp))
TEST_SRCS := $(wildcard tests/unit/*.cpp)
ALL_SRCS  := $(wildcard src/*/*.cpp) $(TEST_SRCS) tests/helpers/process_helper.cpp
obj = $(patsubst %.cpp,$(OBJ)/%.o,$(1))

LIBRARY  := $(BUILD)/libpopgen.a
BINARIES := $(BUILD)/popgen $(BUILD)/tests $(BUILD)/process-helper $(BUILD)/benchmark-fixture $(BUILD)/region-ranges

.PHONY: all app tools deps test verify check run plan workflow genotype-plan genotype reads-plan reads \
        benchmark doctor format format-check lint clean help
all: deps app tools compile_commands.json
app: $(BUILD)/popgen
tools: $(BUILD)/benchmark-fixture $(BUILD)/region-ranges

$(OBJ)/%.o: %.cpp $(STAMP)/htslib
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(LIBRARY): $(call obj,$(LIB_SRCS))
	rm -f $@
	ar rcs $@ $^

$(BUILD)/popgen: $(call obj,src/app/main.cpp) $(LIBRARY)
	$(CXX) $^ -o $@ $(LDLIBS)
$(BUILD)/tests: $(call obj,$(TEST_SRCS)) $(LIBRARY)
	$(CXX) $^ -o $@ $(LDLIBS)
$(BUILD)/process-helper: $(call obj,tests/helpers/process_helper.cpp) $(LIBRARY)
	$(CXX) $^ -o $@ $(LDLIBS)
$(BUILD)/benchmark-fixture: $(call obj,src/tools/benchmark_fixture.cpp) $(LIBRARY)
	$(CXX) $^ -o $@ $(LDLIBS)
$(BUILD)/region-ranges: $(call obj,src/tools/region_ranges.cpp) $(LIBRARY)
	$(CXX) $^ -o $@ $(LDLIBS)

-include $(patsubst %.cpp,$(OBJ)/%.d,$(ALL_SRCS))

# clangd/Serena compile database, regenerated when sources are added or flags change.
compile_commands.json: Makefile $(ALL_SRCS)
	@{ printf '['; sep=''; \
	   for f in $(ALL_SRCS); do \
	     printf '%s\n  {"directory": "%s", "file": "%s", "command": "%s %s -c %s"}' "$$sep" "$(CURDIR)" "$$f" "$(CXX)" "$(CXXFLAGS)" "$$f"; sep=','; \
	   done; printf '\n]\n'; } > $@

# ---- tests ------------------------------------------------------------------------------

INTEGRATION := stats workflow mask genotype acquisition reads

test: $(BUILD)/tests $(BUILD)/process-helper
	$(BUILD)/tests

verify: deps $(BUILD)/popgen $(BUILD)/process-helper
	@for suite in $(INTEGRATION); do echo "== $$suite"; bash tests/integration/$$suite.sh || exit 1; done

# Sequential: the workflow suite measures pool overlap, so it must not share the CPU with unit tests.
check:
	@$(MAKE) --no-print-directory test
	@$(MAKE) --no-print-directory verify

# ---- demos and measurements ------------------------------------------------------------

OUT    ?= out/demo
CONFIG ?= config/workflow-demo.json
run: app
	$(BUILD)/popgen stats --input tests/data/fixtures/cohort.vcf --samples tests/data/fixtures/samples.tsv --out "$(OUT)" --replace
plan: deps app
	$(BUILD)/popgen plan --config "$(CONFIG)"
workflow: deps app
	$(BUILD)/popgen run --config "$(CONFIG)"
genotype-plan genotype reads-plan reads: deps app
	$(BUILD)/popgen $(if $(findstring plan,$@),plan,run) --config config/$(firstword $(subst -, ,$@))-demo.json

SAMPLES ?= 1000
SITES   ?= 1000
benchmark: deps app $(BUILD)/benchmark-fixture
	scripts/benchmark/benchmark.sh --samples $(SAMPLES) --sites $(SITES)

doctor: deps app
	@for t in $(TOOLS); do printf '%-24s ' "$${t##*/}"; "$$t" --version 2>&1 | head -1; done
	@$(BUILD)/popgen doctor

# ---- code quality (optional tools: clang-format, shellcheck) -------------------------------

CPP_FILES   := $(wildcard src/*/*.cpp src/*/*.hpp tests/unit/*.cpp tests/helpers/*.cpp)
SHELL_FILES := $(wildcard scripts/*/*.sh tests/integration/*.sh tests/generators/*.sh)

format:
	clang-format -i $(CPP_FILES)
format-check:
	clang-format --dry-run -Werror $(CPP_FILES)
lint:
	shellcheck --severity=warning $(SHELL_FILES)

clean:
	rm -rf $(OBJ) $(LIBRARY) $(BINARIES)

help:
	@echo 'make                   build vendored dependencies, build/popgen and tools (offline)'
	@echo 'make test              unit tests'
	@echo 'make check             unit tests + all offline integration suites'
	@echo 'make run               statistics demo into OUT=out/demo'
	@echo 'make plan|workflow     review / execute CONFIG=config/workflow-demo.json'
	@echo 'make genotype[-plan]   synthetic genotype QC/PCA demo'
	@echo 'make reads[-plan]      synthetic FASTQ-to-genotype demo'
	@echo 'make benchmark         streaming statistics benchmark (SAMPLES=, SITES=)'
	@echo 'make doctor            dependency versions and popgen tool resolution'
	@echo 'make format[-check]    apply / check .clang-format (needs clang-format)'
	@echo 'make lint              shellcheck all scripts (needs shellcheck)'
	@echo 'make clean             remove application build outputs (not .deps, work or out)'
	@echo 'make deps-clean        remove .deps/linux (rebuilt by the next make)'
