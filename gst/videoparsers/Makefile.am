plugin_LTLIBRARIES = libgstvideoparsersbad.la

libgstvideoparsersbad_la_SOURCES = plugin.c \
	h263parse.c gsth263parse.c \
	gstdiracparse.c dirac_parse.c \
	gsth264parse.c gsth265parse.c \
	gstmpegvideoparse.c gstmpeg4videoparse.c

libgstvideoparsersbad_la_CFLAGS = \
	-Wall -Werror \
	$(GST_PLUGINS_BAD_CFLAGS) $(GST_PLUGINS_BASE_CFLAGS) \
	-DGST_USE_UNSTABLE_API \
	$(GST_BASE_CFLAGS) $(GST_CFLAGS) $(FLUC_CFLAGS)\
	-Dschro_video_format_set_std_video_format=gst_videoparsers_schro_video_format_set_std_video_format\
	-Dschro_video_format_set_std_frame_rate=gst_videoparsers_schro_video_format_set_std_frame_rate\
	-Dschro_video_format_set_std_aspect_ratio=gst_videoparsers_schro_video_format_set_std_aspect_ratio\
	-Dschro_video_format_set_std_signal_range=gst_videoparsers_schro_video_format_set_std_signal_range\
	-Dschro_video_format_set_std_colour_spec=gst_videoparsers_schro_video_format_set_std_colour_spec \
	-Ddirac_sequence_header_parse=gst_videoparsers_dirac_sequence_header_parse

libgstvideoparsersbad_la_LIBADD = \
	$(top_builddir)/gst-libs/gst/codecparsers/libgstcodecparsers-$(GST_MAJORMINOR).la \
	$(GST_PLUGINS_BASE_LIBS) -lgstpbutils-$(GST_MAJORMINOR) -lgstvideo-$(GST_MAJORMINOR) \
	$(GST_BASE_LIBS) $(GST_LIBS) $(FLUC_LIBS)
libgstvideoparsersbad_la_LDFLAGS = $(GST_PLUGIN_LDFLAGS)
if !GST_PLUGIN_BUILD_STATIC
libgstvideoparsersbad_la_LIBTOOLFLAGS = --tag=disable-static
endif

noinst_HEADERS = gsth263parse.h h263parse.h \
	gstdiracparse.h dirac_parse.h \
	gsth264parse.h gsth265parse.h \
	gstmpegvideoparse.h gstmpeg4videoparse.h

Android.mk: Makefile.am $(BUILT_SOURCES)
	androgenizer \
	-:PROJECT libgstvideoparsersbad -:SHARED libgstvideoparsersbad \
	 -:TAGS eng debug \
         -:REL_TOP $(top_srcdir) -:ABS_TOP $(abs_top_srcdir) \
	 -:SOURCES $(libgstvideoparsersbad_la_SOURCES) \
	 -:CFLAGS $(DEFS) $(DEFAULT_INCLUDES) $(libgstvideoparsersbad_la_CFLAGS) \
	 -:LDFLAGS $(libgstvideoparsersbad_la_LDFLAGS) \
	           $(libgstvideoparsersbad_la_LIBADD) \
	           -ldl \
	 -:LIBFILTER_STATIC gstbaseparse-@GST_MAJORMINOR@ \
	                    gstcodecparsers-@GST_MAJORMINOR@ \
	 -:PASSTHROUGH LOCAL_ARM_MODE:=arm \
		       LOCAL_MODULE_PATH:='$$(TARGET_OUT)/lib/gstreamer-0.10' \
	> $@
