/*
 * Copyright (C) 2010 Ole André Vadla Ravnås <oravnas@cisco.com>
 * Copyright (C) 2018 Fluendo SA <ngarcia@fluendo.com>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public
 * License along with this library; if not, write to the
 * Free Software Foundation, Inc., 59 Temple Place - Suite 330,
 * Boston, MA 02111-1307, USA.
 */

#include "avfvideosrc.h"
#include "coremediabuffer.h"

#import <AVFoundation/AVFoundation.h>
#include <gst/video/video.h>
#include <gst/interfaces/propertyprobe.h>

#define DEFAULT_DEVICE_INDEX  -1
#define DEFAULT_DO_STATS      FALSE

#define DEVICE_FPS_N          25
#define DEVICE_FPS_D          1

#define BUFFER_QUEUE_SIZE     2

GST_DEBUG_CATEGORY (gst_avf_video_src_debug);
#define GST_CAT_DEFAULT gst_avf_video_src_debug

static GstStaticPadTemplate src_template = GST_STATIC_PAD_TEMPLATE ("src",
  GST_PAD_SRC,
  GST_PAD_ALWAYS,
  GST_STATIC_CAPS ("video/x-raw-yuv, "
  "format = (fourcc) { NV12, UYVY, YUY2 }, "
  "framerate = " GST_VIDEO_FPS_RANGE ", "
  "width = " GST_VIDEO_SIZE_RANGE ", "
  "height = " GST_VIDEO_SIZE_RANGE "; "

  "video/x-raw-rgb, "
  "bpp = (int) 32, "
  "depth = (int) 32, "                                        \
  "endianness = (int) BIG_ENDIAN, "
  "red_mask = (int) " GST_VIDEO_BYTE3_MASK_32 ", "
  "green_mask = (int) " GST_VIDEO_BYTE2_MASK_32 ", "
  "blue_mask = (int) " GST_VIDEO_BYTE1_MASK_32 ", "
  "alpha_mask = (int) " GST_VIDEO_BYTE4_MASK_32 ", "
  "framerate = " GST_VIDEO_FPS_RANGE ", "
  "width = " GST_VIDEO_SIZE_RANGE ", "
  "height = " GST_VIDEO_SIZE_RANGE "; "
  ));

typedef enum _QueueState {
  NO_BUFFERS = 1,
  HAS_BUFFER_OR_STOP_REQUEST,
} QueueState;

static GstPushSrcClass * parent_class;

@interface GstAVFVideoSrcImpl : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
{
  GstElement *element;
  GstBaseSrc *baseSrc;
  GstPushSrc *pushSrc;

  gint deviceIndex;
  gchar *deviceName;
  BOOL doStats;

  AVCaptureSession *session;
  AVCaptureInput *input;
  AVCaptureVideoDataOutput *output;
  AVCaptureDevice *device;

  dispatch_queue_t mainQueue;
  dispatch_queue_t workerQueue;
  NSConditionLock *bufQueueLock;
  NSMutableArray *bufQueue;
  BOOL stopRequest;

  GstCaps *caps;
  GstVideoFormat format;
  gint width, height;
  gint fps_n, fps_d;
  GstClockTime duration;
  guint64 offset;

  GstClockTime lastSampling;
  guint count;
  gint fps;

  BOOL useVideoMeta;
}

- (id)init;
- (id)initWithSrc:(GstPushSrc *)src;
- (void)finalize;

@property int deviceIndex;
@property gchar* deviceName;
@property BOOL doStats;
@property int fps;

+ (NSArray*) listDevices;
- (BOOL)openScreenInput;
- (BOOL)openDeviceInput;
- (BOOL)openDevice;
- (void)closeDevice;
- (GstVideoFormat)getGstVideoFormat:(NSNumber *)pixel_format;
- (BOOL)getDeviceCaps:(GstCaps *)result;
- (BOOL)setDeviceCaps;
- (BOOL)getSessionPresetCaps:(GstCaps *)result;
- (BOOL)setSessionPresetCaps;
- (GstCaps *)getCaps;
- (BOOL)setCaps:(GstCaps *)new_caps;
- (BOOL)start;
- (BOOL)stop;
- (BOOL)unlock;
- (BOOL)unlockStop;
- (BOOL)query:(GstQuery *)query;
- (GstStateChangeReturn)changeState:(GstStateChange)transition;
- (GstFlowReturn)create:(GstBuffer **)buf;
- (void)timestampBuffer:(GstBuffer *)buf;
- (void)updateStatistics;
- (void)captureOutput:(AVCaptureOutput *)captureOutput
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
    fromConnection:(AVCaptureConnection *)connection;

@end

@implementation GstAVFVideoSrcImpl

@synthesize deviceIndex, deviceName, doStats, fps;

- (id)init
{
  return [self initWithSrc:NULL];
}

- (id)initWithSrc:(GstPushSrc *)src
{
  if ((self = [super init])) {
    element = GST_ELEMENT_CAST (src);
    baseSrc = GST_BASE_SRC_CAST (src);
    pushSrc = src;

    deviceIndex = DEFAULT_DEVICE_INDEX;
    deviceName = NULL;
    useVideoMeta = NO;

    mainQueue =
        dispatch_queue_create ("org.freedesktop.gstreamer.avfvideosrc.main",
      NULL);
    workerQueue =
        dispatch_queue_create ("org.freedesktop.gstreamer.avfvideosrc.output",
      NULL);

    gst_base_src_set_live (baseSrc, TRUE);
    gst_base_src_set_format (baseSrc, GST_FORMAT_TIME);
  }

  return self;
}

- (void)finalize
{
  dispatch_release (mainQueue);
  mainQueue = NULL;
  dispatch_release (workerQueue);
  workerQueue = NULL;
  if (deviceName != NULL) {
    g_free (deviceName);
    deviceName = NULL;
  }

  [super finalize];
}

+ (NSArray *)listDevices
{
  return [[AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]
         arrayByAddingObjectsFromArray:[AVCaptureDevice devicesWithMediaType:
         AVMediaTypeMuxed]];
}

- (BOOL)openDeviceInput
{
  NSString *mediaType = AVMediaTypeVideo;
  NSError *err;

  device = NULL;
  if (deviceName != NULL) {
    NSArray *devices = [GstAVFVideoSrcImpl listDevices];
    for (AVCaptureDevice *dev in devices) {
      gchar *name = (gchar*) [[dev localizedName] UTF8String];
      if (!g_strcmp0 (name, deviceName)) {
        device = dev;
        break;
      }
    }
    if (device == nil) {
      GST_ELEMENT_ERROR (element, RESOURCE, NOT_FOUND,
          ("No video capture devices found"), (NULL));
      return NO;
    }
  } else if (deviceIndex == -1) {
    device = [AVCaptureDevice defaultDeviceWithMediaType:mediaType];
    if (device == nil) {
      GST_ELEMENT_ERROR (element, RESOURCE, NOT_FOUND,
          ("No video capture devices found"), (NULL));
      return NO;
    }
  } else {
    NSArray *devices = [GstAVFVideoSrcImpl listDevices];
    if (deviceIndex >= [devices count]) {
      GST_ELEMENT_ERROR (element, RESOURCE, NOT_FOUND,
          ("Invalid video capture device index"), (NULL));
      return NO;
    }
    device = [devices objectAtIndex:deviceIndex];
  }
  g_assert (device != nil);
  [device retain];

  GST_INFO ("Opening '%s'", [[device localizedName] UTF8String]);

  input = [AVCaptureDeviceInput deviceInputWithDevice:device
      error:&err];
  if (input == nil) {
    GST_ELEMENT_ERROR (element, RESOURCE, BUSY,
        ("Failed to open device: %s",
        [[err localizedDescription] UTF8String]),
        (NULL));
    [device release];
    device = nil;
    return NO;
  }
  [input retain];
  return YES;
}


- (BOOL)openDevice
{
  BOOL success = NO, *successPtr = &success;

  GST_DEBUG_OBJECT (element, "Opening device");

  dispatch_sync (mainQueue, ^{

    if (![self openDeviceInput])
      return;

    output = [[AVCaptureVideoDataOutput alloc] init];
    [output setSampleBufferDelegate:self
    queue:workerQueue];
    output.alwaysDiscardsLateVideoFrames = YES;
    output.videoSettings = nil; /* device native format */

    session = [[AVCaptureSession alloc] init];
    [session addInput:input];
    [session addOutput:output];

    *successPtr = YES;
  });

  GST_DEBUG_OBJECT (element, "Opening device %s",
      success ? "succeed" : "failed");

  return success;
}

- (void)closeDevice
{
  GST_DEBUG_OBJECT (element, "Closing device");

  dispatch_sync (mainQueue, ^{
    g_assert (![session isRunning]);

    [session removeInput:input];
    [session removeOutput:output];

    [session release];
    session = nil;

    [input release];
    input = nil;

    [output release];
    output = nil;

    if (caps)
      gst_caps_unref (caps);
  });
}

- (GstVideoFormat)getGstVideoFormat:(NSNumber *)pixel_format
{
  GstVideoFormat gst_format = GST_VIDEO_FORMAT_UNKNOWN;

  switch ([pixel_format integerValue]) {
  case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: /* 420v */
    gst_format = GST_VIDEO_FORMAT_NV12;
    break;
  case kCVPixelFormatType_422YpCbCr8: /* 2vuy */
    gst_format = GST_VIDEO_FORMAT_UYVY;
    break;
  case kCVPixelFormatType_32BGRA: /* BGRA */
    gst_format = GST_VIDEO_FORMAT_BGRA;
    break;
  case kCVPixelFormatType_422YpCbCr8_yuvs: /* yuvs */
    gst_format = GST_VIDEO_FORMAT_YUY2;
    break;
  default:
    GST_LOG_OBJECT (element, "Pixel format %s is not handled by avfvideosrc",
      [[pixel_format stringValue] UTF8String]);
    break;
  }

  return gst_format;
}

- (BOOL)getDeviceCaps:(GstCaps *)result
{
  NSArray *formats = [device valueForKey:@"formats"];
  NSArray *pixel_formats = output.availableVideoCVPixelFormatTypes;

  GST_DEBUG_OBJECT (element, "Getting device caps");

  /* Do not use AVCaptureDeviceFormat or AVFrameRateRange only
   * available in iOS >= 7.0. We use a dynamic approach with key-value
   * coding or performSelector */
  for (NSObject *f in [formats reverseObjectEnumerator]) {
    CMFormatDescriptionRef formatDescription;
    CMMediaType mediaType;
    CMVideoDimensions dimensions;

    /* formatDescription can't be retrieved with valueForKey so use a selector
       here */
    formatDescription =
        (CMFormatDescriptionRef) [f performSelector:@selector(formatDescription)
        ];
    mediaType = CMFormatDescriptionGetMediaType (formatDescription);
    if (mediaType == kCMMediaType_Video) {
      dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
      for (NSObject *rate in [f valueForKey:@"videoSupportedFrameRateRanges"]) {
        int _fps_n, _fps_d;
        gdouble max_fps;

        [[rate valueForKey:@"maxFrameRate"] getValue:&max_fps];
        gst_util_double_to_fraction (max_fps, &_fps_n, &_fps_d);

        for (NSNumber *pixel_format in pixel_formats) {
          GstVideoFormat gst_format = [self getGstVideoFormat:pixel_format];
          if (gst_format != GST_VIDEO_FORMAT_UNKNOWN)
            gst_caps_append (result,
                gst_video_format_new_caps (gst_format, dimensions.width,
                dimensions.height, _fps_n, _fps_d, 1, 1));
        }
      }
    } else if (mediaType == kCMMediaType_Muxed) {
      FourCharCode subtype;

      subtype = CMFormatDescriptionGetMediaSubType (formatDescription);

      if (subtype == kCMMuxedStreamType_DV) {
        gst_caps_append (result,
            gst_caps_from_string ("video/x-raw-yuv, "
            "format=(fourcc)NV12, "
            "framerate=25/1,width=768,height=576"));
        gst_caps_append (result,
            gst_caps_from_string ("video/x-raw-yuv, "
            "format=(fourcc)NV12, "
            "framerate=30000/1001,width=640,height=480"));
      }
    }
  }
  GST_LOG_OBJECT (element,
      "Device returned the following caps %" GST_PTR_FORMAT,
      result);
  GST_LOG_OBJECT (element, "Device returned the following caps %s", gst_caps_to_string (
      result));
  return YES;
}

- (BOOL)setDeviceCaps
{
  double framerate;
  gboolean found_format = FALSE, found_framerate = FALSE;
  NSArray *formats = [device valueForKey:@"formats"];

  gst_util_fraction_to_double (fps_n, fps_d, &framerate);

  GST_DEBUG_OBJECT (element, "Setting device caps");

  if ([device lockForConfiguration:NULL] == YES) {
    for (NSObject *f in formats) {
      CMFormatDescriptionRef formatDescription;
      CMMediaType mediaType;
      CMVideoDimensions dimensions;

      formatDescription =
          (CMFormatDescriptionRef) [f performSelector:@selector(
            formatDescription)
          ];
      mediaType = CMFormatDescriptionGetMediaType (formatDescription);
      if (mediaType == kCMMediaType_Video) {
        dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
        if (dimensions.width == width && dimensions.height == height) {
          found_format = TRUE;
          [device setValue:f forKey:@"activeFormat"];
          for (NSObject *rate in [f valueForKey:
              @"videoSupportedFrameRateRanges"]) {
            gdouble max_frame_rate;

            [[rate valueForKey:@"maxFrameRate"] getValue:&max_frame_rate];
            if (abs (framerate - max_frame_rate) < 0.00001) {
              NSValue *min_frame_duration, *max_frame_duration;

              found_framerate = TRUE;
              min_frame_duration = [rate valueForKey:@"minFrameDuration"];
              max_frame_duration = [rate valueForKey:@"maxFrameDuration"];
              [device setValue:min_frame_duration forKey:
              @"activeVideoMinFrameDuration"];
              @try {
                /* Only available on OSX >= 10.8 and iOS >= 7.0 */
                [device setValue:max_frame_duration forKey:
                @"activeVideoMaxFrameDuration"];
              } @catch (NSException *exception) {
                if (![[exception name] isEqualToString:NSUndefinedKeyException])
                {
                  GST_WARNING ("An unexcepted error occured: %s",
                      [exception.reason UTF8String]);
                }
              }
              break;
            }
          }
        }
      } else if (mediaType == kCMMediaType_Muxed) {
        found_format = TRUE;
        found_framerate = TRUE;
        break;
      }
    }
    if (!found_format) {
      GST_WARNING ("Unsupported capture dimensions %dx%d", width, height);
      return NO;
    }
    if (!found_framerate) {
      GST_WARNING ("Unsupported capture framerate %d/%d", fps_n, fps_d);
      return NO;
    }
  } else {
    GST_WARNING ("Couldn't lock device for configuration");
    return NO;
  }
  return YES;
}

- (BOOL)getSessionPresetCaps:(GstCaps *)result
{
  NSArray *pixel_formats = output.availableVideoCVPixelFormatTypes;
  for (NSNumber *pixel_format in pixel_formats) {
    GstVideoFormat gst_format = [self getGstVideoFormat:pixel_format];
    if (gst_format == GST_VIDEO_FORMAT_UNKNOWN)
      continue;

#if HAVE_IOS
    if ([session canSetSessionPreset:AVCaptureSessionPreset1920x1080])
      gst_caps_append (result,
          gst_video_format_new_caps (gst_format, 1920, 1080, DEVICE_FPS_N,
          DEVICE_FPS_D, 1, 1));
#endif
    if ([session canSetSessionPreset:AVCaptureSessionPreset1280x720])
      gst_caps_append (result,
          gst_video_format_new_caps (gst_format, 1280, 720, DEVICE_FPS_N,
          DEVICE_FPS_D, 1, 1));
    if ([session canSetSessionPreset:AVCaptureSessionPreset640x480])
      gst_caps_append (result,
          gst_video_format_new_caps (gst_format, 640, 480, DEVICE_FPS_N,
          DEVICE_FPS_D, 1, 1));
    if ([session canSetSessionPreset:AVCaptureSessionPresetMedium])
      gst_caps_append (result,
          gst_video_format_new_caps (gst_format, 480, 360, DEVICE_FPS_N,
          DEVICE_FPS_D, 1, 1));
    if ([session canSetSessionPreset:AVCaptureSessionPreset352x288])
      gst_caps_append (result,
          gst_video_format_new_caps (gst_format, 352, 288, DEVICE_FPS_N,
          DEVICE_FPS_D, 1, 1));
    if ([session canSetSessionPreset:AVCaptureSessionPresetLow])
      gst_caps_append (result,
          gst_video_format_new_caps (gst_format, 192, 144, DEVICE_FPS_N,
          DEVICE_FPS_D, 1, 1));
  }

  GST_LOG_OBJECT (element,
      "Session presets returned the following caps %" GST_PTR_FORMAT,
      result);

  return YES;
}

- (BOOL)setSessionPresetCaps
{
  GST_DEBUG_OBJECT (element, "Setting session presset caps");

  if ([device lockForConfiguration:NULL] != YES) {
    GST_WARNING ("Couldn't lock device for configuration");
    return NO;
  }

  switch (width) {
  case 192:
    session.sessionPreset = AVCaptureSessionPresetLow;
    break;
  case 352:
    session.sessionPreset = AVCaptureSessionPreset352x288;
    break;
  case 480:
    session.sessionPreset = AVCaptureSessionPresetMedium;
    break;
  case 640:
    session.sessionPreset = AVCaptureSessionPreset640x480;
    break;
  case 1280:
    session.sessionPreset = AVCaptureSessionPreset1280x720;
    break;
#if HAVE_IOS
  case 1920:
    session.sessionPreset = AVCaptureSessionPreset1920x1080;
    break;
#endif
  default:
    GST_WARNING ("Unsupported capture dimensions %dx%d", width, height);
    return NO;
  }
  return YES;
}

- (GstCaps *)getCaps
{
  GstCaps *result;
  NSArray *pixel_formats;

  if (session == nil)
    return NULL; /* BaseSrc will return template caps */

  result = gst_caps_new_empty ();
  pixel_formats = output.availableVideoCVPixelFormatTypes;

  @try {

    [self getDeviceCaps:result];

  } @catch (NSException *exception) {

    if (![[exception name] isEqualToString:NSUndefinedKeyException]) {
      GST_WARNING ("An unexcepted error occured: %s",
          [exception.reason UTF8String]);
      return result;
    }

    /* Fallback on session presets API for iOS < 7.0 */
    [self getSessionPresetCaps:result];
  }

  return result;
}

- (BOOL)setCaps:(GstCaps *)new_caps
{
  BOOL success = YES, *successPtr = &success;

  gst_video_format_parse_caps (new_caps, &format, &width, &height);
  gst_video_parse_caps_framerate (new_caps, &fps_n, &fps_d);

  dispatch_sync (mainQueue, ^{
    int newformat;

    g_assert (![session isRunning]);

    @try {

      /* formats and activeFormat keys are only available on OSX >= 10.7 and iOS
         >= 7.0 */
      *successPtr = [self setDeviceCaps];
      if (*successPtr != YES)
        return;

    } @catch (NSException *exception) {

      if (![[exception name] isEqualToString:NSUndefinedKeyException]) {
        GST_WARNING ("An unexcepted error occured: %s",
        [exception.reason UTF8String]);
        *successPtr = NO;
        return;
      }

      /* Fallback on session presets API for iOS < 7.0 */
      *successPtr = [self setSessionPresetCaps];
      if (*successPtr != YES)
        return;
    }

    switch (format) {
    case GST_VIDEO_FORMAT_NV12:
      newformat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
      break;
    case GST_VIDEO_FORMAT_UYVY:
      newformat = kCVPixelFormatType_422YpCbCr8;
      break;
    case GST_VIDEO_FORMAT_YUY2:
      newformat = kCVPixelFormatType_422YpCbCr8_yuvs;
      break;
    case GST_VIDEO_FORMAT_BGRA:
      newformat = kCVPixelFormatType_32BGRA;
      break;
    default:
      *successPtr = NO;
      GST_WARNING ("Unsupported output format %d", format);
      return;
    }

    GST_DEBUG_OBJECT(element,
    "Width: %d Height: %d Format: %" GST_FOURCC_FORMAT,
    width, height,
    GST_FOURCC_ARGS (gst_video_format_to_fourcc (format)));

    output.videoSettings = [NSDictionary
    dictionaryWithObject:[NSNumber numberWithInt:newformat]
    forKey:(NSString*)kCVPixelBufferPixelFormatTypeKey];

    caps = gst_caps_copy (new_caps);
    [session startRunning];

    /* Unlock device configuration only after session is started so the session
     * won't reset the capture formats */
    [device unlockForConfiguration];
  });

  return success;
}

- (BOOL)start
{
  bufQueueLock = [[NSConditionLock alloc] initWithCondition:NO_BUFFERS];
  bufQueue = [[NSMutableArray alloc] initWithCapacity:BUFFER_QUEUE_SIZE];
  stopRequest = NO;

  duration = gst_util_uint64_scale (GST_SECOND, DEVICE_FPS_D, DEVICE_FPS_N);
  offset = 0;

  lastSampling = GST_CLOCK_TIME_NONE;
  count = 0;
  fps = -1;

  return YES;
}

- (BOOL)stop
{
  dispatch_sync (mainQueue, ^{ [session stopRunning]; });
  dispatch_sync (workerQueue, ^{});

  [bufQueueLock release];
  bufQueueLock = nil;
  [bufQueue release];
  bufQueue = nil;

  return YES;
}

- (BOOL)query:(GstQuery *)query
{
  BOOL result = NO;

  if (GST_QUERY_TYPE (query) == GST_QUERY_LATENCY) {
    if (device != nil) {
      GstClockTime min_latency, max_latency;

      min_latency = max_latency = duration; /* for now */
      result = YES;

      GST_DEBUG_OBJECT (element, "reporting latency of min %" GST_TIME_FORMAT
          " max %" GST_TIME_FORMAT,
          GST_TIME_ARGS (min_latency), GST_TIME_ARGS (max_latency));
      gst_query_set_latency (query, TRUE, min_latency, max_latency);
    }
  } else {
    result = GST_BASE_SRC_CLASS (parent_class)->query (baseSrc, query);
  }

  return result;
}

- (BOOL)unlock
{
  [bufQueueLock lock];
  stopRequest = YES;
  [bufQueueLock unlockWithCondition:HAS_BUFFER_OR_STOP_REQUEST];

  return YES;
}

- (BOOL)unlockStop
{
  [bufQueueLock lock];
  stopRequest = NO;
  [bufQueueLock unlock];

  return YES;
}

- (GstStateChangeReturn)changeState:(GstStateChange)transition
{
  GstStateChangeReturn ret;

  if (transition == GST_STATE_CHANGE_NULL_TO_READY) {
    if (![self openDevice])
      return GST_STATE_CHANGE_FAILURE;
  }

  ret = GST_ELEMENT_CLASS (parent_class)->change_state (element, transition);

  if (transition == GST_STATE_CHANGE_READY_TO_NULL)
    [self closeDevice];

  return ret;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
    fromConnection:(AVCaptureConnection *)connection
{
  [bufQueueLock lock];

  if (stopRequest) {
    [bufQueueLock unlock];
    return;
  }

  if ([bufQueue count] == BUFFER_QUEUE_SIZE)
    [bufQueue removeLastObject];

  [bufQueue insertObject:(id)sampleBuffer
  atIndex:0];

  [bufQueueLock unlockWithCondition:HAS_BUFFER_OR_STOP_REQUEST];
}

- (GstFlowReturn)create:(GstBuffer **)buf
{
  CMSampleBufferRef sbuf;
  CVImageBufferRef image_buf;
  CVPixelBufferRef pixel_buf;
  size_t cur_width, cur_height;

  [bufQueueLock lockWhenCondition:HAS_BUFFER_OR_STOP_REQUEST];
  if (stopRequest) {
    [bufQueueLock unlock];
    return GST_FLOW_WRONG_STATE;
  }

  sbuf = (CMSampleBufferRef) [bufQueue lastObject];
  CFRetain (sbuf);
  [bufQueue removeLastObject];
  [bufQueueLock unlockWithCondition:
  ([bufQueue count] == 0) ? NO_BUFFERS : HAS_BUFFER_OR_STOP_REQUEST];

  /* Check output frame size dimensions */
  image_buf = CMSampleBufferGetImageBuffer (sbuf);
  if (image_buf) {
    pixel_buf = (CVPixelBufferRef) image_buf;
    cur_width = CVPixelBufferGetWidth (pixel_buf);
    cur_height = CVPixelBufferGetHeight (pixel_buf);

    if (width != cur_width || height != cur_height) {
      /* Set new caps according to current frame dimensions */
      GST_WARNING (
          "Output frame size has changed %dx%d -> %dx%d, updating caps",
          width, height, (int)cur_width, (int)cur_height);
      width = cur_width;
      height = cur_height;
      gst_caps_set_simple (caps,
          "width", G_TYPE_INT, width,
          "height", G_TYPE_INT, height,
          NULL);
      gst_pad_set_caps (GST_BASE_SRC_PAD (baseSrc), caps);
    }
  }

  *buf = gst_core_media_buffer_new (sbuf);
  CFRelease (sbuf);

  [self timestampBuffer:*buf];

  if (doStats)
    [self updateStatistics];

  return GST_FLOW_OK;
}

- (void)timestampBuffer:(GstBuffer *)buf
{
  GstClock *clock;
  GstClockTime timestamp;

  GST_OBJECT_LOCK (element);
  clock = GST_ELEMENT_CLOCK (element);
  if (clock != NULL) {
    gst_object_ref (clock);
    timestamp = element->base_time;
  } else {
    timestamp = GST_CLOCK_TIME_NONE;
  }
  GST_OBJECT_UNLOCK (element);

  if (clock != NULL) {
    timestamp = gst_clock_get_time (clock) - timestamp;
    if (timestamp > duration)
      timestamp -= duration;
    else
      timestamp = 0;

    gst_object_unref (clock);
    clock = NULL;
  }

  GST_BUFFER_OFFSET (buf) = offset++;
  GST_BUFFER_OFFSET_END (buf) = GST_BUFFER_OFFSET (buf) + 1;
  GST_BUFFER_TIMESTAMP (buf) = timestamp;
  GST_BUFFER_DURATION (buf) = duration;
}

- (void)updateStatistics
{
  GstClock *clock;

  GST_OBJECT_LOCK (element);
  clock = GST_ELEMENT_CLOCK (element);
  if (clock != NULL)
    gst_object_ref (clock);
  GST_OBJECT_UNLOCK (element);

  if (clock != NULL) {
    GstClockTime now = gst_clock_get_time (clock);
    gst_object_unref (clock);

    count++;

    if (GST_CLOCK_TIME_IS_VALID (lastSampling)) {
      if (now - lastSampling >= GST_SECOND) {
        GST_OBJECT_LOCK (element);
        fps = count;
        GST_OBJECT_UNLOCK (element);

        g_object_notify (G_OBJECT (element), "fps");

        lastSampling = now;
        count = 0;
      }
    } else {
      lastSampling = now;
    }
  }
}

@end

/*
 * Glue code
 */

enum
{
  PROP_0,
  PROP_DEVICE_INDEX,
  PROP_DEVICE,
  PROP_DO_STATS,
  PROP_FPS
};

static void gst_avf_video_src_init_interfaces (GType type);
static void gst_avf_video_src_type_add_device_property_probe_interface (
  GType type);

GST_BOILERPLATE_FULL (GstAVFVideoSrc, gst_avf_video_src, GstPushSrc,
    GST_TYPE_PUSH_SRC, gst_avf_video_src_init_interfaces);

static void gst_avf_video_src_finalize (GObject * obj);
static void gst_avf_video_src_get_property (GObject * object, guint prop_id,
    GValue * value, GParamSpec * pspec);
static void gst_avf_video_src_set_property (GObject * object, guint prop_id,
    const GValue * value, GParamSpec * pspec);
static GstStateChangeReturn gst_avf_video_src_change_state (
  GstElement * element, GstStateChange transition);
static GstCaps * gst_avf_video_src_get_caps (GstBaseSrc * basesrc);
static gboolean gst_avf_video_src_set_caps (GstBaseSrc * basesrc,
    GstCaps * caps);
static gboolean gst_avf_video_src_start (GstBaseSrc * basesrc);
static gboolean gst_avf_video_src_stop (GstBaseSrc * basesrc);
static gboolean gst_avf_video_src_query (GstBaseSrc * basesrc,
    GstQuery * query);
static gboolean gst_avf_video_src_unlock (GstBaseSrc * basesrc);
static gboolean gst_avf_video_src_unlock_stop (GstBaseSrc * basesrc);
static GstFlowReturn gst_avf_video_src_create (GstPushSrc * pushsrc,
    GstBuffer ** buf);

static gboolean
gst_avf_video_src_iface_supported (GstImplementsInterface * iface,
    GType iface_type)
{
  return FALSE;
}

static void
gst_avf_video_src_interface_init (GstImplementsInterfaceClass * klass)
{
  /* default virtual functions */
  klass->supported = gst_avf_video_src_iface_supported;
}

static void
gst_avf_video_src_init_interfaces (GType type)
{
  static const GInterfaceInfo implements_iface_info = {
    (GInterfaceInitFunc) gst_avf_video_src_interface_init,
    NULL,
    NULL,
  };

  g_type_add_interface_static (type, GST_TYPE_IMPLEMENTS_INTERFACE,
      &implements_iface_info);

  gst_avf_video_src_type_add_device_property_probe_interface (type);
}

static void
gst_avf_video_src_base_init (gpointer gclass)
{
  GstElementClass *element_class = GST_ELEMENT_CLASS (gclass);

  gst_element_class_set_details_simple (element_class,
      "Video Source (AVFoundation)", "Source/Video",
      "Reads frames from an iOS AVFoundation device",
      "Ole André Vadla Ravnås <oravnas@cisco.com>");

  gst_element_class_add_static_pad_template (element_class, &src_template);
}

static void
gst_avf_video_src_class_init (GstAVFVideoSrcClass * klass)
{
  GObjectClass *gobject_class = G_OBJECT_CLASS (klass);
  GstElementClass *gstelement_class = GST_ELEMENT_CLASS (klass);
  GstBaseSrcClass *gstbasesrc_class = GST_BASE_SRC_CLASS (klass);
  GstPushSrcClass *gstpushsrc_class = GST_PUSH_SRC_CLASS (klass);

  gobject_class->finalize = gst_avf_video_src_finalize;
  gobject_class->get_property = gst_avf_video_src_get_property;
  gobject_class->set_property = gst_avf_video_src_set_property;

  gstelement_class->change_state = gst_avf_video_src_change_state;

  gstbasesrc_class->get_caps = gst_avf_video_src_get_caps;
  gstbasesrc_class->set_caps = gst_avf_video_src_set_caps;
  gstbasesrc_class->start = gst_avf_video_src_start;
  gstbasesrc_class->stop = gst_avf_video_src_stop;
  gstbasesrc_class->query = gst_avf_video_src_query;
  gstbasesrc_class->unlock = gst_avf_video_src_unlock;
  gstbasesrc_class->unlock_stop = gst_avf_video_src_unlock_stop;

  gstpushsrc_class->create = gst_avf_video_src_create;

  g_object_class_install_property (gobject_class, PROP_DEVICE_INDEX,
      g_param_spec_int ("device-index", "Device Index",
      "The zero-based device index",
      -1, G_MAXINT, DEFAULT_DEVICE_INDEX,
      G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));

  g_object_class_install_property (gobject_class, PROP_DEVICE,
      g_param_spec_string ("device", "Device name",
      "Human-readable name of the video device",
      NULL, G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));
  g_object_class_install_property (gobject_class, PROP_DO_STATS,
      g_param_spec_boolean ("do-stats", "Enable statistics",
      "Enable logging of statistics", DEFAULT_DO_STATS,
      G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));
  g_object_class_install_property (gobject_class, PROP_FPS,
      g_param_spec_int ("fps", "Frames per second",
      "Last measured framerate, if statistics are enabled",
      -1, G_MAXINT, -1, G_PARAM_READABLE | G_PARAM_STATIC_STRINGS));

  GST_DEBUG_CATEGORY_INIT (gst_avf_video_src_debug, "avfvideosrc",
      0, "iOS AVFoundation video source");
}

#define OBJC_CALLOUT_BEGIN() \
  NSAutoreleasePool *pool; \
  \
  pool = [[NSAutoreleasePool alloc] init]
#define OBJC_CALLOUT_END() \
  [pool release]

static void
gst_avf_video_src_init (GstAVFVideoSrc * src, GstAVFVideoSrcClass * gclass)
{
  OBJC_CALLOUT_BEGIN ();
  src->impl = [[GstAVFVideoSrcImpl alloc] initWithSrc:GST_PUSH_SRC (src)];
  OBJC_CALLOUT_END ();
}

static void
gst_avf_video_src_finalize (GObject * obj)
{
  OBJC_CALLOUT_BEGIN ();
  [GST_AVF_VIDEO_SRC_IMPL (obj) release];
  OBJC_CALLOUT_END ();

  G_OBJECT_CLASS (parent_class)->finalize (obj);
}

static void
gst_avf_video_src_get_property (GObject * object, guint prop_id, GValue * value,
    GParamSpec * pspec)
{
  GstAVFVideoSrcImpl *impl = GST_AVF_VIDEO_SRC_IMPL (object);

  switch (prop_id) {
  case PROP_DEVICE_INDEX:
    g_value_set_int (value, impl.deviceIndex);
    break;
  case PROP_DEVICE:
    g_value_set_string (value, impl.deviceName);
    break;
  case PROP_DO_STATS:
    g_value_set_boolean (value, impl.doStats);
    break;
  case PROP_FPS:
    GST_OBJECT_LOCK (object);
    g_value_set_int (value, impl.fps);
    GST_OBJECT_UNLOCK (object);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
    break;
  }
}

static void
gst_avf_video_src_set_property (GObject * object, guint prop_id,
    const GValue * value, GParamSpec * pspec)
{
  GstAVFVideoSrcImpl *impl = GST_AVF_VIDEO_SRC_IMPL (object);

  switch (prop_id) {
  case PROP_DEVICE_INDEX:
    impl.deviceIndex = g_value_get_int (value);
    break;
  case PROP_DEVICE:
    if (impl.deviceName != NULL) {
      g_free (impl.deviceName);
    }
    impl.deviceName = g_value_dup_string (value);
    break;
  case PROP_DO_STATS:
    impl.doStats = g_value_get_boolean (value);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
    break;
  }
}

static GstStateChangeReturn
gst_avf_video_src_change_state (GstElement * element, GstStateChange transition)
{
  GstStateChangeReturn ret;

  OBJC_CALLOUT_BEGIN ();
  ret = [GST_AVF_VIDEO_SRC_IMPL (element) changeState: transition];
  OBJC_CALLOUT_END ();

  return ret;
}

static GstCaps *
gst_avf_video_src_get_caps (GstBaseSrc * basesrc)
{
  GstCaps *ret;

  OBJC_CALLOUT_BEGIN ();
  ret = [GST_AVF_VIDEO_SRC_IMPL (basesrc) getCaps];
  OBJC_CALLOUT_END ();

  return ret;
}

static gboolean
gst_avf_video_src_set_caps (GstBaseSrc * basesrc, GstCaps * caps)
{
  gboolean ret;

  OBJC_CALLOUT_BEGIN ();
  ret = [GST_AVF_VIDEO_SRC_IMPL (basesrc) setCaps:caps];
  OBJC_CALLOUT_END ();

  return ret;
}

static gboolean
gst_avf_video_src_start (GstBaseSrc * basesrc)
{
  gboolean ret;

  OBJC_CALLOUT_BEGIN ();
  ret = [GST_AVF_VIDEO_SRC_IMPL (basesrc) start];
  OBJC_CALLOUT_END ();

  return ret;
}

static gboolean
gst_avf_video_src_stop (GstBaseSrc * basesrc)
{
  gboolean ret;

  OBJC_CALLOUT_BEGIN ();
  ret = [GST_AVF_VIDEO_SRC_IMPL (basesrc) stop];
  OBJC_CALLOUT_END ();

  return ret;
}

static gboolean
gst_avf_video_src_query (GstBaseSrc * basesrc, GstQuery * query)
{
  gboolean ret;

  OBJC_CALLOUT_BEGIN ();
  ret = [GST_AVF_VIDEO_SRC_IMPL (basesrc) query:query];
  OBJC_CALLOUT_END ();

  return ret;
}

static gboolean
gst_avf_video_src_unlock (GstBaseSrc * basesrc)
{
  gboolean ret;

  OBJC_CALLOUT_BEGIN ();
  ret = [GST_AVF_VIDEO_SRC_IMPL (basesrc) unlock];
  OBJC_CALLOUT_END ();

  return ret;
}

static gboolean
gst_avf_video_src_unlock_stop (GstBaseSrc * basesrc)
{
  gboolean ret;

  OBJC_CALLOUT_BEGIN ();
  ret = [GST_AVF_VIDEO_SRC_IMPL (basesrc) unlockStop];
  OBJC_CALLOUT_END ();

  return ret;
}

static GstFlowReturn
gst_avf_video_src_create (GstPushSrc * pushsrc, GstBuffer ** buf)
{
  GstFlowReturn ret;

  OBJC_CALLOUT_BEGIN ();
  ret = [GST_AVF_VIDEO_SRC_IMPL (pushsrc) create: buf];
  OBJC_CALLOUT_END ();

  return ret;
}

static const GList *
probe_get_properties (GstPropertyProbe * probe)
{
  GObjectClass *klass = G_OBJECT_GET_CLASS (probe);
  static GList *list = NULL;

  GST_CLASS_LOCK (GST_OBJECT_CLASS (klass));

  if (!list) {
    GParamSpec *pspec;

    pspec = g_object_class_find_property (klass, "device");
    list = g_list_append (NULL, pspec);
  }

  GST_CLASS_UNLOCK (GST_OBJECT_CLASS (klass));

  return list;
}

static void
probe_probe_property (GstPropertyProbe * probe, guint prop_id,
    const GParamSpec * pspec)
{
  /* we do nothing in here.  the actual "probe" occurs in get_values(),
   * which is a common practice when not caching responses.
   */

  if (!g_str_equal (pspec->name, "device")) {
    G_OBJECT_WARN_INVALID_PROPERTY_ID (probe, prop_id, pspec);
  }
}

static gboolean
probe_needs_probe (GstPropertyProbe * probe, guint prop_id,
    const GParamSpec * pspec)
{
  /* don't cache probed data */
  return TRUE;
}

static GValueArray *
probe_get_values (GstPropertyProbe * probe, guint prop_id,
    const GParamSpec * pspec)
{
  GstAVFVideoSrc *src;
  GValueArray *array;
  NSArray *devices;
  GValue value = { 0, };

  if (!g_str_equal (pspec->name, "device")) {
    G_OBJECT_WARN_INVALID_PROPERTY_ID (probe, prop_id, pspec);
    return NULL;
  }

  src = GST_AVF_VIDEO_SRC (probe);

  devices = [GstAVFVideoSrcImpl listDevices];

  if ([devices count] == 0) {
    return NULL;
  }

  array = g_value_array_new ([devices count]);
  g_value_init (&value, G_TYPE_STRING);
  for (AVCaptureDevice *device in devices) {
    gchar *name = (gchar*) [[device localizedName] UTF8String];
    GST_LOG_OBJECT (probe, "Found device: %s", name);
    g_value_set_string (&value, name);
    g_value_array_append (array, &value);
  }
  g_value_unset (&value);

  return array;
}

static void
gst_avf_video_src_property_probe_interface_init (GstPropertyProbeInterface *
    iface)
{
  iface->get_properties = probe_get_properties;
  iface->probe_property = probe_probe_property;
  iface->needs_probe = probe_needs_probe;
  iface->get_values = probe_get_values;
}

void
gst_avf_video_src_type_add_device_property_probe_interface (GType type)
{
  static const GInterfaceInfo probe_iface_info = {
    (GInterfaceInitFunc) gst_avf_video_src_property_probe_interface_init,
    NULL,
    NULL,
  };

  g_type_add_interface_static (type, GST_TYPE_PROPERTY_PROBE,
      &probe_iface_info);
}
