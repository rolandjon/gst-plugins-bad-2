
plugin_LTLIBRARIES = libgstaudioresample.la

libgstaudioresample_la_SOURCES = gstaudioresample.c
libgstaudioresample_la_CFLAGS = $(GST_CFLAGS) $(AUDIORESAMPLE_CFLAGS)
libgstaudioresample_la_LIBADD = $(AUDIORESAMPLE_LIBS)
libgstaudioresample_la_LDFLAGS = $(GST_PLUGIN_LDFLAGS)
if !GST_PLUGIN_BUILD_STATIC
libgstaudioresample_la_LIBTOOLFLAGS = --tag=disable-static
endif

noinst_HEADERS = gstaudioresample.h

