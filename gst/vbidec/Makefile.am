
plugin_LTLIBRARIES = libgstvbidec.la

libgstvbidec_la_SOURCES = gstvbidec.h gstvbidec.c \
	vbidata.h vbidata.c \
	vbiscreen.h vbiscreen.c
libgstvbidec_la_CFLAGS = $(GST_CFLAGS)
libgstvbidec_la_LDFLAGS = $(GST_PLUGIN_LDFLAGS)
if !GST_PLUGIN_BUILD_STATIC
libgstvbidec_la_LIBTOOLFLAGS = --tag=disable-static
endif

