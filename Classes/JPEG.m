/*
 * Copyright 2013 33cube, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <jpeglib.h>
#import <jerror.h>

#import "Logging.h"

#import "iccjpeg.h"

#define kJPEGCompressionQuality 0.9
#define kMaxJPEGMarkerSize 65535

typedef struct {
  struct jpeg_error_mgr error_mgr;
  jmp_buf jmp_buffer;
} ErrorManager;

NSData* TranscodeJPEG2000ToJPEG(NSData* jp2Data) {
  NSMutableData* jpgData = nil;
  NSDictionary* options = [NSDictionary dictionaryWithObject:(id)kUTTypeJPEG2000 forKey:(id)kCGImageSourceTypeIdentifierHint];
  CGImageSourceRef source = CGImageSourceCreateWithData((CFDataRef)jp2Data, (CFDictionaryRef)options);
  if (source) {
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    if (image) {
      jpgData = [NSMutableData dataWithCapacity:(5 * jp2Data.length)];
      CGImageDestinationRef destination = CGImageDestinationCreateWithData((CFMutableDataRef)jpgData, kUTTypeJPEG, 1, NULL);
      if (destination) {
        NSDictionary* properties = [NSDictionary dictionaryWithObject:[NSNumber numberWithFloat:kJPEGCompressionQuality] forKey:(id)kCGImageDestinationLossyCompressionQuality];
        CGImageDestinationAddImage(destination, image, (CFDictionaryRef)properties);
        if (!CGImageDestinationFinalize(destination)) {
          LOG_ERROR(@"ImageIO failed compressing JPEG data");
          jpgData = nil;
        }
        CFRelease(destination);
      } else {
        LOG_ERROR(@"ImageIO failed creating JPEG data");
        DNOT_REACHED();
      }
      CGImageRelease(image);
    } else {
      LOG_ERROR(@"ImageIO failed decompressing JPEG 2000 data");
      DNOT_REACHED();
    }
    CFRelease(source);
  } else {
    LOG_ERROR(@"ImageIO failed parsing JPEG 2000 data");
    DNOT_REACHED();
  }
  return jpgData;
}

static void _ErrorExit(j_common_ptr cinfo) {
  ErrorManager* errorManager = (ErrorManager*)cinfo->err;
  char buffer[JMSG_LENGTH_MAX];
  (*errorManager->error_mgr.format_message)(cinfo, buffer);
  LOG_ERROR(@"libjpeg error (%i): %s", errorManager->error_mgr.msg_code, buffer);
  
  if (cinfo->err->msg_code != JERR_UNKNOWN_MARKER) {
    longjmp(errorManager->jmp_buffer, 1);
  }
}

static void _EmitMessage(j_common_ptr cinfo, int msg_level) {
  ErrorManager* errorManager = (ErrorManager*)cinfo->err;
  if (msg_level < 0) {  // Indicates a corrupt-data warning
    char buffer[JMSG_LENGTH_MAX];
    (*errorManager->error_mgr.format_message)(cinfo, buffer);
    LOG_WARNING(@"libjpeg warning (%i): %s", errorManager->error_mgr.msg_code, buffer);
  } else if (msg_level == 0) {  // Indicates an advisory message
    char buffer[JMSG_LENGTH_MAX];
    (*errorManager->error_mgr.format_message)(cinfo, buffer);
    LOG_INFO(@"libjpeg message (%i): %s", errorManager->error_mgr.msg_code, buffer);
  }
}

NSData* BuildJPEGFile(NSData* jpgData, NSData* commentData, NSData* exifData, NSData* irbData, NSData* xmpData, NSData* iccData) {
  struct jpeg_decompress_struct dinfo;
  struct jpeg_compress_struct cinfo;
  ErrorManager errorManager;
  unsigned char* buffer = NULL;
  unsigned long length = 0;
  
  jpeg_create_decompress(&dinfo);
  jpeg_create_compress(&cinfo);
  cinfo.err = dinfo.err = jpeg_std_error(&errorManager.error_mgr);
  errorManager.error_mgr.error_exit = _ErrorExit;
  errorManager.error_mgr.emit_message = _EmitMessage;
  
  if (setjmp(errorManager.jmp_buffer)) {
    if (buffer) {
      free(buffer);
    }
    jpeg_destroy_compress(&cinfo);
    jpeg_destroy_decompress(&dinfo);
    return nil;
  }
  
  jpeg_mem_src(&dinfo, (unsigned char*)jpgData.bytes, (unsigned long)jpgData.length);
  jpeg_read_header(&dinfo, true);
  
  jvirt_barray_ptr* dct = jpeg_read_coefficients(&dinfo);
  DCHECK(dct);
  
  jpeg_copy_critical_parameters(&dinfo, &cinfo);
  jpeg_mem_dest(&cinfo, &buffer, &length);
  
  jpeg_write_coefficients(&cinfo, dct);
  
  if (commentData) {
    if (commentData.length <= kMaxJPEGMarkerSize) {
      jpeg_write_marker(&cinfo, 0xFE, (const JOCTET*)commentData.bytes, (unsigned int)commentData.length);
    } else {
      LOG_WARNING(@"Ignoring JPEG comment over maximum size");
      DNOT_REACHED();
    }
  }
  if (exifData) {
    unsigned int length = exifData.length + 6;
    if (length <= kMaxJPEGMarkerSize) {
      void* buffer = malloc(length);
      bcopy("Exif\0\0", buffer, 6);
      bcopy(exifData.bytes, (char*)buffer + 6, exifData.length);
      jpeg_write_marker(&cinfo, 0xE1, (const JOCTET*)buffer, length);
      free(buffer);
    } else {
      LOG_WARNING(@"Ignoring JPEG EXIF payload over maximum size");
      DNOT_REACHED();
    }
  }
  if (xmpData) {
    unsigned int length = xmpData.length + 29;
    if (length <= kMaxJPEGMarkerSize) {
      void* buffer = malloc(length);
      bcopy("http://ns.adobe.com/xap/1.0/\0", buffer, 29);
      bcopy(xmpData.bytes, (char*)buffer + 29, xmpData.length);
      jpeg_write_marker(&cinfo, 0xE1, (const JOCTET*)buffer, length);
      free(buffer);
    } else {
      LOG_WARNING(@"Ignoring JPEG XMP payload over maximum size");
      DNOT_REACHED();
    }
  }
  if (irbData) {
    unsigned int length = irbData.length + 14;
    if (length <= kMaxJPEGMarkerSize) {
      void* buffer = malloc(length);
      bcopy("Photoshop 3.0\0", buffer, 14);
      bcopy(irbData.bytes, (char*)buffer + 14, irbData.length);
      jpeg_write_marker(&cinfo, 0xED, (const JOCTET*)buffer, length);
      free(buffer);
    } else {
      LOG_WARNING(@"Ignoring JPEG IRB payload over maximum size");
      DNOT_REACHED();
    }
  }
  if (iccData) {
    write_icc_profile(&cinfo, (const JOCTET*)iccData.bytes, (unsigned int)iccData.length);
  }
  
  jpeg_finish_compress(&cinfo);
  jpeg_destroy_compress(&cinfo);
  jpeg_finish_decompress(&dinfo);
  jpeg_destroy_decompress(&dinfo);
  
  return [NSData dataWithBytesNoCopy:buffer length:length freeWhenDone:YES];
}
