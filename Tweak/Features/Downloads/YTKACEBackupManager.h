#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^YTKACEBackupCreationCompletion)(NSURL * _Nullable URL,
                                                NSError * _Nullable error);
typedef void (^YTKACEBackupRestoreCompletion)(NSError * _Nullable error);

// Writes existing files to one ZIP. Each entry provides its file URL and archive name.
FOUNDATION_EXPORT BOOL YTKACEWriteStoredZip(NSURL *outputURL,
    NSArray<NSDictionary *> *entries, NSError **error);

@interface YTKACEBackupManager : NSObject

+ (void)createBackupWithCompletion:(YTKACEBackupCreationCompletion)completion;
+ (void)restoreBackupFromURL:(NSURL *)URL
                  completion:(YTKACEBackupRestoreCompletion)completion;

@end

NS_ASSUME_NONNULL_END
