# variables used for enum/marshal generation
glib_enum_define = GST_HLS_DEMUX
glib_gen_prefix = gst_hls_demux
glib_gen_basename = gsthlsdemux

built_sources = gsthlsdemux-marshal.c
built_headers = gsthlsdemux-marshal.h

plugin_LTLIBRARIES = libgstfragmented.la

libgstfragmented_la_SOURCES =			\
	m3u8.c					\
	gsthlsdemux.c				\
	gstfragment.c				\
	gsturidownloader.c			\
	gsthlsadaptation.c			\
	gstfragmentedplugin.c

nodist_libgstfragmented_la_SOURCES = $(built_sources)
libgstfragmented_la_CFLAGS = $(GST_CFLAGS) $(GST_BASE_CFLAGS) $(SOUP_CFLAGS)
libgstfragmented_la_LIBADD = $(GST_LIBS) $(GST_BASE_LIBS) $(SOUP_LIBS) $(HLS_LIBS)
libgstfragmented_la_LDFLAGS = $(GST_PLUGIN_LDFLAGS) -no-undefined
if !GST_PLUGIN_BUILD_STATIC
libgstfragmented_la_LIBTOOLFLAGS = --tag=disable-static
endif

# headers we need but don't want installed
noinst_HEADERS = 			\
	gstfragmented.h		\
	gstfragment.h				\
	gsthlsdemux.h			\
	gsturidownloader.h			\
	gsthlsadaptation.h				\
	m3u8.h

BUILT_SOURCES = $(built_headers) $(built_sources)

EXTRA_DIST = gstplay-marshal.list

CLEANFILES = $(BUILT_SOURCES)

include $(top_srcdir)/common/gst-glib-gen.mak

Android.mk: Makefile.am $(BUILT_SOURCES)
	androgenizer \
	-:PROJECT libgsthls -:SHARED libgsthls \
	 -:TAGS eng debug \
         -:REL_TOP $(top_srcdir) -:ABS_TOP $(abs_top_srcdir) \
	 -:SOURCES $(libgsthls_la_SOURCES) \
	 -:CFLAGS $(DEFS) $(DEFAULT_INCLUDES) $(libgsthls_la_CFLAGS) \
	 -:LDFLAGS $(libgsthls_la_LDFLAGS) \
	           $(libgsthls_la_LIBADD) \
	           -ldl \
	 -:PASSTHROUGH LOCAL_ARM_MODE:=arm \
		       LOCAL_MODULE_PATH:='$$(TARGET_OUT)/lib/gstreamer-0.10' \
	> $@
