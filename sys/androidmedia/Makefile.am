plugin_LTLIBRARIES = libgstandroidmedia.la

libgstandroidmedia_la_SOURCES = \
	gstaudiotracksink.c \
	gstamc.c \
	gstamcdrm.c \
	gstamcaudiodec.c \
	gstamcvideodec.c \
	gstamcvideosink.c \
	video/video.c \
	video/gstvideodecoder.c \
	video/gstvideoencoder.c \
	video/gstvideoutils.c

noinst_HEADERS = \
	gstaudiotracksink.h \
	gstamc.h \
	gstamcdrm.h \
	gstamc-constants.h \
	gstamcaudiodec.h \
	gstamcvideodec.h \
	gstamcvideosink.h \
	video/video.h \
	video/gstvideodecoder.h \
	video/gstvideoencoder.h \
	video/gstvideoutils.h

libgstandroidmedia_la_CFLAGS = \
	-Wall -Werror -Wno-deprecated-declarations \
	-I$(srcdir) \
	-I$(top_srcdir)/gst-libs \
	$(GST_PLUGINS_BASE_CFLAGS) \
	$(GST_BASE_CFLAGS) \
	$(GST_CFLAGS) \
	$(ORC_CFLAGS) \
	$(FLUC_CFLAGS) \
	$(CURL_CFLAGS)

libgstandroidmedia_la_LIBADD = \
	$(GST_PLUGINS_BASE_LIBS) \
	-lgstaudio-@GST_MAJORMINOR@ \
	-lgstpbutils-@GST_MAJORMINOR@ \
	-lgstvideo-@GST_MAJORMINOR@ \
	$(top_builddir)/gst-libs/gst/androidjni/libgstandroidjni-$(GST_MAJORMINOR).la \
	$(GST_BASE_LIBS) \
	$(GST_LIBS) \
	$(ORC_LIBS) \
	$(FLUC_LIBS) \
	$(CURL_LIBS)


libgstandroidmedia_la_LDFLAGS = $(GST_PLUGIN_LDFLAGS)
libgstandroidmedia_la_LIBTOOLFLAGS = --tag=disable-static

EXTRA_DIST = $(VIDEO_BASE_CLASSES_C) $(VIDEO_BASE_CLASSES_H)

Android.mk: Makefile.am $(BUILT_SOURCES)
	androgenizer \
	-:PROJECT libgstandroidmedia -:SHARED libgstandroidmedia \
	 -:TAGS eng debug \
         -:REL_TOP $(top_srcdir) -:ABS_TOP $(abs_top_srcdir) \
	 -:SOURCES $(libgstandroidmedia_la_SOURCES) \
	           $(nodist_libgstandroidmedia_la_SOURCES) \
	 -:CFLAGS $(DEFS) $(DEFAULT_INCLUDES) $(libgstandroidmedia_la_CFLAGS) \
	 -:LDFLAGS $(libgstandroidmedia_la_LDFLAGS) \
	           $(libgstandroidmedia_la_LIBADD) \
	           -ldl \
	 -:PASSTHROUGH LOCAL_ARM_MODE:=arm \
		       LOCAL_MODULE_PATH:='$$(TARGET_OUT)/lib/gstreamer-@GST_MAJOR_MINOR@' \
	> $@
