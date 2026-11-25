#import <Foundation/Foundation.h>
@interface CCKernelSession : NSObject
+ (BOOL)isCandidate;
+ (BOOL)isReady;
+ (NSDictionary *)prepare;
@end
