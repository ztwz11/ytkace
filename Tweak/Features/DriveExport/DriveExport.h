#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

BOOL YTKDriveCanExport(NSURL *url);
NSString *YTKDriveExportTitle(void);
void YTKDriveShowExportOptions(UIViewController *presenter, NSURL *videoURL);
void YTKDriveShowFrameSettings(UIViewController *presenter);
void YTKDriveCreateDownloadZIP(NSURL *videoURL, NSArray<NSDictionary *> * _Nullable cues, NSProgress *job,
    void (^report)(NSString *stage), void (^complete)(NSURL * _Nullable archive, NSError * _Nullable error));

NS_ASSUME_NONNULL_END
