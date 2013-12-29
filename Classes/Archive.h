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

#import <Foundation/Foundation.h>

typedef void (^ExportProgressBlock)(double progress);
typedef void (^ExportCompletionBlock)(NSArray* failures);

@class DatabaseConnection;

@interface EverpixUser : NSObject {
@private
  NSString* _email;
  NSString* _firstName;
  NSString* _lastName;
  NSString* _timezone;
}
@property(nonatomic, retain) NSString* email;
@property(nonatomic, retain) NSString* firstName;
@property(nonatomic, retain) NSString* lastName;
@property(nonatomic, retain) NSString* timezone;
@end

@interface EverpixPhoto : NSObject {
@private
  NSData* _pid;
  NSNumber* _timestamp;  // UNIX timestamp in UTC
  NSNumber* _year;
  NSString* _sourceType;
  NSString* _sourceName;
  NSString* _deviceType;
  NSString* _deviceName;
  NSData* _backing;
}
@property(nonatomic, retain) NSData* pid;
@property(nonatomic, retain) NSNumber* timestamp;
@property(nonatomic, retain) NSNumber* year;
@property(nonatomic, retain) NSString* sourceType;
@property(nonatomic, retain) NSString* sourceName;
@property(nonatomic, retain) NSString* deviceType;
@property(nonatomic, retain) NSString* deviceName;
@property(nonatomic, retain) NSData* backing;
@end

@interface EverpixArchive : NSObject {
@private
  DatabaseConnection* _connection;
  NSMutableDictionary* _files;
}
- (id)initWithPath:(NSString*)path;
- (EverpixUser*)fetchUser;
- (NSArray*)fetchAllPhotos;
- (void)exportPhotos:(NSArray*)photos toPath:(NSString*)path withProgressBlock:(ExportProgressBlock)progressBlock completionBlock:(ExportCompletionBlock)completionBlock;
@end
