plugin_LTLIBRARIES = libgstpcapparse.la

# when compiling for windows we need to link with the winsock library
if HAVE_WINSOCK2_H
  WINSOCK2_LIBS = -lws2_32
else
  WINSOCK2_LIBS = 
endif

libgstpcapparse_la_SOURCES = \
	gstpcapparse.c gstirtspparse.c plugin.c

noinst_HEADERS = \
	gstpcapparse.h gstirtspparse.h

libgstpcapparse_la_CFLAGS = $(GST_CFLAGS) $(GST_BASE_CFLAGS)
libgstpcapparse_la_LIBADD = $(GST_LIBS) $(GST_BASE_LIBS) $(WINSOCK2_LIBS)
libgstpcapparse_la_LDFLAGS = $(GST_PLUGIN_LDFLAGS)
if !GST_PLUGIN_BUILD_STATIC
libgstpcapparse_la_LIBTOOLFLAGS = --tag=disable-static
endif

Android.mk: Makefile.am $(BUILT_SOURCES)
	androgenizer \
	-:PROJECT libgstpcapparse -:SHARED libgstpcapparse \
	 -:TAGS eng debug \
         -:REL_TOP $(top_srcdir) -:ABS_TOP $(abs_top_srcdir) \
	 -:SOURCES $(libgstpcapparse_la_SOURCES) \
	 -:CFLAGS $(DEFS) $(DEFAULT_INCLUDES) $(libgstpcapparse_la_CFLAGS) \
	 -:LDFLAGS $(libgstpcapparse_la_LDFLAGS) \
	           $(libgstpcapparse_la_LIBADD) \
	           -ldl \
	 -:PASSTHROUGH LOCAL_ARM_MODE:=arm \
		       LOCAL_MODULE_PATH:='$$(TARGET_OUT)/lib/gstreamer-0.10' \
	> $@
