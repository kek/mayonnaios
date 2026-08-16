################################################################################
#
# libretro-2048
#
################################################################################

LIBRETRO_2048_VERSION = c90437d3c3913999624deca3fb55ecfa632b72c4
LIBRETRO_2048_SITE = $(call github,libretro,libretro-2048,$(LIBRETRO_2048_VERSION))
LIBRETRO_2048_LICENSE = Unlicense
LIBRETRO_2048_LICENSE_FILES = COPYING

# No _DEPENDENCIES on retroarch on purpose. The core links against nothing but
# -lm and has no build-time relationship to the frontend, and `install -D`
# creates /usr/lib/libretro whichever package's install step runs first, so
# adding one would only serialise the build behind a much larger package.
# Config.in's `depends on BR2_PACKAGE_RETROARCH` is what keeps a core from
# being shipped with no frontend to load it.
#
# Cores are plain shared objects built by a libretro Makefile; there is no
# configure step. Makefile.libretro is the right makefile -- the bare
# `Makefile` in this repo is the MSVC one (CC=cl, TARGET=2048_libretro.dll).
#
# platform=unix must be passed explicitly. Left unset, Makefile.libretro:4-14
# guesses from `uname -s` on the BUILD machine, and only platform=unix selects
# -fPIC, -shared -Wl,--no-undefined and the .so extension (Makefile.libretro:65-69).
#
# Nothing to link but -lm: Makefile.common builds libretro.c,
# game_noncairo.c, game_shared.c and a handful of libretro-common files.
# The core's cairo/ and pixman/ subtrees are only used by the MSVC build.
#
# TARGET_CONFIGURE_OPTS carries GIT_DIR=. from TARGET_MAKE_ENV, which makes
# Makefile.libretro:36's `git rev-parse --short HEAD || echo unknown` fail the
# same way on every machine, so GIT_VERSION lands on " unknown" and
# -DGIT_VERSION is left out consistently. That matters here because
# BR2_REPRODUCIBLE=y is set in nerves_defconfig.
define LIBRETRO_2048_BUILD_CMDS
	$(TARGET_CONFIGURE_OPTS) $(MAKE) -C $(@D) -f Makefile.libretro platform=unix
endef

define LIBRETRO_2048_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/2048_libretro.so \
		$(TARGET_DIR)/usr/lib/libretro/2048_libretro.so
endef

$(eval $(generic-package))
