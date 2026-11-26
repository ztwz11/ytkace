#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTKDriveClient : NSObject
@property(atomic, readonly, getter=isCancelled) BOOL cancelled;
+ (nullable NSString *)configurationProblem;
- (void)authorizeFrom:(UIViewController *)presenter
             complete:(void (^)(NSError * _Nullable error))complete;
- (nullable NSArray<NSString *> *)fileIDs:(NSUInteger)count error:(NSError **)error;
- (BOOL)createFolder:(NSString *)name fileID:(NSString *)fileID
              parent:(nullable NSString *)parent error:(NSError **)error;
- (BOOL)upload:(NSData *)data name:(NSString *)name mime:(NSString *)mime
        fileID:(NSString *)fileID folder:(NSString *)folder error:(NSError **)error;
- (void)cancel;
@end

NSError *YTKDriveError(NSString *message);

NS_ASSUME_NONNULL_END
