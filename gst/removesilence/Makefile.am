
plugin_LTLIBRARIES = libgstremovesilence.la

libgstremovesilence_la_SOURCES = gstremovesilence.c vad_private.c
libgstremovesilence_la_CFLAGS = $(GST_PLUGINS_BASE_CFLAGS) $(GST_CFLAGS)
libgstremovesilence_la_LIBADD = $(GST_PLUGINS_BASE_LIBS) $(GST_BASE_LIBS) $(GST_LIBS)
libgstremovesilence_la_LDFLAGS = $(GST_PLUGIN_LDFLAGS)
if !GST_PLUGIN_BUILD_STATIC
libgstremovesilence_la_LIBTOOLFLAGS = --tag=disable-static
endif

noinst_HEADERS = \
	gstremovesilence.h \
	vad_private.h
