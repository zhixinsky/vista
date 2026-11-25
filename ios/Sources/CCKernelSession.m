#import "CCKernelSession.h"
#import "DriftKernelDirect.h"
#import "WQAccess.h"
#import <sys/utsname.h>
#import <TargetConditionals.h>

@implementation CCKernelSession
static BOOL attempted;
static BOOL ready;
+ (BOOL)isCandidate {
#if TARGET_OS_SIMULATOR
    return NO;
#else
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    BOOL inBand = (v.majorVersion == 17 && v.minorVersion <= 7) ||
        (v.majorVersion == 18 && (v.minorVersion < 7 ||
         (v.minorVersion == 7 && v.patchVersion <= 1)));
    if (!inBand) return NO;
    struct utsname info;
    if (uname(&info) != 0) return NO;
    NSString *model = [NSString stringWithUTF8String:info.machine];
    if (![model hasPrefix:@"iPhone"]) return NO;
    NSArray *parts = [[model substringFromIndex:6] componentsSeparatedByString:@","];
    if (parts.count != 2) return NO;
    NSInteger family = [parts[0] integerValue];
    return family >= 11 && family <= 17 && [parts[1] integerValue] > 0;
#endif
}
+ (BOOL)isReady { @synchronized(self) { return ready; } }
+ (NSDictionary *)prepare {
    @synchronized(self) {
        if (ready) return @{@"ok": @YES, @"backend": @"kernelDirect"};
        NSString *failure = nil;
        if (![self isCandidate]) failure = @"当前系统或机型不在 iOS 17/18 实验后端范围内。";
        else if (NSThread.isMainThread) failure = @"内核会话必须在后台线程启动。";
        else if (attempted) failure = @"本进程的内核会话启动失败，请退出 App 后重新打开。";
        if (failure) return @{@"ok": @NO, @"message": failure};
        attempted = YES;
        wq_log(@"KernelDirect: starting iOS 17/18 session");
        int code = kexploit_opa334();
        if (code == 0) {
            uint64_t process = proc_self();
            if (process) {
                code = sandbox_escape(process);
                ready = code == 0;
            } else code = -1;
        }
        wq_log(@"KernelDirect: session result %d, ready=%d", code, ready);
        return ready ? @{@"ok": @YES, @"backend": @"kernelDirect"}
            : @{@"ok": @NO, @"backend": @"kernelDirect", @"message": [NSString stringWithFormat:@"iOS 17/18 会话启动失败（%d），请退出 App 后重试。", code]};
    }
}
@end
