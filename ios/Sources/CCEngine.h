// SPDX-License-Identifier: GPL-3.0-or-later
#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface CCEngine : NSObject
+ (NSString *)appGroup;
+ (NSString *)logs;
+ (void)cancelScan;
+ (NSDictionary *)discover:(BOOL)allowFullScan;
+ (nullable UIImage *)decodeBitmap:(NSData *)data;
+ (nullable UIImage *)preview:(NSString *)path;
+ (NSDictionary *)encode:(UIImage *)image to:(NSString *)path;
+ (NSDictionary *)saveSnapshot:(NSArray<NSDictionary *> *)targets;
+ (NSArray<NSDictionary *> *)snapshots;
+ (NSDictionary *)restoreDefaults:(NSDictionary<NSString *, NSData *> *)images;
+ (NSDictionary *)clearWallpaperImages;
+ (NSDictionary *)apply:(NSDictionary *)target source:(NSString *)source;
+ (NSDictionary *)verify:(NSDictionary *)target source:(NSString *)source;
// Pure recovery selection, shared by startup maintenance and regression tests.
+ (NSDictionary *)cacheRecoveryPlan:(NSDictionary *)records files:(NSArray *)files root:(NSString *)root NS_SWIFT_NAME(cacheRecoveryPlan(records:files:root:));
+ (NSDictionary *)recoverySource:(nullable NSData *)backup loose:(nullable NSData *)loose NS_SWIFT_NAME(recoverySource(backup:loose:));
+ (NSArray *)wallpaperDiagnosticHistory;
+ (NSDictionary *)selfCheck;
+ (NSDictionary *)maintainWallpaperCache:(NSDictionary<NSString *, NSData *> *)defaults;
+ (NSDictionary *)repairCache:(NSDictionary *)target;
+ (NSDictionary *)unlockWallpapers;
+ (NSArray<NSDictionary *> *)backups;
+ (NSDictionary *)restore:(NSString *)backup;

@end
NS_ASSUME_NONNULL_END
