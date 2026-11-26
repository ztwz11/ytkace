#import "DriveExport.h"
#import "DriveClient.h"
#import "DriveMedia.h"
#import "../../Runtime/Localization.h"
#import "../Downloads/YTKACEBackupManager.h"

#import <AVFoundation/AVFoundation.h>
#include <cmath>

static NSString *const FrameIntervalKey = @"YTKACE.Preference.DriveExport.FrameInterval";
static NSString *const FrameSizeKey = @"YTKACE.Preference.DriveExport.MaxFrameSize";
static BOOL ExportInProgress;

BOOL YTKDriveCanExport(NSURL *url) {
    return url.isFileURL && [@[@"mp4", @"mov", @"m4v", @"webm", @"mkv"]
        containsObject:url.pathExtension.lowercaseString];
}

NSString *YTKDriveExportTitle(void) {
    return YTKACELocalized(@"Export to Google Drive");
}

static void ShowResult(UIViewController *presenter, NSString *message, NSString *folder) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:YTKDriveExportTitle()
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"OK")
        style:UIAlertActionStyleCancel handler:nil]];
    if (folder.length) {
        NSURL *url = [NSURL URLWithString:[@"https://drive.google.com/drive/folders/" stringByAppendingString:folder]];
        [alert addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Open Drive folder")
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
            }]];
    }
    [presenter presentViewController:alert animated:YES completion:nil];
}

static NSData *FrameAt(AVAssetImageGenerator *generator, NSUInteger seconds, CMTime *actual, NSError **error) {
    CMTime requested = CMTimeMake((int64_t)seconds, 1);
    CGImageRef frame = [generator copyCGImageAtTime:requested actualTime:actual error:error];
    if (!frame) return nil;
    NSData *jpeg = UIImageJPEGRepresentation([UIImage imageWithCGImage:frame], 0.82);
    CGImageRelease(frame);
    if (!jpeg && error) *error = YTKDriveError(@"Could not encode the JPEG frame.");
    return jpeg;
}

static BOOL WriteExportFile(NSURL *directory, NSData *data, NSString *name, NSString *mime,
                            NSMutableArray<NSDictionary *> *entries, NSError **error) {
    NSURL *url = [directory URLByAppendingPathComponent:name];
    if (![data writeToURL:url options:NSDataWritingAtomic error:error]) return NO;
    [entries addObject:@{@"name":name, @"url":url, @"mime":mime}];
    return YES;
}

static NSArray<NSDictionary *> *PrepareVideo(NSURL *videoURL, NSURL *directory,
    NSUInteger interval, NSUInteger frameSize, NSProgress *job, void (^progress)(NSString *), NSError **error) {
    NSDictionary<NSString *, NSData *> *captions = YTKDriveCaptionFiles(videoURL,
        ^BOOL { return job.cancelled; }, error);
    if (!captions) return nil;

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoURL options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
    double duration = CMTimeGetSeconds(asset.duration);
    if (!std::isfinite(duration) || duration <= 0 || ![asset tracksWithMediaType:AVMediaTypeVideo].count) {
        if (error) *error = YTKDriveError(@"This download does not contain a readable video track.");
        return nil;
    }
    NSUInteger frameCount = (NSUInteger)ceil(duration / interval);
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.maximumSize = CGSizeMake(frameSize, frameSize);
    generator.requestedTimeToleranceBefore = CMTimeMake(1, 10);
    generator.requestedTimeToleranceAfter = CMTimeMake(1, 10);
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray arrayWithCapacity:captions.count + frameCount + 1];
    for (NSString *filename in @[@"transcript.txt", @"transcript.vtt"]) {
        NSString *mime = [filename hasSuffix:@".vtt"] ? @"text/vtt" : @"text/plain";
        if (!WriteExportFile(directory, captions[filename], filename, mime, entries, error)) return nil;
    }

    NSMutableString *csv = [NSMutableString stringWithString:@"file,requested_time,actual_time\n"];
    for (NSUInteger frame = 0; frame < frameCount; frame++) {
        if (job.cancelled) return nil;
        NSError *frameError = nil;
        BOOL saved = NO;
        @autoreleasepool {
            NSUInteger seconds = frame * interval;
            CMTime actual = kCMTimeInvalid;
            NSData *jpeg = FrameAt(generator, seconds, &actual, &frameError);
            NSString *requested = YTKDriveTimestamp(seconds);
            NSString *filename = [NSString stringWithFormat:@"frame_%@.jpg",
                [requested stringByReplacingOccurrencesOfString:@":" withString:@"-"]];
            saved = jpeg && WriteExportFile(directory, jpeg, filename, @"image/jpeg", entries, &frameError);
            if (saved) {
                NSString *actualTime = CMTIME_IS_NUMERIC(actual) ? YTKDriveTimestamp(CMTimeGetSeconds(actual)) : @"";
                [csv appendFormat:@"%@,%@,%@\n", filename, requested, actualTime];
            }
        }
        if (!saved) {
            if (error) *error = frameError;
            return nil;
        }
        if (frame == 0 || (frame + 1) % 5 == 0 || frame + 1 == frameCount) {
            progress([NSString stringWithFormat:YTKACELocalized(@"Prepared %lu of %lu frames."),
                (unsigned long)(frame + 1), (unsigned long)frameCount]);
        }
    }
    return WriteExportFile(directory, [csv dataUsingEncoding:NSUTF8StringEncoding], @"frames.csv",
                           @"text/csv", entries, error) ? entries : nil;
}

static BOOL UploadFiles(YTKDriveClient *client, NSArray<NSDictionary *> *entries, NSString *title,
                        void (^progress)(NSString *), NSString **uploadedFolder, NSError **error) {
    NSArray<NSString *> *ids = [client fileIDs:entries.count + 1 error:error];
    if (!ids) return NO;
    NSString *folder = ids.firstObject;
    if (![client createFolder:[@"YTKACE - " stringByAppendingString:title] fileID:folder parent:nil error:error]) return NO;
    *uploadedFolder = folder;
    NSUInteger index = 0;
    for (NSDictionary *entry in entries) {
        NSError *fileError = nil;
        BOOL uploaded = NO;
        @autoreleasepool {
            if (client.cancelled) return NO;
            NSData *data = [NSData dataWithContentsOfURL:entry[@"url"] options:NSDataReadingMappedIfSafe error:&fileError];
            uploaded = data && [client upload:data name:entry[@"name"] mime:entry[@"mime"]
                fileID:ids[index + 1] folder:folder error:&fileError];
        }
        if (!uploaded) {
            if (error) *error = fileError;
            return NO;
        }
        index++;
        if (index == 1 || index % 5 == 0 || index == entries.count) {
            progress([NSString stringWithFormat:YTKACELocalized(@"Uploaded %lu of %lu files."),
                (unsigned long)index, (unsigned long)entries.count]);
        }
    }
    return YES;
}

static void ShareArchive(UIViewController *presenter, NSURL *archive, NSURL *directory) {
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[archive]
        applicationActivities:nil];
    UIPopoverPresentationController *popover = share.popoverPresentationController;
    popover.sourceView = presenter.view;
    popover.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1, 1);
    popover.permittedArrowDirections = 0;
    share.completionWithItemsHandler = ^(__unused NSString *activity, __unused BOOL completed,
        __unused NSArray *items, __unused NSError *error) {
        [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
    };
    [presenter presentViewController:share animated:YES completion:nil];
}

static void StartExport(UIViewController *presenter, NSURL *videoURL, NSUInteger interval, NSUInteger size,
                        BOOL direct) {
    if (ExportInProgress) return;
    ExportInProgress = YES;
    YTKDriveClient *client = direct ? [YTKDriveClient new] : nil;
    void (^begin)(NSError *) = ^(NSError *authError) {
        if (authError) {
            ExportInProgress = NO;
            [client cancel];
            ShowResult(presenter, authError.localizedDescription, nil);
            return;
        }
        NSProgress *job = [NSProgress progressWithTotalUnitCount:1];
        UIAlertController *progress = [UIAlertController alertControllerWithTitle:YTKDriveExportTitle()
            message:YTKACELocalized(@"Reading captions and video…") preferredStyle:UIAlertControllerStyleAlert];
        [progress addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Cancel")
            style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
                [job cancel];
                [client cancel];
            }]];
        [presenter presentViewController:progress animated:YES completion:nil];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error = nil;
            NSString *folder = nil;
            void (^report)(NSString *) = ^(NSString *message) {
                dispatch_async(dispatch_get_main_queue(), ^{ progress.message = message; });
            };
            NSString *title = videoURL.lastPathComponent.stringByDeletingPathExtension;
            NSURL *directory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
                URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
            NSURL *staging = [directory URLByAppendingPathComponent:@"contents" isDirectory:YES];
            NSURL *archive = [directory URLByAppendingPathComponent:[title stringByAppendingPathExtension:@"zip"]];
            NSArray<NSDictionary *> *entries = nil;
            BOOL success = NO;
            if ([NSFileManager.defaultManager createDirectoryAtURL:staging
                withIntermediateDirectories:YES attributes:nil error:&error]) {
                entries = PrepareVideo(videoURL, staging, interval, size, job, report, &error);
            }
            if (entries && !job.cancelled) {
                if (direct) {
                    success = UploadFiles(client, entries, title, report, &folder, &error);
                } else {
                    report(YTKACELocalized(@"Creating ZIP…"));
                    @try {
                        success = YTKACEWriteStoredZip(archive, entries, &error);
                    } @catch (__unused NSException *exception) {
                        error = YTKDriveError(@"Could not create the ZIP file.");
                    }
                }
            }
            BOOL share = success && !direct && !job.cancelled;
            if (share) {
                [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
            } else {
                [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL cancelled = job.cancelled;
                [client cancel];
                ExportInProgress = NO;
                NSString *message = cancelled ? YTKACELocalized(@"Drive export cancelled.") :
                    (success ? YTKACELocalized(@"Captions and frames uploaded.") :
                     (error.localizedDescription ?: YTKACELocalized(@"Drive export failed.")));
                if ((!success || cancelled) && folder.length) {
                    message = [message stringByAppendingFormat:@"\n%@",
                        YTKACELocalized(@"The Drive folder may contain files already uploaded.")];
                }
                dispatch_block_t finish = ^{
                    if (share && !cancelled) {
                        ShareArchive(presenter, archive, directory);
                    } else {
                        if (share) [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
                        ShowResult(presenter, message, folder);
                    }
                };
                if (progress.isBeingDismissed) {
                    if (![progress.transitionCoordinator animateAlongsideTransition:nil completion:
                        ^(__unused id<UIViewControllerTransitionCoordinatorContext> context) { finish(); }]) finish();
                } else if (progress.presentingViewController) {
                    [progress dismissViewControllerAnimated:YES completion:finish];
                } else {
                    finish();
                }
            });
        });
    };
    if (direct) [client authorizeFrom:presenter complete:begin];
    else begin(nil);
}

static NSInteger IntegerInRange(NSString *value, NSInteger minimum, NSInteger maximum) {
    NSScanner *scanner = [NSScanner scannerWithString:value ?: @""];
    NSInteger result = 0;
    return [scanner scanInteger:&result] && scanner.isAtEnd && result >= minimum && result <= maximum ? result : 0;
}

static void AfterDismissal(UIViewController *presenter, dispatch_block_t present) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *closing = presenter.presentedViewController;
        if (closing.isBeingDismissed && [closing.transitionCoordinator
            animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
                present();
            }]) return;
        present();
    });
}

void YTKDriveShowExportOptions(UIViewController *presenter, NSURL *videoURL) {
    AfterDismissal(presenter, ^{
        if (ExportInProgress) {
            ShowResult(presenter, YTKACELocalized(@"A Drive export is already running."), nil);
            return;
        }
        BOOL directAvailable = YTKDriveClient.configurationProblem == nil;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSInteger interval = [defaults integerForKey:FrameIntervalKey] ?: 10;
        NSInteger size = [defaults integerForKey:FrameSizeKey] ?: 1280;
        UIAlertController *options = [UIAlertController alertControllerWithTitle:YTKDriveExportTitle()
            message:YTKACELocalized(@"Share a ZIP of the timed captions and JPG frames to Drive, or save it to Files.")
            preferredStyle:UIAlertControllerStyleAlert];
        [options addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.keyboardType = UIKeyboardTypeNumberPad;
            field.text = [@(interval) stringValue];
            field.placeholder = field.accessibilityLabel = YTKACELocalized(@"Frame interval in seconds (1–3600)");
        }];
        [options addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.keyboardType = UIKeyboardTypeNumberPad;
            field.text = [@(size) stringValue];
            field.placeholder = field.accessibilityLabel = YTKACELocalized(@"Longest edge in pixels (320–1920)");
        }];
        options.message = [options.message stringByAppendingFormat:@"\n\n%@\n%@",
            options.textFields[0].placeholder, options.textFields[1].placeholder];
        [options addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Cancel")
            style:UIAlertActionStyleCancel handler:nil]];
        __weak UIAlertController *weakOptions = options;
        void (^start)(BOOL) = ^(BOOL direct) {
                NSArray<UITextField *> *fields = weakOptions.textFields;
                if (fields.count != 2) return;
                NSInteger seconds = IntegerInRange(fields[0].text, 1, 3600);
                NSInteger pixels = IntegerInRange(fields[1].text, 320, 1920);
                AfterDismissal(presenter, ^{
                    if (!seconds || !pixels) {
                        ShowResult(presenter, YTKACELocalized(@"Enter a valid frame interval and pixel size."), nil);
                        return;
                    }
                    [defaults setInteger:seconds forKey:FrameIntervalKey];
                    [defaults setInteger:pixels forKey:FrameSizeKey];
                    StartExport(presenter, videoURL, (NSUInteger)seconds, (NSUInteger)pixels, direct);
                });
        };
        [options addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Share ZIP")
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { start(NO); }]];
        if (directAvailable) {
            [options addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Upload directly to Drive")
                style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { start(YES); }]];
        }
        [presenter presentViewController:options animated:YES completion:nil];
    });
}
