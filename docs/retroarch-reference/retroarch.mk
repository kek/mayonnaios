################################################################################
#
# retroarch
#
################################################################################

RETROARCH_VERSION = v1.22.2
RETROARCH_SITE = $(call github,libretro,RetroArch,$(RETROARCH_VERSION))
RETROARCH_LICENSE = GPL-3.0-or-later
RETROARCH_LICENSE_FILES = COPYING
RETROARCH_DEPENDENCIES = \
	host-pkgconf \
	alsa-lib \
	freetype \
	libdrm \
	libegl \
	libgbm \
	libgles \
	sdl2 \
	zlib

# This is a generic-package, not an autotools-package, and that is not a
# stylistic choice. RetroArch's ./configure is libretro's hand-written "qb"
# script: qb/qb.params.sh opt_exists() ends in `die 1 "Unknown option"` for
# anything absent from qb/config.params.sh, and it understands only
# --prefix --sysconfdir --bindir --build --datarootdir --docdir --host
# --mandir. autotools-package would hand it --target, --localstatedir and
# --enable-shared and configure would abort on the first one.
#
# Every flag below is spelled the way qb/config.params.sh spells it AT THIS
# TAG, checked one by one against the v1.22.2 tarball. That list is not
# stable: Batocera's retroarch.mk passes --disable-builtinzlib, and
# HAVE_BUILTINZLIB was dropped from config.params.sh after 1.22.2, so lifting
# a newer or older option list verbatim aborts configure rather than quietly
# ignoring the flag. If you bump RETROARCH_VERSION, re-diff this list against
# qb/config.params.sh.
RETROARCH_CONF_OPTS = \
	--prefix=/usr \
	--host=$(GNU_TARGET_NAME) \
	--enable-threads \
	--enable-dynamic \
	--enable-zlib \
	--disable-builtinzlib \
	--enable-alsa \
	--enable-freetype \
	--enable-kms \
	--enable-egl \
	--enable-opengles \
	--enable-sdl2 \
	--enable-menu \
	--enable-rgui \
	--disable-materialui \
	--disable-ozone \
	--disable-xmb \
	--disable-opengl \
	--disable-opengles3 \
	--disable-vulkan \
	--disable-slang \
	--disable-glslang \
	--disable-spirv_cross \
	--disable-x11 \
	--disable-wayland \
	--disable-qt \
	--disable-sdl \
	--disable-oss \
	--disable-pulse \
	--disable-pipewire \
	--disable-udev \
	--disable-dbus \
	--disable-systemd \
	--disable-libusb \
	--disable-ffmpeg \
	--disable-mpv \
	--disable-v4l2 \
	--disable-cdrom \
	--disable-microphone \
	--disable-overlay \
	--disable-networking \
	--disable-ssl \
	--disable-cheevos \
	--disable-cheevos_rvz \
	--disable-discord \
	--disable-translate \
	--disable-accessibility \
	--disable-online_updater \
	--disable-update_cores \
	--disable-update_core_info \
	--disable-update_assets \
	--disable-langextra \
	--disable-parport \
	--disable-crtswitchres \
	--disable-neon

# --host is not here to find a compiler; $(TARGET_CONFIGURE_OPTS) sets CC and
# qb/qb.comp.sh:43 uses $CC directly when it is set. It is here because
# qb/config.libs.sh:20-22 reads
#
#     [ -z "$CROSS_COMPILE" ] && [ -d /usr/lib64 ] && add_dirs LIBRARY /usr/lib64
#     [ -z "$CROSS_COMPILE" ] && [ -d /opt/local/lib ] && add_dirs LIBRARY /opt/local/lib
#
# and CROSS_COMPILE is set by nothing but --host (qb/qb.params.sh:116). Without
# it, configure adds the BUILD machine's library directories to the link line.
# The value itself is never used to build a tool name here, so Buildroot's
# canonical GNU_TARGET_NAME is fine even though it is not the toolchain's own
# prefix.
#
# --disable-neon is deliberate on aarch64 and must not be "fixed". HAVE_NEON
# in Makefile.common:987-994 pulls in memory/neon/memcpy-neon.S and the
# *_neon.S resamplers, which are ARM32 assembly, and adds NEON_ASFLAGS
# (config.libs.sh:100-103 sets it to -mfpu=neon) that aarch64 gcc rejects.
# Batocera only sets --enable-neon under BR2_ARM_FPU_NEON*, all of which are
# 32-bit-only symbols.
#
# Ozone/XMB/MaterialUI are off because their artwork is not in the release
# tarball: media/assets is a git submodule, and `tar tzf` on
# retroarch-v1.22.2.tar.gz matches zero paths under media/assets. Enabling them
# would build menus that come up empty -- Makefile:284 skips the asset install
# with `test -d media/assets` and says nothing. RGUI is drawn from a built-in
# bitmap font, needs no assets, and is the right menu for a 640x480 panel
# anyway.
#
# slang/glslang/spirv_cross are off because they are the C++ half of the
# build and only feed the Vulkan/slang shader pipeline, which this board
# has no driver for.

# Mesa's EGL/eglplatform.h #includes <X11/Xlib.h> unless MESA_EGL_NO_X11_HEADERS
# or EGL_NO_X11 is defined, and there is no X11 anywhere in this system's
# staging tree. RetroArch never defines it itself -- grepping EGL_NO_X11 across
# the 1.22.2 tree matches zero files -- so without this the very first EGL probe
# (config.libs.sh:130, `check_header '' EGL EGL/egl.h EGL/eglext.h`) fails and
# HAVE_EGL comes out "no", which then drags KMS and OPENGLES down with it via
# the check_enabled lines at config.libs.sh:463 and :522. Buildroot itself uses
# the same define for non-X11 EGL: see package/mesa3d-demos's
# 0001-demos-makes-opengl-an-optional-component.patch and package/mali-t76x's
# egl.pc.
RETROARCH_EXTRA_CFLAGS = -DEGL_NO_X11

# PKG_CONF_PATH, not PKG_CONFIG. qb/qb.comp.sh:129 looks pkg-config up by name
# in $PATH and never reads Buildroot's PKG_CONFIG variable. $(HOST_DIR)/bin is
# first on BR_PATH so it would most likely find the sysroot-aware wrapper
# anyway -- but "most likely" here means the difference between probing
# $(STAGING_DIR)/usr/lib/pkgconfig and probing the build machine's, and the
# second one produces a configure summary that looks correct and a binary
# linked against libraries the device does not have.
#
# The CFLAGS/CXXFLAGS assignments deliberately come after
# $(TARGET_CONFIGURE_OPTS), which sets both: the later assignment in the
# command's environment prefix wins. Same shape as package/musl/musl.mk and
# package/berkeleydb/berkeleydb.mk upstream.
define RETROARCH_CONFIGURE_CMDS
	(cd $(@D); \
		rm -f config.log config.mk config.h; \
		$(TARGET_CONFIGURE_OPTS) \
		CFLAGS="$(TARGET_CFLAGS) $(RETROARCH_EXTRA_CFLAGS)" \
		CXXFLAGS="$(TARGET_CXXFLAGS) $(RETROARCH_EXTRA_CFLAGS)" \
		PKG_CONF_PATH="$(PKG_CONFIG_HOST_BINARY)" \
		./configure $(RETROARCH_CONF_OPTS) \
	)
endef

# configure writes CC, CXX, CFLAGS, LDFLAGS and INCLUDE_DIRS into config.mk
# (qb/qb.libs.sh create_config_make), so the build step only needs Buildroot's
# PATH -- passing TARGET_CONFIGURE_OPTS again here would be noise.
define RETROARCH_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)
endef

# The upstream install target (Makefile:258-283) also drops a desktop file, an
# AppStream metainfo XML, an SVG icon and a Python script (tools/cg2glsl.py,
# installed as retroarch-cg2glsl) into the target. There is no python and no
# desktop environment on this device. /usr/share/{man,doc} are removed by
# Buildroot's own target-finalize (Makefile:797,799), the rest are removed here.
#
# /usr/lib/libretro is created unconditionally so the directory RetroArch's
# core scan points at exists even in an image with no core packages -- an
# empty core list is a much clearer symptom than "directory not found".
define RETROARCH_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) DESTDIR=$(TARGET_DIR) install
	$(RM) $(TARGET_DIR)/usr/bin/retroarch-cg2glsl
	$(RM) -r $(TARGET_DIR)/usr/share/metainfo \
		$(TARGET_DIR)/usr/share/pixmaps \
		$(TARGET_DIR)/usr/share/applications
	$(INSTALL) -d -m 0755 $(TARGET_DIR)/usr/lib/libretro
endef

$(eval $(generic-package))
