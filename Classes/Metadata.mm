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

#import <exiv2/exiv2.hpp>

#import "Metadata.h"

#import "Logging.h"
#import "Extensions_Foundation.h"

#define kExifProcessingSoftware "Everpix-Unarchiver"

// See http://www.exif.org/Exif2-2.PDF for EXIF specs
// See http://www.exiv2.org/tags.html for list of tags in libexiv2
// See http://www.adobe.com/devnet/xmp.html for XMP specs

// EXIF GPS coordinates are an array of 3 Exiv2::URational, [degrees, minutes, seconds] (24 bytes in total)
#pragma pack(push, 1)
typedef struct {
  Exiv2::URational degrees;
  Exiv2::URational minutes;
  Exiv2::URational seconds;
} DegreesMinutesSeconds;
#pragma pack(pop)

typedef struct {
  DegreesMinutesSeconds dms;
  const char* ref;
} DegreesMinutesSecondsRef;

static Exiv2::ByteOrder _GetHostByteOrder() {
  int x = 1;
  if (*((char *) &x)) {
    return Exiv2::littleEndian;
  } else {
    return Exiv2::bigEndian;
  }
}

static BOOL _HasExifKey(Exiv2::ExifData* exif, const std::string& key) {
  Exiv2::ExifData::const_iterator i = exif->findKey(Exiv2::ExifKey(key));
  return i == exif->end() ? NO : YES;
}

static void _RemoveExifKey(Exiv2::ExifData* exif, const std::string& key) {
  while (true) {
    Exiv2::ExifData::iterator i = exif->findKey(Exiv2::ExifKey(key));
    if (i == exif->end()) {
      break;
    }
    exif->erase(i);
  }
}

static void _DegreesDoubleToDegreesMinutesSecondsRef(double degrees, const char* posRef, const char* negRef, DegreesMinutesSecondsRef* dmsr) {
  degrees = abs(degrees);
  int d = truncf(degrees);
  double m = (degrees - d) * 60;
  dmsr->dms.degrees = Exiv2::URational(d, 1);
  dmsr->dms.minutes = Exiv2::URational(roundf(m * 1000), 1000);
  dmsr->dms.seconds = Exiv2::URational(0, 1);
  dmsr->ref = degrees >= 0.0 ? posRef : negRef;
}

NSData* ProcessEXIFMetadata(NSData* inData, unsigned short orientation, NSDate* date, double latitude, double longitude, BOOL sRGB) {
  DCHECK(sizeof(DegreesMinutesSeconds) == 24);
  NSData* outData = nil;
  Exiv2::ExifData* exif = new Exiv2::ExifData();
  try {
    // Read data if any
    Exiv2::ByteOrder order;
    if (inData) {
      order = Exiv2::ExifParser::decode(*exif, (const unsigned char*)inData.bytes, inData.length);
      DCHECK((order == Exiv2::littleEndian) || (order == Exiv2::bigEndian));
    } else {
      order = Exiv2::littleEndian;
    }
    
    // Remove thumbnail(s) - EXIF only
    Exiv2::ExifThumb thumbnail(*exif);
    thumbnail.erase();
    
    // Set processing software - EXIF only
    (*exif)["Exif.Image.ProcessingSoftware"] = kExifProcessingSoftware;
    
    // Set colorspace
    (*exif)["Exif.Photo.ColorSpace"] = (unsigned short)(sRGB ? 1 : 65535);
    
    // Set orientation
    (*exif)["Exif.Image.Orientation"] = orientation;
    
    // Set timestamp if necessary
    if (date) {
      const char* datetime = [[date stringWithCachedFormat:@"yyyy:MM:dd HH:mm:ss" localIdentifier:@"en_US" timeZone:[NSTimeZone GMTTimeZone]] UTF8String];
      DCHECK(strlen(datetime) == 19);
      (*exif)["Exif.Image.DateTime"] = datetime;
      _RemoveExifKey(exif, "Exif.Image.DateTimeOriginal");
      _RemoveExifKey(exif, "Exif.Image.PreviewDateTime");
      (*exif)["Exif.Photo.DateTimeOriginal"] = datetime;
      _RemoveExifKey(exif, "Exif.Photo.DateTimeDigitized");
      _RemoveExifKey(exif, "Exif.Photo.SubSecTime");
      _RemoveExifKey(exif, "Exif.Photo.SubSecTimeOriginal");
      _RemoveExifKey(exif, "Exif.Photo.SubSecTimeDigitized");
    }
    
    // Set latitude / longitude if necessary
    if (!isnan(latitude) && !isnan(longitude)) {
      if (_HasExifKey(exif, "Exif.Image.GPSTag")) {
        // TODO: What to do if there's already a GPS tag?
      } else {
        DCHECK(sizeof(DegreesMinutesSeconds) == 24);
        DegreesMinutesSecondsRef dmsrLatitude;
        _DegreesDoubleToDegreesMinutesSecondsRef(latitude, "N", "S", &dmsrLatitude);
        (*exif)["Exif.GPSInfo.GPSLatitude"] = Exiv2::ValueType<Exiv2::URational>((const Exiv2::byte*)&dmsrLatitude.dms, sizeof(dmsrLatitude.dms), _GetHostByteOrder(), Exiv2::unsignedRational);
        (*exif)["Exif.GPSInfo.GPSLatitudeRef"] = dmsrLatitude.ref;
        DegreesMinutesSecondsRef dmsrLongitude;
        _DegreesDoubleToDegreesMinutesSecondsRef(longitude, "E", "W", &dmsrLongitude);
        (*exif)["Exif.GPSInfo.GPSLongitude"] = Exiv2::ValueType<Exiv2::URational>((const Exiv2::byte*)&dmsrLongitude.dms, sizeof(dmsrLongitude.dms), _GetHostByteOrder(), Exiv2::unsignedRational);
        (*exif)["Exif.GPSInfo.GPSLongitudeRef"] = dmsrLongitude.ref;
        Exiv2::byte version[4] = {2, 0, 0, 0};
        (*exif)["Exif.GPSInfo.GPSVersionID"] = Exiv2::DataValue(version, sizeof(version), Exiv2::invalidByteOrder, Exiv2::unsignedByte);
      }
    }
    
    // Write data
    Exiv2::Blob* oldBlob = new Exiv2::Blob((unsigned char*)inData.bytes, (unsigned char*)inData.bytes + inData.length);
    Exiv2::Blob* newBlob = new Exiv2::Blob();
    if (Exiv2::ExifParser::encode(*newBlob, &*oldBlob->begin(), oldBlob->size(), order, *exif) == Exiv2::wmNonIntrusive) {
      delete newBlob;
      newBlob = oldBlob;
    } else {
      delete oldBlob;
    }
    outData = [NSData dataWithBytes:&*newBlob->begin() length:newBlob->size()];
    delete newBlob;
    
  } catch (Exiv2::Error& e) {
    LOG_ERROR(@"libexiv2 exception: %s", e.what());
    DNOT_REACHED();
  }
  delete exif;
  return outData;
}

static void _RemoveXmpKey(Exiv2::XmpData* xmp, const std::string& key) {
  while (true) {
    Exiv2::XmpData::iterator i = xmp->findKey(Exiv2::XmpKey(key));
    if (i == xmp->end()) {
      break;
    }
    xmp->erase(i);
  }
}

NSData* ProcessXMPMetadata(NSData* inData, unsigned short orientation, NSDate* date, double latitude, double longitude, BOOL sRGB) {
  NSData* outData = nil;
  Exiv2::XmpData* xmp = new Exiv2::XmpData();
  try {
    // Read data
    if (Exiv2::XmpParser::decode(*xmp, std::string((char*)inData.bytes, inData.length)) == 0) {
      
      // Set colorspace
      (*xmp)["Xmp.exif.ColorSpace"] = (unsigned short)(sRGB ? 1 : 65535);
      
      // Set orientation
      (*xmp)["Xmp.tiff.Orientation"] = orientation;
      
      // Set timestamp
      if (date) {
        const char* datetime = [[date stringWithCachedFormat:@"yyyy-MM-dd'T'HH:mm:ss" localIdentifier:@"en_US" timeZone:[NSTimeZone GMTTimeZone]] UTF8String];
        DCHECK(strlen(datetime) == 19);
        (*xmp)["Xmp.xmp.CreateDate"] = datetime;
        (*xmp)["Xmp.exif.DateTimeOriginal"] = datetime;
      } else {
        _RemoveXmpKey(xmp, "Xmp.xmp.CreateDate");
        _RemoveXmpKey(xmp, "Xmp.exif.DateTimeOriginal");
      }
      _RemoveXmpKey(xmp, "Xmp.tiff.DateTime");
      _RemoveXmpKey(xmp, "Xmp.exif.DateTimeDigitized");
      
      // Set latitude / longitude if necessary
      if (!isnan(latitude) && !isnan(longitude)) {
        // TODO
      }
      
      // Write data
      std::string* packet = new std::string;
      if (Exiv2::XmpParser::encode(*packet, *xmp) == 0) {
        outData = [NSData dataWithBytes:packet->data() length:packet->length()];
      } else {
        LOG_ERROR(@"libexiv2 failed encoding XMP");
        DNOT_REACHED();
      }
      delete packet;
      
    } else {
      LOG_ERROR(@"libexiv2 failed decoding XMP");
      DNOT_REACHED();
    }
  } catch (Exiv2::Error& e) {
    LOG_ERROR(@"libexiv2 exception: %s", e.what());
    DNOT_REACHED();
  }
  delete xmp;
  return outData;
}
