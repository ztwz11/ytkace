#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSString *YTKDriveTimestamp(double seconds);
NSDictionary<NSString *, NSData *> *YTKDriveCaptionFilesFromCues(NSArray<NSDictionary *> *cues);
NSDictionary<NSString *, NSData *> * _Nullable YTKDriveCaptionFiles(NSURL *videoURL,
    BOOL (^cancelled)(void), NSError **error);

NS_ASSUME_NONNULL_END
