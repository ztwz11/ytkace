#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, YTKACEDownloadDestination) {
    YTKACEDownloadDestinationLibrary = 0,
    YTKACEDownloadDestinationPhotos = 1,
    YTKACEDownloadDestinationAsk = 2,
    YTKACEDownloadDestinationShare = 3,
    YTKACEDownloadDestinationZIP = 4,
};

FOUNDATION_EXPORT UIImage *YTKACEDownloadGlyphImage(void);

FOUNDATION_EXPORT void YTKACESaveVideoToPhotosFile(
    NSURL *url, void (^_Nullable completion)(BOOL success, NSError *_Nullable error));

// Shows the playlist download menu (download all or select videos, then
// quality) for a list of videos; items need a "videoId" key.
FOUNDATION_EXPORT void YTKACEPresentVideoListDownloadMenu(
    NSArray<NSDictionary *> *items, NSString *title, UIView *_Nullable source);

@interface YTKACEDownloadCoordinator : NSObject
+ (instancetype)sharedCoordinator;
@property(nonatomic, strong, nullable) id playerResponse;
- (void)showDownloadMenu;
- (void)showDownloadMenuFromButton:(nullable UIButton *)button;
- (void)showShortsDownloadMenuFromView:(UIView *)sourceView;
- (void)showDownloadMenuForResponse:(id)response
                        sourceView:(nullable UIView *)sourceView;
- (NSUInteger)activeJobCount;
- (BOOL)enqueueDownloadForResponse:(id)response
                           quality:(NSInteger)quality
                         audioOnly:(BOOL)audioOnly
                       destination:(YTKACEDownloadDestination)destination;
- (void)beginBatchSharing;
- (void)flushBatchSharingFromView:(nullable UIView *)sourceView;
- (void)resolveDestinationFromView:(nullable UIView *)sourceView
                         audioOnly:(BOOL)audioOnly
                              then:(void (^)(YTKACEDownloadDestination destination))handler;
- (NSDictionary *)nativeSheetAction:(NSString *)title
                               icon:(NSString *)icon
                            handler:(dispatch_block_t)handler;
- (void)presentPlaylistSheetWithTitle:(nullable NSString *)title
                             subtitle:(nullable NSString *)subtitle
                           sourceView:(nullable UIView *)sourceView
                              actions:(NSArray<NSDictionary *> *)actions;
@end

NS_ASSUME_NONNULL_END
