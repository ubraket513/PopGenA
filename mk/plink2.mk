# Parallel build of PLINK 2 from the plink-ng 2.0 source tree. Run with
# `make -f mk/plink2.mk -C <plink-ng>/2.0 OPENBLAS=<prefix>`.
#
# Upstream's build_dynamic/Makefile compiles every file in one serial command.
# These rules use its source lists (Makefile.src) and reproduce its flags for
# the AVX2 build with bundled zstd/libdeflate, linked to static OpenBLAS.

include Makefile.src

CC  ?= gcc
CXX ?= g++
OBJDIR := build_popgena

BASEFLAGS := -DZSTD_MULTITHREAD -ffp-contract=off -mavx2 -mbmi -mbmi2 -mfma -mlzcnt \
             -DUSE_OPENBLAS -I$(OPENBLAS)/include
CFLAGS_P   := -O2 -std=gnu99 $(BASEFLAGS) $(CWARN2) -Ilibdeflate
ZCFLAGS_P  := -O2 -std=gnu99 $(BASEFLAGS) $(CWARN2)
CXXFLAGS_P := -std=c++17 -O2 $(BASEFLAGS) $(CXXWARN2) -Ilibdeflate

C_OBJ   := $(addprefix $(OBJDIR)/,$(CSRC:.c=.o))
Z_OBJ   := $(addprefix $(OBJDIR)/,$(ZCSRC:.c=.o) $(ZSSRC:.S=.o))
CXX_OBJ := $(addprefix $(OBJDIR)/,$(CCSRC:.cc=.o))

plink2: $(C_OBJ) $(Z_OBJ) $(CXX_OBJ) $(OBJDIR)/plink2_cpu.o
	$(CXX) $^ -o $@ $(OPENBLAS)/lib/libopenblas.a -fopenmp -lm -lpthread -lz

$(C_OBJ): $(OBJDIR)/%.o: %.c
	@mkdir -p $(@D)
	$(CC) $(CFLAGS_P) -c $< -o $@

$(OBJDIR)/zstd/%.o: zstd/%.c
	@mkdir -p $(@D)
	$(CC) $(ZCFLAGS_P) -c $< -o $@

$(OBJDIR)/zstd/%.o: zstd/%.S
	@mkdir -p $(@D)
	$(CC) $(ZCFLAGS_P) -c $< -o $@

$(CXX_OBJ): $(OBJDIR)/%.o: %.cc
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS_P) -c $< -o $@

# Upstream compiles the CPU check without the AVX2 flags so it can run anywhere.
$(OBJDIR)/plink2_cpu.o: plink2_cpu.cc
	@mkdir -p $(@D)
	$(CXX) -c $< -o $@
