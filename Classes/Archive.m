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

#import <python2.7/Python.h>

#import "Archive.h"
#import "JPEG.h"
#import "Metadata.h"
#import "MiniZip.h"

#import "Crypto.h"
#import "Database.h"
#import "Logging.h"

typedef enum {
  kColorProfileID_Other = 0,
  kColorProfileID_sRGB = 1,
  kColorProfileID_AdobeRGB = 2,
  kColorProfileID_AppleRGB = 3,
  kColorProfileID_GenericRGB = 4,
  kColorProfileID_CameraRGB = 5
} ColorProfileID;

static PyObject* _bridgeDecodeFunction = NULL;
static NSData* _adobeRGBProfile = nil;
static NSData* _appleRGBProfile = nil;
static NSData* _genericRGBProfile = nil;
static NSData* _cameraRGBProfile = nil;

@implementation EverpixUser

@synthesize email=_email, firstName=_firstName, lastName=_lastName, timezone=_timezone;

- (void)dealloc {
  [_email release];
  [_firstName release];
  [_lastName release];
  [_timezone release];
  
  [super dealloc];
}

@end

@implementation EverpixPhoto

@synthesize pid=_pid, timestamp=_timestamp, year=_year, sourceType=_sourceType, sourceName=_sourceName, deviceType=_deviceType,
            deviceName=_deviceName, backing=_backing;

- (void)dealloc {
  [_pid release];
  [_timestamp release];
  [_year release];
  [_sourceType release];
  [_sourceName release];
  [_deviceType release];
  [_deviceName release];
  [_backing release];
  
  [super dealloc];
}

@end

@implementation EverpixArchive

+ (void)initialize {
  if (_bridgeDecodeFunction == NULL) {
    NSString* bridge = [NSString stringWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"Bridge" ofType:@"py"] encoding:NSUTF8StringEncoding error:NULL];
    Py_Initialize();
    PyRun_SimpleString([bridge UTF8String]);
    PyObject* mainModule = PyImport_AddModule("__main__");
    PyObject* globalDictionary = PyModule_GetDict(mainModule);
    _bridgeDecodeFunction = PyDict_GetItemString(globalDictionary, "decode");
    CHECK(_bridgeDecodeFunction);
  }
  if (_adobeRGBProfile == nil) {
    _adobeRGBProfile = [[NSData alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"Adobe_RGB_1998" ofType:@"icc"]];
    CHECK(_adobeRGBProfile);
  }
  if (_appleRGBProfile == nil) {
    _appleRGBProfile = [[NSData alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"Apple_RGB" ofType:@"icc"]];
    CHECK(_appleRGBProfile);
  }
  if (_genericRGBProfile == nil) {
    _genericRGBProfile = [[NSData alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"Generic_RGB" ofType:@"icc"]];
    CHECK(_genericRGBProfile);
  }
  if (_cameraRGBProfile == nil) {
    _cameraRGBProfile = [[NSData alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"Camera_RGB" ofType:@"icc"]];
    CHECK(_cameraRGBProfile);
  }
}

- (id)initWithPath:(NSString*)path {
  if ((self = [super init])) {
    NSString* basePath = [path stringByDeletingLastPathComponent];
    LOG_INFO(@"Using archive directory at \"%@\"", basePath);
    
    _connection = [[DatabaseConnection alloc] initWithDatabaseAtPath:path readWrite:NO];
    if (_connection == nil) {
      LOG_ERROR(@"Failed opening archive database");
      [self release];
      return nil;
    }
    LOG_INFO(@"Loaded database file at \"%@\"", [path lastPathComponent]);
    
    _files = [[NSMutableDictionary alloc] init];
    for (NSString* file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:basePath error:NULL]) {
      if ([file hasSuffix:@".zip"]) {
        MiniZip* zip = [[MiniZip alloc] initWithArchiveAtPath:[basePath stringByAppendingPathComponent:file]];
        if (zip) {
          for (NSString* entry in [zip retrieveFileList]) {
            if ([entry hasSuffix:@".jp2"]) {
              DCHECK(entry.length == 55);
              [_files setObject:zip forKey:entry];
            } else {
              LOG_WARNING(@"Unexpected entry \"%@\" in ZIP file", entry);
              DNOT_REACHED();
            }
          }
          [zip release];
          LOG_INFO(@"Loaded ZIP file at \"%@\"", file);
        } else {
          LOG_ERROR(@"Failed loading ZIP file at \"@%\"", file);
          DNOT_REACHED();
        }
      }
    }
  }
  return self;
}

- (void)dealloc {
  [_connection release];
  
  [super dealloc];
}

- (EverpixUser*)fetchUser {
  NSString* sql = @" \
    SELECT CAST(email AS VARCHAR) AS email, CAST(first_name AS VARCHAR) AS firstName, CAST(last_name AS VARCHAR) AS lastName, CAST(timezone AS VARCHAR) AS timezone FROM users \
  ";
  return [[_connection executeRawSQLStatement:sql usingRowClass:[EverpixUser class] primaryKey:nil] firstObject];
}

- (NSArray*)fetchAllPhotos {
  NSString* sql = [NSString stringWithFormat:@" \
    SELECT photos.pid, timestamp - %f AS timestamp, year, sources__source_type.enum_value AS sourceType, CAST(source_name AS VARCHAR) AS sourceName, sources__device_type.enum_value AS deviceType, CAST(device_name AS VARCHAR) AS deviceName, backing \
    FROM photos \
    JOIN photos_instances ON photos_instances.bid = SUBSTR(photos.backing, 1, 16) \
    JOIN sources ON sources.source_uuid = photos_instances.source_uuid \
    LEFT JOIN sources__source_type ON sources__source_type.enum_id = sources.source_type \
    LEFT JOIN sources__device_type ON sources__device_type.enum_id = sources.device_type \
    WHERE visibility >= 0 \
  ", NSTimeIntervalSince1970];
  NSArray* allPhotos = [_connection executeRawSQLStatement:sql usingRowClass:[EverpixPhoto class] primaryKey:nil];
  NSMutableArray* availablePhotos = [NSMutableArray arrayWithCapacity:allPhotos.count];
  for (EverpixPhoto* photo in allPhotos) {
    NSString* backing = DataToString([photo backing]);
    NSString* file = [NSString stringWithFormat:@"%@/%@.jp2", [backing substringToIndex:2], backing];
    if ([_files objectForKey:file]) {
      [availablePhotos addObject:photo];
    }
  }
  if (allPhotos.count > availablePhotos.count) {
    LOG_WARNING(@"%i photos are in database file but missing from ZIP files", allPhotos.count - availablePhotos.count);
  } else {
    LOG_INFO(@"%i photos loaded from database file", allPhotos.count);
  }
  return availablePhotos;
}

static NSString* _NSStringFromPyStringOrPyUnicode(PyObject* str) {
  NSString* string = nil;
  if (PyUnicode_Check(str)) {
    PyObject* copy = PyUnicode_AsUTF8String(str);
    DCHECK(PyString_Check(copy));
    string = [[NSString alloc] initWithBytes:PyString_AS_STRING(copy) length:PyString_GET_SIZE(copy) encoding:NSUTF8StringEncoding];
    Py_DECREF(copy);
  } else if (PyString_Check(str)) {
    string = [[NSString alloc] initWithBytes:PyString_AS_STRING(str) length:PyString_GET_SIZE(str) encoding:NSUTF8StringEncoding];
  }
  return [string autorelease];
}

static NSDictionary* _NSDictionaryFromPyDict(PyObject* dict, BOOL rawData) {
  DCHECK(PyDict_Check(dict));
  NSMutableDictionary* dictionary = [[NSMutableDictionary alloc] init];
  PyObject* key = NULL;
  PyObject* value = NULL;
  Py_ssize_t i = 0;
  while (PyDict_Next(dict, &i, &key, &value)) {
    NSString* string = _NSStringFromPyStringOrPyUnicode(key);
    id object = nil;
    if (rawData) {
      DCHECK(PyString_Check(value));
      object = [NSData dataWithBytes:PyString_AS_STRING(value) length:PyString_GET_SIZE(value)];
    } else if (PyInt_Check(value)) {
      object = [NSNumber numberWithLong:PyInt_AS_LONG(value)];
    } else if (PyFloat_Check(value)) {
      object = [NSNumber numberWithDouble:PyFloat_AS_DOUBLE(value)];
    } else {
      object = _NSStringFromPyStringOrPyUnicode(value);
    }
    if (object) {
      [dictionary setObject:object forKey:string];
    } else {
      fprintf(stderr, "Unexpected Python object for metadata key '");
      PyObject_Print(key, stderr, Py_PRINT_RAW);
      fprintf(stderr, "':\n");
      PyObject_Print(value, stderr, 0);
      fprintf(stderr, "\n");
      fflush(stderr);
    }
  }
  return [dictionary autorelease];
}

static void _DecodeSourceMetadata(NSData* data, NSMutableDictionary* dictionary) {
  PyObject* args = PyTuple_New(1);
  PyTuple_SetItem(args, 0, PyString_FromStringAndSize(data.bytes, data.length));
  PyObject* result = PyObject_CallObject(_bridgeDecodeFunction, args);
  [dictionary addEntriesFromDictionary:_NSDictionaryFromPyDict(result, NO)];
  Py_DECREF(result);
  Py_DECREF(args);
}

static void _DecodeSourceHeaders(NSData* data, NSMutableDictionary* dictionary) {
  PyObject* args = PyTuple_New(1);
  PyTuple_SetItem(args, 0, PyString_FromStringAndSize(data.bytes, data.length));
  PyObject* result = PyObject_CallObject(_bridgeDecodeFunction, args);
  [dictionary addEntriesFromDictionary:_NSDictionaryFromPyDict(result, YES)];
  Py_DECREF(result);
  Py_DECREF(args);
}

static void _DecodeSourceBlob(NSData* data, NSMutableDictionary* dictionary) {
  PyObject* args = PyTuple_New(1);
  PyTuple_SetItem(args, 0, PyString_FromStringAndSize(data.bytes, data.length));
  PyObject* result = PyObject_CallObject(_bridgeDecodeFunction, args);
  DCHECK(PyTuple_Check(result));
  PyObject* metadata = PyTuple_GetItem(result, 0);
  [dictionary addEntriesFromDictionary:_NSDictionaryFromPyDict(metadata, NO)];
  PyObject* headers = PyTuple_GetItem(result, 1);
  [dictionary addEntriesFromDictionary:_NSDictionaryFromPyDict(headers, YES)];
  Py_DECREF(result);
  Py_DECREF(args);
}

static id _GetMetadata(NSDictionary* primary, NSArray* secondary, NSString* key) {
  id value = [primary objectForKey:key];
  if (value == nil) {
    for (NSDictionary* dictionary in secondary) {
      value = [dictionary objectForKey:key];
      if (value) {
        break;
      }
    }
  }
  return value;
}

- (NSArray*)_exportPhotos:(NSArray*)photos toPath:(NSString*)path withProgressBlock:(ExportProgressBlock)block {
  NSMutableArray* failures = [NSMutableArray array];
  NSUInteger index = 0;
  for (EverpixPhoto* photo in photos) {
    @autoreleasepool {
      double progress = (double)++index / (double)photos.count;
      dispatch_async(dispatch_get_main_queue(), ^{
        block(progress);
      });
      BOOL success = NO;
      
      NSString* sql1 = [NSString stringWithFormat:@" \
        SELECT timestamp, latitude, longitude, orientation, color_profile_id AS colorProfileID \
        FROM photos \
        WHERE pid = X'%@' \
      ", DataToString(photo.pid)];
      NSDictionary* photoInfo = [[_connection executeRawSQLStatement:sql1] firstObject];
      if (photoInfo) {
        NSString* backing = DataToString([photo backing]);
        NSData* bid = [[photo backing] subdataWithRange:NSMakeRange(0, 16)];
        NSDate* date = nil;
        if ([photoInfo objectForKey:@"timestamp"]) {
          double timestamp = [[photoInfo objectForKey:@"timestamp"] doubleValue];
          DCHECK((timestamp >= -62135596800) && (timestamp <= 253402300799));
          date = [NSDate dateWithTimeIntervalSince1970:timestamp];
          DCHECK(date);
        }
        double latitude = [photoInfo objectForKey:@"latitude"] ? [[photoInfo objectForKey:@"latitude"] doubleValue] : NAN;
        DCHECK(isnan(latitude) || ((latitude >= -90.0) && (latitude <= 90.0)));
        double longitude = [photoInfo objectForKey:@"longitude"] ? [[photoInfo objectForKey:@"longitude"] doubleValue] : NAN;
        DCHECK(isnan(longitude) || ((longitude >= -180.0) && (longitude <= 180.0)));
        int orientation = [[photoInfo objectForKey:@"orientation"] intValue];
        DCHECK((orientation >= 1) && (orientation <= 8));
        ColorProfileID colorProfileID = [[photoInfo objectForKey:@"colorProfileID"] intValue];
        DCHECK((colorProfileID >= 0) && (colorProfileID <= 5));
        
        NSString* sql2 = [NSString stringWithFormat:@" \
          SELECT photos_instances.source_pid AS sourcePID, source_metadata AS sourceMetadata, headers, blob_data AS blobData, bid \
          FROM photos_instances \
          LEFT JOIN photo_instance_blobs ON photo_instance_blobs.user_id = photos_instances.user_id AND photo_instance_blobs.source_pid = photos_instances.source_pid \
          WHERE pid = X'%@' \
        ", DataToString(photo.pid)];
        NSArray* photoInstances = [_connection executeRawSQLStatement:sql2];
        DCHECK(photoInstances.count >= 1);
        NSDictionary* primaryMetadata = nil;
        NSMutableArray* secondaryMetadata = [NSMutableArray array];
        for (NSDictionary* instance in photoInstances) {
          NSMutableDictionary* metadata = [NSMutableDictionary dictionary];
          NSData* data = [instance objectForKey:@"blobData"];
          if (data) {
            _DecodeSourceBlob(data, metadata);
          } else {
            NSData* sourceMetadata = [instance objectForKey:@"sourceMetadata"];
            if (sourceMetadata) {
              _DecodeSourceMetadata(sourceMetadata, metadata);
            }
            NSData* headers = [instance objectForKey:@"headers"];
            if (headers) {
              _DecodeSourceHeaders(headers, metadata);
            }
          }
          if (metadata.count) {
            if ([bid isEqualToData:[instance objectForKey:@"bid"]]) {
              if (primaryMetadata == nil) {
                primaryMetadata = metadata;
              } else {
                LOG_WARNING(@"Duplicate primary photo instance for photo with PID '%@'", photo.pid);
              }
            } else {
              [secondaryMetadata addObject:metadata];
            }
          }
        }
        DCHECK(primaryMetadata);
        
        NSString* file = [NSString stringWithFormat:@"%@/%@.jp2", [backing substringToIndex:2], backing];
        MiniZip* zip = [_files objectForKey:file];
        if (zip) {
          NSString* jp2Path = [[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]] stringByAppendingPathExtension:@"jp2"];
          if ([zip extractFile:file toPath:jp2Path]) {
            NSData* jp2Data = [NSData dataWithContentsOfFile:jp2Path];
            NSData* jpgData = TranscodeJPEG2000ToJPEG(jp2Data);
            if (jpgData) {
              
              NSData* textData = _GetMetadata(primaryMetadata, secondaryMetadata, @"TEXT");
              
              NSData* exifData = _GetMetadata(primaryMetadata, secondaryMetadata, @"EXIF");
              exifData = ProcessEXIFMetadata(exifData, orientation, date, latitude, longitude, colorProfileID == kColorProfileID_sRGB);
              
              NSData* xmpData = _GetMetadata(primaryMetadata, secondaryMetadata, @"XMP");
              if (xmpData) {
                xmpData = ProcessXMPMetadata(xmpData, orientation, date, latitude, longitude, colorProfileID == kColorProfileID_sRGB);
              }
              
              NSData* irbData = _GetMetadata(primaryMetadata, secondaryMetadata, @"IRB");
              
              NSData* iccData = nil;
              switch (colorProfileID) {
                
                case kColorProfileID_Other: {
                  iccData = _GetMetadata(primaryMetadata, secondaryMetadata, @"ICC");
                  DCHECK(iccData);
                  break;
                }
                
                case kColorProfileID_sRGB:
                  break;
                
                case kColorProfileID_AdobeRGB:
                  iccData = _adobeRGBProfile;
                  break;
                
                case kColorProfileID_AppleRGB:
                  iccData = _appleRGBProfile;
                  break;
                
                case kColorProfileID_GenericRGB:
                  iccData = _genericRGBProfile;
                  break;
                
                case kColorProfileID_CameraRGB:
                  iccData = _cameraRGBProfile;
                  break;
                
              }
              
              NSData* fileData = BuildJPEGFile(jpgData, textData, exifData, irbData, xmpData, iccData);
              if (fileData) {
                NSString* baseName = [[_GetMetadata(primaryMetadata, secondaryMetadata, @"filePath") lastPathComponent] stringByDeletingPathExtension];
                if (baseName == nil) {
                  baseName = DataToString(photo.pid);
                }
                NSString* filePath;
                int index = 0;
                while (1) {
                  filePath = [[path stringByAppendingPathComponent:(index ? [NSString stringWithFormat:@"%@ (%i)", baseName, index] : baseName)] stringByAppendingPathExtension:@"jpg"];
                  if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
                    break;
                  }
                  ++index;
                }
                if ([fileData writeToFile:filePath atomically:YES]) {
                  success = YES;
                } else {
                  LOG_ERROR(@"Failed writing JPEG file for photo with PID '%@'", photo.pid);
                  DNOT_REACHED();
                }
              } else {
                LOG_ERROR(@"Failed building JPEG file for photo with PID '%@'", photo.pid);
                DNOT_REACHED();
              }
              
            } else {
              LOG_ERROR(@"Failed transcoding photo with PID '%@'", photo.pid);
              DNOT_REACHED();
            }
            
            [[NSFileManager defaultManager] removeItemAtPath:jp2Path error:NULL];
          } else {
            LOG_ERROR(@"Failed extracting backing for photo with PID '%@'", photo.pid);
            DNOT_REACHED();
          }
        } else {
          LOG_ERROR(@"Missing backing for photo with PID '%@'", photo.pid);
        }
        
      } else {
        LOG_ERROR(@"Failed fetching photo with PID '%@'", photo.pid);
        DNOT_REACHED();
      }
      
      if (!success) {
        [failures addObject:photo];
      }
    }
  }
  return failures;
}

- (void)exportPhotos:(NSArray*)photos toPath:(NSString*)path withProgressBlock:(ExportProgressBlock)progressBlock completionBlock:(ExportCompletionBlock)completionBlock {
  progressBlock = Block_copy(progressBlock);
  completionBlock = Block_copy(completionBlock);
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    
    NSArray* failures = [self _exportPhotos:photos toPath:path withProgressBlock:progressBlock];
    Block_release(progressBlock);
    
    dispatch_async(dispatch_get_main_queue(), ^{
      completionBlock(failures);
      Block_release(completionBlock);
    });
  });
}

@end
