#import "DriveExport.h"
#import "DriveClient.h"
#import "DriveMedia.h"
#import "../../Runtime/Localization.h"

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

static BOOL ExportVideo(NSURL *videoURL, NSUInteger interval, NSUInteger frameSize, YTKDriveClient *client,
                        void (^progress)(NSString *), NSString **uploadedFolder, NSError **error) {
    NSDictionary<NSString *, NSData *> *captions = YTKDriveCaptionFiles(videoURL,
        ^BOOL { return client.cancelled; }, error);
    if (!captions) return NO;

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoURL options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
    double duration = CMTimeGetSeconds(asset.duration);
    if (!std::isfinite(duration) || duration <= 0 || ![asset tracksWithMediaType:AVMediaTypeVideo].count) {
        if (error) *error = YTKDriveError(@"This download does not contain a readable video track.");
        return NO;
    }
    NSUInteger frameCount = (NSUInteger)ceil(duration / interval);
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.maximumSize = CGSizeMake(frameSize, frameSize);
    generator.requestedTimeToleranceBefore = CMTimeMake(1, 10);
    generator.requestedTimeToleranceAfter = CMTimeMake(1, 10);
    CMTime firstTime = kCMTimeInvalid;
    NSData *firstFrame = FrameAt(generator, 0, &firstTime, error);
    if (!firstFrame) return NO;

    NSArray<NSString *> *ids = [client fileIDs:1 + captions.count + frameCount + 1 error:error];
    if (!ids) return NO;
    NSString *folder = ids.firstObject;
    NSString *name = videoURL.lastPathComponent.stringByDeletingPathExtension;
    if (![client createFolder:[@"YTKACE - " stringByAppendingString:name] fileID:folder parent:nil error:error]) return NO;
    *uploadedFolder = folder;

    NSUInteger index = 1;
    for (NSString *filename in @[@"transcript.txt", @"transcript.vtt"]) {
        NSString *mime = [filename hasSuffix:@".vtt"] ? @"text/vtt" : @"text/plain";
        if (![client upload:captions[filename] name:filename mime:mime fileID:ids[index++] folder:folder error:error]) return NO;
    }

    NSMutableString *csv = [NSMutableString stringWithString:@"file,requested_time,actual_time\n"];
    for (NSUInteger frame = 0; frame < frameCount; frame++) {
        if (client.cancelled) return NO;
        NSError *frameError = nil;
        BOOL uploaded = NO;
        @autoreleasepool {
            NSUInteger seconds = frame * interval;
            CMTime actual = firstTime;
            NSData *jpeg = frame == 0 ? firstFrame : FrameAt(generator, seconds, &actual, &frameError);
            NSString *requested = YTKDriveTimestamp(seconds);
            NSString *filename = [NSString stringWithFormat:@"frame_%@.jpg",
                [requested stringByReplacingOccurrencesOfString:@":" withString:@"-"]];
            uploaded = jpeg && [client upload:jpeg name:filename mime:@"image/jpeg" fileID:ids[index]
                folder:folder error:&frameError];
            if (uploaded) {
                NSString *actualTime = CMTIME_IS_NUMERIC(actual) ? YTKDriveTimestamp(CMTimeGetSeconds(actual)) : @"";
                [csv appendFormat:@"%@,%@,%@\n", filename, requested, actualTime];
            }
        }
        if (!uploaded) {
            if (error) *error = frameError;
            return NO;
        }
        index++;
        if (frame == 0 || (frame + 1) % 5 == 0 || frame + 1 == frameCount) {
            progress([NSString stringWithFormat:YTKACELocalized(@"Uploaded %lu of %lu frames."),
                (unsigned long)(frame + 1), (unsigned long)frameCount]);
        }
    }
    return [client upload:[csv dataUsingEncoding:NSUTF8StringEncoding] name:@"frames.csv" mime:@"text/csv"
        fileID:ids[index] folder:folder error:error];
}

static void StartExport(UIViewController *presenter, NSURL *videoURL, NSUInteger interval, NSUInteger size) {
    if (ExportInProgress) return;
    ExportInProgress = YES;
    YTKDriveClient *client = [YTKDriveClient new];
    [client authorizeFrom:presenter complete:^(NSError *authError) {
        if (authError) {
            ExportInProgress = NO;
            [client cancel];
            ShowResult(presenter, authError.localizedDescription, nil);
            return;
        }
        UIAlertController *progress = [UIAlertController alertControllerWithTitle:YTKDriveExportTitle()
            message:YTKACELocalized(@"Reading captions and video…") preferredStyle:UIAlertControllerStyleAlert];
        [progress addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Cancel")
            style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) { [client cancel]; }]];
        [presenter presentViewController:progress animated:YES completion:nil];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error = nil;
            NSString *folder = nil;
            BOOL success = ExportVideo(videoURL, interval, size, client, ^(NSString *message) {
                dispatch_async(dispatch_get_main_queue(), ^{ progress.message = message; });
            }, &folder, &error);
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL cancelled = client.cancelled;
                [client cancel];
                ExportInProgress = NO;
                NSString *message = success ? YTKACELocalized(@"Captions and frames uploaded.") :
                    (cancelled ? YTKACELocalized(@"Drive export cancelled.") :
                     (error.localizedDescription ?: YTKACELocalized(@"Drive export failed.")));
                if (!success && folder.length) {
                    message = [message stringByAppendingFormat:@"\n%@",
                        YTKACELocalized(@"The Drive folder may contain files already uploaded.")];
                }
                dispatch_block_t finish = ^{ ShowResult(presenter, message, folder); };
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
    }];
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
        NSString *configurationProblem = YTKDriveClient.configurationProblem;
        if (configurationProblem) {
            ShowResult(presenter, configurationProblem, nil);
            return;
        }
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSInteger interval = [defaults integerForKey:FrameIntervalKey] ?: 10;
        NSInteger size = [defaults integerForKey:FrameSizeKey] ?: 1280;
        UIAlertController *options = [UIAlertController alertControllerWithTitle:YTKDriveExportTitle()
            message:YTKACELocalized(@"Upload timed captions and JPG frames to a new folder in My Drive.")
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
        [options addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Upload")
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
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
                    StartExport(presenter, videoURL, (NSUInteger)seconds, (NSUInteger)pixels);
                });
            }]];
        [presenter presentViewController:options animated:YES completion:nil];
    });
}
