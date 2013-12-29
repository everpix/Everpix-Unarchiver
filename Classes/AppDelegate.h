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

#import <AppKit/AppKit.h>

@class EverpixArchive;

@interface AppDelegate : NSObject <NSApplicationDelegate> {
@private
  NSWindow* _mainWindow;
  NSTableView* _tableView;
  NSArrayController* _arrayController;
  NSProgressIndicator* _progressIndicator;
  
  BOOL _exporting;
  EverpixArchive* _archive;
}
@property(nonatomic, assign) IBOutlet NSWindow* mainWindow;
@property(nonatomic, assign) IBOutlet NSTableView* tableView;
@property(nonatomic, assign) IBOutlet NSArrayController* arrayController;
@property(nonatomic, assign) IBOutlet NSProgressIndicator* progressIndicator;
@property(nonatomic, getter=isExporting) BOOL exporting;
- (IBAction)exportPhotos:(id)sender;
@end
