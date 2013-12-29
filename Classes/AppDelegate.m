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

#import "AppDelegate.h"
#import "Archive.h"

#import "Logging.h"

@implementation AppDelegate

@synthesize mainWindow=_mainWindow, tableView=_tableView, arrayController=_arrayController, progressIndicator=_progressIndicator, exporting=_exporting;

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
#ifdef NDEBUG
  LoggingSetMinimumLevel(kLogLevel_Info);
#endif
  
  NSOpenPanel* openPanel = [NSOpenPanel openPanel];
  [openPanel setCanChooseDirectories:NO];
  [openPanel setCanChooseFiles:YES];
  [openPanel setAllowedFileTypes:[NSArray arrayWithObject:@"sqlite"]];
  [openPanel setPrompt:NSLocalizedString(@"SELECT_DATABASE_BUTTON", nil)];
  if ([openPanel runModal] != NSFileHandlingPanelOKButton) {
    [NSApp terminate:nil];
  }
  
  _archive = [[EverpixArchive alloc] initWithPath:[[openPanel URL] path]];
  if (_archive) {
    EverpixUser* user = [_archive fetchUser];
    if (user) {
      [_mainWindow setTitle:[NSString stringWithFormat:@"%@ %@ (%@)", user.firstName, user.lastName, user.email]];
    } else {
      DNOT_REACHED();
    }
    [_arrayController setContent:[_archive fetchAllPhotos]];
    [_arrayController setSortDescriptors:[NSArray arrayWithObject:[NSSortDescriptor sortDescriptorWithKey:@"timestamp" ascending:NO]]];
  } else {
    NSAlert* alert = [NSAlert alertWithMessageText:NSLocalizedString(@"ALERT_DATABASE_TITLE", nil) defaultButton:NSLocalizedString(@"ALERT_DATABASE_BUTTON", nil) alternateButton:nil otherButton:nil informativeTextWithFormat:NSLocalizedString(@"ALERT_DATABASE_MESSAGE", nil)];
    [alert runModal];
  }
  
  [_mainWindow makeKeyAndOrderFront:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)application {
  return YES;
}

- (IBAction)exportPhotos:(id)sender {
  NSOpenPanel* openPanel = [NSOpenPanel openPanel];
  [openPanel setCanChooseDirectories:YES];
  [openPanel setCanChooseFiles:NO];
  [openPanel setPrompt:NSLocalizedString(@"SELECT_DESTINATION_BUTTON", nil)];
  if ([openPanel runModal] == NSFileHandlingPanelOKButton) {
    [_progressIndicator setDoubleValue:0.0];
    self.exporting = YES;
    [_archive exportPhotos:[_arrayController selectedObjects] toPath:[[openPanel URL] path] withProgressBlock:^(double progress) {
      
      [_progressIndicator setDoubleValue:progress];
      
    } completionBlock:^(NSArray* failures) {
      self.exporting = NO;
      [_progressIndicator setDoubleValue:0.0];
      
      if (failures.count) {
        NSAlert* alert = [NSAlert alertWithMessageText:[NSString stringWithFormat:NSLocalizedString(@"ALERT_EXPORT_TITLE", nil), failures.count] defaultButton:NSLocalizedString(@"ALERT_EXPORT_BUTTON", nil) alternateButton:nil otherButton:nil informativeTextWithFormat:NSLocalizedString(@"ALERT_EXPORT_MESSAGE", nil)];
        [alert runModal];
      }
      
    }];
  }
}

@end
