# Native tool dependencies, built from the pinned upstream source archives in
# third_party/src. No network access: every archive is checked against
# third_party/src/SHA256SUMS before extraction.
#
# Layout (all ignored local state):
#   .deps/linux/src     extracted and built source trees
#   .deps/linux/prefix  static libraries, headers and the tool executables
#   .deps/linux/stamps  one file per completed step
#
# System prerequisites: gcc/g++, make, perl, and zlib/bzip2/liblzma headers.

ARCHIVES := third_party/src
DEPS     := $(CURDIR)/.deps/linux
DSRC     := $(DEPS)/src
PREFIX   := $(DEPS)/prefix
STAMP    := $(DEPS)/stamps
TOOLBIN  := $(PREFIX)/bin

HTSLIB_VER   := 1.24
BOWTIE2_VER  := 2.5.5
FASTP_VER    := 1.3.3
ISAL_VER     := 2.31.0
DEFLATE_VER  := 1.26
HWY_VER      := 1.4.0
NASM_VER     := 3.02
OPENBLAS_VER := 0.3.34
PLINK_COMMIT := 1c68b8c36591b9ccee0e7bbb7683f7f81264af7d
NINJA_VER    := 1.13.2
JQ_VER       := 1.8.1

# Static C libraries are linked into shared objects by some upstream builds.
DEP_CFLAGS := -O2 -fPIC

TOOLS := $(TOOLBIN)/ninja $(TOOLBIN)/jq $(TOOLBIN)/bcftools $(TOOLBIN)/samtools $(TOOLBIN)/plink2 $(TOOLBIN)/fastp \
         $(TOOLBIN)/bowtie2-align-s $(TOOLBIN)/bowtie2-align-s-v256 $(TOOLBIN)/bowtie2-build-s

.PHONY: deps deps-clean
deps: $(TOOLS)

deps-clean:
	rm -rf $(DEPS)

# One verification stamp per archive, so changing one archive rebuilds only its users.
archive = $(STAMP)/archive-$(1)
$(STAMP)/archive-%: $(ARCHIVES)/%
	@mkdir -p $(STAMP)
	cd $(ARCHIVES) && grep -E ' \*?$*$$' SHA256SUMS | sha256sum --check --quiet --strict
	@touch $@

# $(call extract,archive,directory-name)
define extract
	rm -rf $(DSRC)/$(2)
	@mkdir -p $(DSRC)
	tar -xf $(ARCHIVES)/$(1) -C $(DSRC)
endef

# ---- workflow executor ---------------------------------------------------------

# The workflow engine runs task graphs with Ninja. Upstream's configure.py needs
# Python, so its POSIX source list is compiled directly (re2c output is shipped).
NINJADIR := $(DSRC)/ninja-$(NINJA_VER)
NINJA_SOURCES := depfile_parser lexer build build_log clean clparser debug_flags deps_log \
  disk_interface dyndep dyndep_parser edit_distance elide_middle eval_env graph graphviz \
  jobserver json line_printer manifest_parser metrics missing_deps parser real_command_runner \
  state status_printer string_piece_util util version jobserver-posix subprocess-posix ninja
NINJA_OBJS := $(NINJA_SOURCES:%=$(NINJADIR)/obj/%.o)

$(STAMP)/ninja-src: $(call archive,ninja-$(NINJA_VER).tar.gz)
	$(call extract,ninja-$(NINJA_VER).tar.gz,ninja-$(NINJA_VER))
	@touch $@
$(NINJADIR)/src/%.cc: $(STAMP)/ninja-src ;
$(NINJADIR)/obj/%.o: $(NINJADIR)/src/%.cc
	@mkdir -p $(@D)
	$(CXX) -std=c++14 -O2 -DNDEBUG -fno-rtti -fno-exceptions -c $< -o $@
$(TOOLBIN)/ninja: $(NINJA_OBJS)
	@mkdir -p $(TOOLBIN)
	$(CXX) $^ -o $@

# JSON processor used by tools/*.sh and the integration tests; regex support comes
# from its bundled Oniguruma.
JQDIR := $(DSRC)/jq-$(JQ_VER)
$(TOOLBIN)/jq: $(call archive,jq-$(JQ_VER).tar.gz)
	$(call extract,jq-$(JQ_VER).tar.gz,jq-$(JQ_VER))
	cd $(JQDIR) && ./configure --quiet --with-oniguruma=builtin --disable-docs --disable-shared --enable-static
	$(MAKE) -C $(JQDIR)
	@mkdir -p $(TOOLBIN)
	cp $(JQDIR)/jq $@

# ---- compression libraries ---------------------------------------------------

$(STAMP)/nasm: $(call archive,nasm-$(NASM_VER).tar.xz)
	$(call extract,nasm-$(NASM_VER).tar.xz,nasm-$(NASM_VER))
	cd $(DSRC)/nasm-$(NASM_VER) && ./configure --quiet --prefix=$(DEPS)/host
	$(MAKE) -C $(DSRC)/nasm-$(NASM_VER) nasm
	@mkdir -p $(DEPS)/host/bin
	cp $(DSRC)/nasm-$(NASM_VER)/nasm $(DEPS)/host/bin/nasm
	@touch $@

$(STAMP)/isa-l: $(call archive,isa-l-$(ISAL_VER).tar.gz) $(STAMP)/nasm
	$(call extract,isa-l-$(ISAL_VER).tar.gz,isa-l-$(ISAL_VER))
	$(MAKE) -C $(DSRC)/isa-l-$(ISAL_VER) -f Makefile.unx lib AS=$(DEPS)/host/bin/nasm
	@mkdir -p $(PREFIX)/lib $(PREFIX)/include/isa-l
	cp $(DSRC)/isa-l-$(ISAL_VER)/bin/isa-l.a $(PREFIX)/lib/libisal.a
	cp $(DSRC)/isa-l-$(ISAL_VER)/include/*.h $(PREFIX)/include/isa-l/
	@touch $@

# libdeflate upstream builds with CMake; its library is plain C, so compile it directly.
$(STAMP)/libdeflate: $(call archive,libdeflate-$(DEFLATE_VER).tar.gz)
	$(call extract,libdeflate-$(DEFLATE_VER).tar.gz,libdeflate-$(DEFLATE_VER))
	cd $(DSRC)/libdeflate-$(DEFLATE_VER) && mkdir -p obj && \
	  for f in lib/*.c lib/x86/*.c; do \
	    $(CC) $(DEP_CFLAGS) -I. -c $$f -o obj/$$(echo $$f | tr / _).o || exit 1; \
	  done
	@mkdir -p $(PREFIX)/lib $(PREFIX)/include
	rm -f $(PREFIX)/lib/libdeflate.a
	ar rcs $(PREFIX)/lib/libdeflate.a $(DSRC)/libdeflate-$(DEFLATE_VER)/obj/*.o
	cp $(DSRC)/libdeflate-$(DEFLATE_VER)/libdeflate.h $(PREFIX)/include/
	@touch $@

# Highway's runtime library sources (the HWY_SOURCES list in its CMakeLists.txt).
HWY_SOURCES := abort aligned_allocator nanobenchmark per_target perf_counters print profiler stats targets timer
$(STAMP)/highway: $(call archive,highway-$(HWY_VER).tar.gz)
	$(call extract,highway-$(HWY_VER).tar.gz,highway-$(HWY_VER))
	cd $(DSRC)/highway-$(HWY_VER) && mkdir -p obj && \
	  for f in $(HWY_SOURCES); do \
	    $(CXX) -std=c++17 $(DEP_CFLAGS) -I. -c hwy/$$f.cc -o obj/$$f.o || exit 1; \
	  done
	@mkdir -p $(PREFIX)/lib
	rm -f $(PREFIX)/lib/libhwy.a
	ar rcs $(PREFIX)/lib/libhwy.a $(DSRC)/highway-$(HWY_VER)/obj/*.o
	@touch $@

# ---- HTSlib family -----------------------------------------------------------

HTSDIR := $(DSRC)/htslib-$(HTSLIB_VER)
$(STAMP)/htslib: $(call archive,htslib-$(HTSLIB_VER).tar.bz2) $(STAMP)/libdeflate
	$(call extract,htslib-$(HTSLIB_VER).tar.bz2,htslib-$(HTSLIB_VER))
	cd $(HTSDIR) && ./configure --quiet --disable-libcurl --disable-gcs --disable-s3 \
	  --with-libdeflate CFLAGS="$(DEP_CFLAGS)" CPPFLAGS=-I$(PREFIX)/include LDFLAGS=-L$(PREFIX)/lib
	$(MAKE) -C $(HTSDIR) lib-static
	@touch $@

# $(call hts_tool,name,extra-configure-args)
define hts_tool
$(TOOLBIN)/$(1): $(STAMP)/htslib $$(call archive,$(1)-$(HTSLIB_VER).tar.bz2)
	$$(call extract,$(1)-$(HTSLIB_VER).tar.bz2,$(1)-$(HTSLIB_VER))
	cd $(DSRC)/$(1)-$(HTSLIB_VER) && ./configure --quiet --with-htslib=$(HTSDIR) $(2) \
	  CPPFLAGS=-I$(PREFIX)/include LDFLAGS=-L$(PREFIX)/lib
	$$(MAKE) -C $(DSRC)/$(1)-$(HTSLIB_VER) $(1)
	@mkdir -p $(TOOLBIN)
	cp $(DSRC)/$(1)-$(HTSLIB_VER)/$(1) $$@
endef
$(eval $(call hts_tool,bcftools,))
$(eval $(call hts_tool,samtools,--without-curses))

# ---- PLINK 2 with OpenBLAS (--pca requires LAPACK) ---------------------------

# NOFORTRAN + C_LAPACK: no gfortran runtime dependency. PLINK 2 calls single and
# double precision BLAS/LAPACK only (cblas_s*/d*, sgeqrf_, sorgqr_, LAPACK_d*),
# so the complex variants are not built.
OPENBLAS_OPTS := USE_OPENMP=1 NO_SHARED=1 NOFORTRAN=1 C_LAPACK=1 NUM_THREADS=64 \
                 BUILD_SINGLE=1 BUILD_DOUBLE=1 $(OPENBLAS_FLAGS)
$(STAMP)/openblas: $(call archive,OpenBLAS-$(OPENBLAS_VER).tar.gz)
	$(call extract,OpenBLAS-$(OPENBLAS_VER).tar.gz,OpenBLAS-$(OPENBLAS_VER))
	$(MAKE) -C $(DSRC)/OpenBLAS-$(OPENBLAS_VER) $(OPENBLAS_OPTS)
	rm -rf $(DEPS)/openblas
	$(MAKE) -C $(DSRC)/OpenBLAS-$(OPENBLAS_VER) install PREFIX=$(DEPS)/openblas $(OPENBLAS_OPTS)
	@touch $@

# Upstream compiles PLINK 2 serially; mk/plink2.mk builds the same sources in parallel.
PLINKSRC := $(DSRC)/plink-ng-$(PLINK_COMMIT)/2.0
$(TOOLBIN)/plink2: $(call archive,plink-ng-1c68b8c.tar.gz) $(STAMP)/openblas mk/plink2.mk
	$(call extract,plink-ng-1c68b8c.tar.gz,plink-ng-$(PLINK_COMMIT))
	$(MAKE) -C $(PLINKSRC) -f $(CURDIR)/mk/plink2.mk plink2 CC=$(CC) CXX=$(CXX) OPENBLAS=$(DEPS)/openblas
	@mkdir -p $(TOOLBIN)
	cp $(PLINKSRC)/plink2 $@

# ---- raw reads ---------------------------------------------------------------

FASTPDIR := $(DSRC)/fastp-$(FASTP_VER)
$(TOOLBIN)/fastp: $(call archive,fastp-$(FASTP_VER).tar.gz) $(STAMP)/isa-l $(STAMP)/libdeflate $(STAMP)/highway
	$(call extract,fastp-$(FASTP_VER).tar.gz,fastp-$(FASTP_VER))
	$(MAKE) -C $(FASTPDIR) \
	  HWY_CFLAGS=-I$(DSRC)/highway-$(HWY_VER) ISAL_CFLAGS=-I$(PREFIX)/include \
	  DEFLATE_CFLAGS=-I$(PREFIX)/include \
	  LD_FLAGS="$(PREFIX)/lib/libisal.a $(PREFIX)/lib/libdeflate.a $(PREFIX)/lib/libhwy.a -pthread"
	@mkdir -p $(TOOLBIN)
	cp $(FASTPDIR)/fastp $@

# The -s aligner re-executes itself as <argv0>-v256 on x86-64-v3 CPUs, so both
# variants are installed side by side.
BT2DIR := $(DSRC)/bowtie2-$(BOWTIE2_VER)
$(STAMP)/bowtie2: $(call archive,bowtie2-$(BOWTIE2_VER).tar.gz)
	$(call extract,bowtie2-$(BOWTIE2_VER).tar.gz,bowtie2-$(BOWTIE2_VER))
	$(MAKE) -C $(BT2DIR) bowtie2-align-s bowtie2-align-s-v256 bowtie2-build-s
	@mkdir -p $(TOOLBIN)
	cp $(BT2DIR)/bowtie2-align-s $(BT2DIR)/bowtie2-align-s-v256 $(BT2DIR)/bowtie2-build-s $(TOOLBIN)/
	@touch $@
$(TOOLBIN)/bowtie2-align-s $(TOOLBIN)/bowtie2-align-s-v256 $(TOOLBIN)/bowtie2-build-s: $(STAMP)/bowtie2
