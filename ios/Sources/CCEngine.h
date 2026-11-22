// SPDX-License-Identifier: GPL-3.0-or-later
#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface CCEngine : NSObject
+ (NSString *)appGroup;
+ (NSString *)logs;
+ (void)cancelScan;
+ (NSDictionary *)discover:(BOOL)allowFullScan;
+ (nullable UIImage *)preview:(NSString *)path;
+ (NSDictionary *)encode:(UIImage *)image to:(NSString *)path;
+ (NSDictionary *)apply:(NSDictionary *)target source:(NSString *)source;
+ (NSDictionary *)verify:(NSDictionary *)target source:(NSString *)source;
+ (NSDictionary *)repairCache:(NSDictionary *)target;
+ (NSDictionary *)unlockWallpapers;
+ (NSArray<NSDictionary *> *)backups;
+ (NSDictionary *)restore:(NSString *)backup;

@end
NS_ASSUME_NONNULL_END
