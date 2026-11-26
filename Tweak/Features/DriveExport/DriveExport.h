#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

BOOL YTKDriveCanExport(NSURL *url);
NSString *YTKDriveExportTitle(void);
void YTKDriveShowExportOptions(UIViewController *presenter, NSURL *videoURL);

NS_ASSUME_NONNULL_END
