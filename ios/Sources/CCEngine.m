// SPDX-License-Identifier: GPL-3.0-or-later
#import "CCEngine.h"
#import "CCKernelSession.h"
#import "WQAccess.h"
#import <dlfcn.h>
#import <CommonCrypto/CommonDigest.h>
#import <errno.h>
#import <fcntl.h>
#import <objc/message.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const CCIdentifier = @"com.apple.CarPlayWallpaper";
static NSString *const CCParent = @"/private/var/mobile/Containers/Data/Application";
static BOOL CCAllowFullScan;
static NSMutableSet<NSString *> *CCRoots;
static WQScanCancellation *CCScan;
static BOOL CCConfirm(NSString *what, int64_t ids, double seconds) {
    wq_log(@"CarVista scan: %@, %lld ids, estimate %.0f seconds", what, ids, seconds);
    return CCAllowFullScan;
}
static void CCProgress(int64_t done, int64_t total, BOOL finished) {
    if (finished) wq_log(@"CarVista container scan finished: %lld/%lld", done, total);
}
static NSDictionary *CCFail(NSString *text) { return @{@"ok": @NO, @"message": text ?: @"操作失败"}; }
static NSString *CCCanonical(NSString *path) {
    NSString *p = path.stringByStandardizingPath;
    if ([p hasPrefix:@"/var/"]) p = [@"/private" stringByAppendingString:p];
    return p;
}
static void CCSetup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CCRoots = NSMutableSet.new;
        wq_set_container_label_resolver(wq_bundle_id_for_container);
        wq_set_container_list_provider(wq_ls_container_paths);
        wq_set_full_scan_ui(CCConfirm, CCProgress);
    });
}
static BOOL CCRegisterRoot(NSString *path) {
    NSString *p = CCCanonical(path);
    if (![p.stringByDeletingLastPathComponent isEqualToString:CCParent]) return NO;
    if (![[NSUUID alloc] initWithUUIDString:p.lastPathComponent]) return NO;
    if (![wq_container_label(p) isEqualToString:CCIdentifier]) return NO;
    @synchronized (CCRoots) { [CCRoots addObject:p]; }
    return YES;
}
static NSString *CCKeptDirectory(NSString *root);
static NSString *CCWallpaperDirectory(NSString *root) {
    return [CCCanonical(root) stringByAppendingPathComponent:@"Library/Caches/MappedImageCache/com.apple.CarPlayApp.wallpaper-images"];
}
// Recreate only the fixed cache hierarchy in an identity-checked container.
// Validate top-down so an unavailable parent or symlink is never followed.
static BOOL CCEnsureWallpaperDirectory(NSString *root, NSString **errorText) {
    if (!CCRegisterRoot(root)) {
        if (errorText) *errorText = @"壁纸容器身份无法确认。";
        return NO;
    }
    NSString *cursor = CCCanonical(root);
    NSArray *parts = @[@"", @"Library", @"Caches", @"MappedImageCache", @"com.apple.CarPlayApp.wallpaper-images"];
    for (NSString *part in parts) {
        if (part.length) cursor = [cursor stringByAppendingPathComponent:part];
        struct stat st;
        errno = 0;
        if (!wq_stat(cursor, &st)) {
            if (!part.length || errno != ENOENT) {
                if (errorText) *errorText = @"壁纸缓存目录无法访问，未重建。";
                return NO;
            }
            BOOL created = wq_create_dir(cursor, errorText);
            // Another process may have created it. Recheck its type either way.
            if (!wq_stat(cursor, &st)) return NO;
            if (!created && errorText) *errorText = nil;
        }
        if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) {
            if (errorText) *errorText = @"壁纸缓存路径不是普通目录，未重建。";
            return NO;
        }
    }
    return YES;
}
static BOOL CCWallpaperName(NSString *name) {
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pattern = [NSRegularExpression regularExpressionWithPattern:@"^CARWallpaper[A-Za-z0-9]+-(Dark|Light)-[0-9]+\\.cpbitmap$" options:0 error:nil]; });
    return [pattern firstMatchInString:name options:0 range:NSMakeRange(0, name.length)] != nil;
}

static BOOL CCAllowed(NSString *path) {
    NSString *p = CCCanonical(path);
    if (!CCWallpaperName(p.lastPathComponent)) return NO;
    NSArray *roots;
    @synchronized (CCRoots) { roots = CCRoots.allObjects; }
    for (NSString *root in roots) {
        // Recheck identity on every mutation; never accept an arbitrary path.
        if (![p.stringByDeletingLastPathComponent isEqualToString:CCWallpaperDirectory(root)] || ![wq_container_label(root) isEqualToString:CCIdentifier]) continue;
        NSString *cursor = p;
        while ([cursor hasPrefix:[root stringByAppendingString:@"/"]]) {
            struct stat st;
            if (!wq_stat(cursor, &st) || S_ISLNK(st.st_mode)) return NO;
            cursor = cursor.stringByDeletingLastPathComponent;
        }
        return YES;
    }
    return NO;
}
static UIImage *CCDecode(NSData *data) {
    if (!data.length) return nil;
    typedef CFArrayRef (*Decoder)(CFDataRef, void *, int, void *);
    static Decoder decode;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/AppSupport.framework/AppSupport", RTLD_LAZY);
        if (handle) {
            decode = (Decoder)dlsym(handle, "CPBitmapCreateImagesFromData");
            if (!decode) decode = (Decoder)dlsym(handle, "_CPBitmapCreateImagesFromData");
        }
        if (!decode) decode = (Decoder)dlsym(RTLD_DEFAULT, "CPBitmapCreateImagesFromData");
        if (!decode) decode = (Decoder)dlsym(RTLD_DEFAULT, "_CPBitmapCreateImagesFromData");
    });
    if (!decode) return nil;
    CFArrayRef array = decode((__bridge CFDataRef)data, NULL, 1, NULL);
    if (!array) return nil;
    UIImage *image = nil;
    if (CFGetTypeID(array) == CFArrayGetTypeID() && CFArrayGetCount(array)) {
        CFTypeRef first = CFArrayGetValueAtIndex(array, 0);
        if (first && CFGetTypeID(first) == CGImageGetTypeID()) image = [UIImage imageWithCGImage:(CGImageRef)first];
    }
    CFRelease(array);
    return image;
}
static NSString *CCNotePath(NSString *root) {
    return [root stringByAppendingPathComponent:@"Library/Caches/CarVista.note"];
}
// The note lives in the CarPlay container, which is not removed when CarVista is
// reinstalled. UserDefaults is wiped by a reinstall, so the note is what lets
// the next install choose the same wallpaper container.
static BOOL CCNoteConfirms(NSString *root) {
    NSData *data = wq_read(CCNotePath(root), 1024, NULL);
    if (!data.length) return NO;
    NSString *saved = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [CCCanonical(saved) isEqualToString:CCCanonical(root)];
}
static void CCRemember(NSString *root) {
    NSString *canonical = CCCanonical(root);
    [NSUserDefaults.standardUserDefaults setObject:canonical forKey:@"CCContainer"];
    NSData *data = [canonical dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;
    NSString *note = CCNotePath(canonical);
    if (!wq_write(note, data, NULL)) wq_create_file(note, data, NULL);
}
static NSString *CCKeptDirectory(NSString *root) {
    return [root stringByAppendingPathComponent:@"Documents/CarVista"];
}
static NSArray *CCWalkFrom(NSString *root, NSString *start, NSString *skip, NSMutableArray *issues, WQScanCancellation *scan) {
    NSMutableArray *queue = [NSMutableArray arrayWithObject:start];
    NSMutableArray *files = NSMutableArray.new;
    NSMutableSet *seen = NSMutableSet.new;
    NSUInteger count = 0;
    while (queue.count && count < 20000 && !scan.isCancelled) {
        @autoreleasepool {
        NSString *dir = queue.lastObject;
        [queue removeLastObject];
        NSString *error = nil;
        NSArray *names = wq_list(dir, &error);
        if (!names) { [issues addObject:[NSString stringWithFormat:@"%@: %@", dir, error ?: @"无法列出目录"]]; continue; }
        for (NSString *listed in names) {
            NSString *name = listed;
            if (scan.isCancelled) break;
            if (++count > 20000) break;
            if ([name isEqualToString:@"."] || [name isEqualToString:@".."] || [name containsString:@"/"]) continue;
            NSString *path = [dir stringByAppendingPathComponent:name];
            if (skip.length && [CCCanonical(path) hasPrefix:skip]) continue;
            struct stat st;
            if (!wq_stat(path, &st)) { [issues addObject:[NSString stringWithFormat:@"无法检查 %@", path]]; continue; }
            if (S_ISLNK(st.st_mode)) {
                char link[1024];
                ssize_t n = readlink(path.fileSystemRepresentation, link, sizeof(link) - 1);
                if (n <= 0) continue;
                link[n] = 0;
                NSString *target = [NSString stringWithUTF8String:link];
                if (![target hasPrefix:@"/"]) target = [dir stringByAppendingPathComponent:target];
                target = CCCanonical(target);
                if (![target hasPrefix:[CCCanonical(root) stringByAppendingString:@"/"]]) continue;
                path = target;
                name = path.lastPathComponent;
                if (!wq_stat(path, &st) || !S_ISREG(st.st_mode)) continue;
            }
            if (S_ISDIR(st.st_mode)) {
                if (path.pathComponents.count - start.pathComponents.count < 10) [queue addObject:path];
                else [issues addObject:[NSString stringWithFormat:@"达到目录深度限制：%@", path]];
            } else if (S_ISREG(st.st_mode) && [name.pathExtension.lowercaseString isEqualToString:@"cpbitmap"]) {
                @autoreleasepool {
                if (files.count >= 200) { [issues addObject:@"达到 200 个缓存文件上限"]; return files; }
                path = CCCanonical(path);
                if ([seen containsObject:path]) continue;
                [seen addObject:path];
                NSDictionary *version = wq_file_version(path);
                if (!version) continue;
                UIImage *image = CCDecode(wq_read(path, 0, &error));
                NSString *mode = [name.lowercaseString containsString:@"dark"] ? @"深色" : [name.lowercaseString containsString:@"light"] ? @"浅色" : @"未知";
                [files addObject:@{@"path":path, @"name":name, @"mode":mode, @"bytes":@(st.st_size),
                    @"width":@(image.CGImage ? CGImageGetWidth(image.CGImage) : 0),
                    @"height":@(image.CGImage ? CGImageGetHeight(image.CGImage) : 0), @"version":version}];
                if (!image) [issues addObject:[NSString stringWithFormat:@"无法解码 %@，已禁止替换", name]];
                }
            }
        }
        }
    }
    if (queue.count || count > 20000) [issues addObject:@"达到 20000 个目录项上限，扫描不完整"];
    return files;
}
static NSArray *CCWalkContainer(NSString *root, NSMutableArray *issues, WQScanCancellation *scan) {
    NSString *directory = CCWallpaperDirectory(root);
    struct stat st;
    if (!wq_stat(directory, &st) || !S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) {
        [issues addObject:@"未找到车机壁纸图片缓存目录"];
        NSString *caches = [CCCanonical(root) stringByAppendingPathComponent:@"Library/Caches"];
        NSUInteger misplaced = 0;
        for (NSString *name in wq_list(caches, NULL)) {
            if (!CCWallpaperName(name)) continue;
            struct stat candidate;
            NSString *path = [caches stringByAppendingPathComponent:name];
            if (wq_stat(path, &candidate) && S_ISREG(candidate.st_mode) && !S_ISLNK(candidate.st_mode)) misplaced++;
        }
        if (misplaced) {
            NSString *message = [NSString stringWithFormat:@"Caches 根目录发现 %lu 个壁纸文件，但 CarPlay 图片缓存目录不可用；请使用本机修复副本补回原目录。", (unsigned long)misplaced];
            [issues addObject:message];
            wq_log(@"CarVista: %@ (%@)", message, caches);
        }
        return @[];
    }
    NSArray *files = CCWalkFrom(root, directory, nil, issues, scan);
    NSPredicate *valid = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *file, NSDictionary *bindings) {
        NSString *path = file[@"path"];
        return [path.stringByDeletingLastPathComponent isEqualToString:directory] && CCWallpaperName(path.lastPathComponent) && CCAllowed(path);
    }];
    return [files filteredArrayUsingPredicate:valid];
}

static void CCKeepWallpapers(NSString *root, NSArray *files);
static BOOL CCKeepData(NSString *root, NSString *path, NSData *data);
static NSArray *CCIncludeKnownTargets(NSString *root, NSArray *files);
static NSString *CCRootForPath(NSString *path);

@implementation CCEngine
+ (NSString *)appGroup { CCSetup(); return wq_app_group() ?: @""; }
+ (NSString *)logs { return wq_log_text(); }
+ (void)cancelScan {
    @synchronized (CCEngine.class) { [CCScan cancel]; }
    wq_full_scan_stop();
}
+ (NSDictionary *)discover:(BOOL)allowFullScan {
    CCSetup();
    WQScanCancellation *scan = WQScanCancellation.new;
    @synchronized (CCEngine.class) { CCScan = scan; }
    NSInteger systemMajor = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    if ((systemMajor == 17 || systemMajor == 18) && ![CCKernelSession isCandidate])
        return CCFail(@"当前系统或机型不在 iOS 17.0–17.7.x / 18.0–18.7.1 方案范围内。");
    // Explicit discover/self-check calls share the iOS 17/18 session.
    // iOS 26/27 never enter this branch and retain WQFiles authorization.
    if ([CCKernelSession isCandidate] && ![CCKernelSession isReady]) {
        NSDictionary *session = [CCKernelSession prepare];
        if (![session[@"ok"] boolValue]) return session;
    }
    if (![CCKernelSession isReady] && !wq_app_group().length) return CCFail(@"签名未提供 App Group。请用支持 App Group 的签名方式重新安装；通配符证书通常不满足要求。");
    CCAllowFullScan = allowFullScan;
    @synchronized (CCRoots) { [CCRoots removeAllObjects]; }
    NSString *remembered = [NSUserDefaults.standardUserDefaults stringForKey:@"CCContainer"];
    if (remembered.length && CCRegisterRoot(remembered)) {
        NSString *root = CCCanonical(remembered);
        NSMutableArray *issues = [NSMutableArray new];
        NSArray *files = CCWalkContainer(root, issues, scan);
        if (scan.isCancelled) return CCFail(@"已停止查找，可随时重试。");
        if (files.count) {
            CCAllowFullScan = NO;
            CCRemember(root);
            CCKeepWallpapers(root, files);
            files = CCIncludeKnownTargets(root, files);
            return @{@"ok":@YES, @"root":root, @"files":files, @"issues":issues,
                @"message":@"已找到壁纸缓存；请选择单个目标进行替换。"};
        }
    }
    NSMutableArray<NSString *> *candidates = [NSMutableArray new];
    wq_display_names_reset_miss();
    NSArray *paths = wq_ls_container_paths(nil);
    for (NSString *path in paths) {
        if (![wq_bundle_id_for_container(path) isEqualToString:CCIdentifier] || !CCRegisterRoot(path)) continue;
        NSString *canonical = CCCanonical(path);
        if ([canonical isEqualToString:CCCanonical(remembered)]) continue;
        if (CCNoteConfirms(canonical)) [candidates insertObject:canonical atIndex:0];
        else [candidates addObject:canonical];
    }
    if (!candidates.count && !CCRoots.count) {
        NSArray *containers;
        if ([CCKernelSession isReady]) {
            // A prepared native-access session does not use App Group tokens.
            NSArray *names = wq_list(CCParent, NULL);
            NSMutableArray *nativePaths = NSMutableArray.new;
            for (NSString *name in names) {
                if (scan.isCancelled) break;
                if ([[NSUUID alloc] initWithUUIDString:name])
                    [nativePaths addObject:[CCParent stringByAppendingPathComponent:name]];
            }
            containers = nativePaths;
        } else {
            containers = wq_enumerate(CCParent, 0, scan, nil);
        }
        wq_load_display_names();
        for (NSString *path in containers) {
            if (scan.isCancelled) break;
            if (!CCRegisterRoot(path)) continue;
            [candidates addObject:CCCanonical(path)];
            break;
        }
    }
    CCAllowFullScan = NO;
    if (scan.isCancelled) return CCFail(@"已停止查找，可随时重试。");
    if (!candidates.count && !CCRoots.count) return CCFail(allowFullScan ? @"未能确认 CarPlayWallpaper 容器。请导出日志；可能是签名、访问被拒绝或系统结构变化。" : @"快速定位未找到容器。首次使用可尝试完整扫描，可能需要数分钟。");
    NSString *root = remembered.length ? CCCanonical(remembered) : nil;
    NSArray *files = @[];
    NSMutableArray *issues = [NSMutableArray new];
    for (NSString *candidate in candidates) {
        NSMutableArray *foundIssues = [NSMutableArray new];
        NSArray *found = CCWalkContainer(candidate, foundIssues, scan);
        if (scan.isCancelled) return CCFail(@"已停止查找，可随时重试。");
        if (!root) root = candidate;
        if (found.count) {
            root = candidate;
            files = found;
            issues = foundIssues;
            break;
        }
        if (!remembered.length) { root = candidate; issues = foundIssues; }
    }
    if (!root) return CCFail(@"未能确认 CarPlayWallpaper 容器。请导出日志；可能是签名、访问被拒绝或系统结构变化。");
    @synchronized (CCRoots) { [CCRoots removeAllObjects]; }
    CCRegisterRoot(root);
    if (!files.count) {
        issues = [NSMutableArray new];
        files = CCWalkContainer(root, issues, scan);
    }
    if (scan.isCancelled) return CCFail(@"已停止查找，可随时重试。");
    if (files.count) {
        CCRemember(root);
        CCKeepWallpapers(root, files);
    }
    files = CCIncludeKnownTargets(root, files);
    NSString *message = files.count
        ? @"已读取壁纸位置；深色与浅色的状态分别显示。"
        : @"容器已找到，但没有可识别的 CPBitmap。请先在车机切换内置壁纸后重试；也可能是格式变化。";
    return @{@"ok":@YES, @"root":root, @"files":files, @"issues":issues, @"message":message};
}
+ (UIImage *)decodeBitmap:(NSData *)data { return CCDecode(data); }
+ (UIImage *)preview:(NSString *)path {
    if (!CCAllowed(path)) return nil;
    return CCDecode(wq_read(path, 0, NULL));
}
+ (NSDictionary *)encode:(UIImage *)image to:(NSString *)path {
    if (!image.CGImage || image.size.width < 1 || image.size.height < 1) return CCFail(@"图片无效");
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (![path.stringByStandardizingPath hasPrefix:[documents stringByAppendingString:@"/"]]) return CCFail(@"导出路径必须在本应用内");
    SEL selector = NSSelectorFromString(@"writeToCPBitmapFile:flags:");
    if (![image respondsToSelector:selector]) return CCFail(@"当前系统不提供 CPBitmap 编码接口");
    BOOL ok = ((BOOL(*)(id, SEL, NSString *, int))objc_msgSend)(image, selector, path, 0);
    UIImage *decoded = ok ? CCDecode([NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil]) : nil;
    if (!decoded.CGImage || CGImageGetWidth(decoded.CGImage) != CGImageGetWidth(image.CGImage) || CGImageGetHeight(decoded.CGImage) != CGImageGetHeight(image.CGImage)) {
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        return CCFail(@"CPBitmap 回读尺寸校验失败，未写入系统缓存");
    }
    return @{@"ok":@YES, @"path":path};
}
static NSString *CCOriginalsDirectory(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"Originals"];
}
static BOOL CCOriginalName(NSString *name) {
    if (name.length < 10 || name.length > 120 || ![name.lowercaseString hasSuffix:@".cpbitmap"]) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"];
    return [name rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}
static NSString *CCRootForPath(NSString *path) {
    NSString *canonical = CCCanonical(path);
    NSArray *roots;
    @synchronized (CCRoots) { roots = CCRoots.allObjects; }
    for (NSString *root in roots) {
        NSString *prefix = [CCCanonical(root) stringByAppendingString:@"/"];
        if ([canonical hasPrefix:prefix]) return CCCanonical(root);
    }
    return nil;
}
// Repair records use full canonical paths, never a basename guessed into Caches.
// Kept separately from original-wallpaper backups; scanning never writes system files.
static NSString *CCRepairDirectory(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"CacheRepairs"];
}
static NSMutableDictionary *CCRepairRecords(void) {
    NSData *json = [NSData dataWithContentsOfFile:[CCRepairDirectory() stringByAppendingPathComponent:@"index.json"]];
    id records = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    return [records isKindOfClass:NSDictionary.class] ? [records mutableCopy] : NSMutableDictionary.new;
}
static NSString *CCDigest(NSData *data) {
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    for (NSUInteger offset = 0; offset < data.length;) {
        CC_LONG count = (CC_LONG)MIN(data.length - offset, (NSUInteger)65536);
        CC_SHA256_Update(&context, (const uint8_t *)data.bytes + offset, count);
        offset += count;
    }
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(bytes, &context);
    NSMutableString *digest = NSMutableString.new;
    for (NSUInteger i = 0; i < sizeof(bytes); i++) [digest appendFormat:@"%02x", bytes[i]];
    return digest;
}
static NSData *CCRepairData(NSDictionary *record) {
    if (![record isKindOfClass:NSDictionary.class]) return nil;
    NSString *key = record[@"key"];
    if (![key isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:key]) return nil;
    NSData *data = [NSData dataWithContentsOfFile:[CCRepairDirectory() stringByAppendingPathComponent:key]];
    return data.length && [CCDigest(data) isEqual:record[@"digest"]] && CCDecode(data) ? data : nil;
}
static NSString *CCWallpaperSlot(NSString *path) {
    NSString *name = path.lastPathComponent;
    if (!CCWallpaperName(name)) return nil;
    // Preserve colour + appearance; the final numeric component is a system version.
    return [name substringToIndex:[name rangeOfString:@"-" options:NSBackwardsSearch].location];
}
static BOOL CCKeepData(NSString *root, NSString *path, NSData *data) {
    path = CCCanonical(path);
    if (!root.length || ![wq_container_label(root) isEqualToString:CCIdentifier] ||
        ![path.stringByDeletingLastPathComponent isEqualToString:CCWallpaperDirectory(root)] ||
        !CCWallpaperName(path.lastPathComponent) || !data.length || !CCDecode(data)) return NO;
    NSMutableDictionary *records = CCRepairRecords();
    NSDictionary *old = records[path];
    NSString *digest = CCDigest(data);
    if ([old isKindOfClass:NSDictionary.class] && [old[@"digest"] isEqual:digest] && CCRepairData(old)) return YES;
    NSString *directory = CCRepairDirectory();
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    NSString *key = NSUUID.UUID.UUIDString;
    NSString *copy = [directory stringByAppendingPathComponent:key];
    if (![data writeToFile:copy options:NSDataWritingAtomic error:nil]) return NO;
    if (![[NSData dataWithContentsOfFile:copy] isEqualToData:data]) return NO;
    // Each appearance has its own latest successful copy. Retire older filename
    // versions for this slot without changing any other colour or appearance.
    for (NSString *previous in records.allKeys) {
        NSDictionary *entry = records[previous];
        if ([entry isKindOfClass:NSDictionary.class] && [entry[@"root"] isEqual:CCCanonical(root)] &&
            [CCWallpaperSlot(previous) isEqual:CCWallpaperSlot(path)]) [records removeObjectForKey:previous];
    }
    records[path] = @{@"root":CCCanonical(root), @"key":key, @"digest":digest};
    NSData *json = [NSJSONSerialization dataWithJSONObject:records options:NSJSONWritingSortedKeys error:nil];
    BOOL saved = [json writeToFile:[directory stringByAppendingPathComponent:@"index.json"] options:NSDataWritingAtomic error:nil];
    if (saved && [old isKindOfClass:NSDictionary.class]) {
        NSString *oldKey = old[@"key"];
        if ([oldKey isKindOfClass:NSString.class] && [[NSUUID alloc] initWithUUIDString:oldKey])
            [NSFileManager.defaultManager removeItemAtPath:[directory stringByAppendingPathComponent:oldKey] error:nil];
    }
    return saved;
}
static void CCKeepWallpapers(NSString *root, NSArray *files) {
    for (NSDictionary *file in files) {
        NSString *path = file[@"path"];
        BOOL preserved = NO;
        NSDictionary *records = CCRepairRecords();
        for (NSString *savedPath in records) {
            NSDictionary *record = records[savedPath];
            if ([record isKindOfClass:NSDictionary.class] && [record[@"root"] isEqual:CCCanonical(root)] &&
                [CCWallpaperSlot(savedPath) isEqual:CCWallpaperSlot(path)]) {
                preserved = YES;
                break;
            }
        }
        if (preserved) continue;
        NSDictionary *before = wq_file_version(path);
        if ([file[@"version"] isKindOfClass:NSDictionary.class] && ![file[@"version"] isEqual:before]) continue;
        NSData *data = wq_read(path, 0, NULL);
        if (before && [before isEqual:wq_file_version(path)] && !CCKeepData(root, path, data))
            wq_log(@"CarVista: could not preserve repair copy for %@", path);
    }
}
static NSArray *CCIncludeKnownTargets(NSString *root, NSArray *files) {
    // Upgrade existing installations using their exact saved target paths. Never
    // infer missing filenames from a colour or a sibling's system-version suffix.
    NSDictionary *known = CCRepairRecords();
    NSString *originals = CCOriginalsDirectory();
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:originals error:nil]) {
        if (![name hasSuffix:@".cpbitmap.json"]) continue;
        NSData *json = [NSData dataWithContentsOfFile:[originals stringByAppendingPathComponent:name]];
        id item = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
        if (![item isKindOfClass:NSDictionary.class] || ![item[@"target"] isKindOfClass:NSString.class]) continue;
        NSString *path = CCCanonical(item[@"target"]);
        if (known[path] || ![path.lastPathComponent isEqualToString:name.stringByDeletingPathExtension]) continue;
        BOOL hasSlot = NO;
        for (NSString *savedPath in known) {
            NSDictionary *record = known[savedPath];
            if ([record isKindOfClass:NSDictionary.class] && [record[@"root"] isEqual:CCCanonical(root)] &&
                [CCWallpaperSlot(savedPath) isEqual:CCWallpaperSlot(path)]) { hasSlot = YES; break; }
        }
        if (hasSlot) continue;
        NSData *original = [NSData dataWithContentsOfFile:[originals stringByAppendingPathComponent:name.stringByDeletingPathExtension]];
        CCKeepData(root, path, original);
    }
    NSMutableArray *result = [files mutableCopy];
    NSMutableSet *seen = NSMutableSet.new;
    for (NSDictionary *file in files) [seen addObject:CCCanonical(file[@"path"])];
    NSDictionary *records = CCRepairRecords();
    for (NSString *path in records) {
        NSDictionary *record = records[path];
        if (![record isKindOfClass:NSDictionary.class] || ![record[@"root"] isEqual:CCCanonical(root)] ||
            ![path.stringByDeletingLastPathComponent isEqualToString:CCWallpaperDirectory(root)] || !CCWallpaperName(path.lastPathComponent) || [seen containsObject:path]) continue;
        struct stat st;
        errno = 0;
        BOOL exists = wq_stat(path, &st);
        BOOL missing = !exists && errno == ENOENT;
        BOOL repairable = missing && CCRepairData(record) != nil;
        NSString *name = path.lastPathComponent;
        NSString *mode = [name.lowercaseString containsString:@"dark"] ? @"深色" : [name.lowercaseString containsString:@"light"] ? @"浅色" : @"未知";
        [result addObject:@{@"path":path, @"name":name, @"mode":mode, @"width":@0, @"height":@0,
            @"missing":@(missing), @"repairable":@(repairable),
            @"status":missing ? (repairable ? @"文件暂缺，可从本机副本补回" : @"文件暂缺，尚无可用的修复副本") : @"本次未能读取此位置，请重新查找"}];
    }
    return result;
}
static NSString *CCOriginalDisplayName(NSString *filename) {
    NSDictionary *colors = @{@"Blue": @"蓝色", @"Purple": @"紫色", @"Gray": @"灰色", @"Green": @"绿色",
        @"Brown": @"棕色", @"Red": @"红色", @"Black": @"黑色"};
    NSString *label = filename.stringByDeletingPathExtension;
    for (NSString *key in colors) {
        if ([label localizedCaseInsensitiveContainsString:key]) label = [label stringByReplacingOccurrencesOfString:key withString:colors[key]];
    }
    label = [label stringByReplacingOccurrencesOfString:@"-Light" withString:@" · 浅色" options:NSCaseInsensitiveSearch range:NSMakeRange(0, label.length)];
    label = [label stringByReplacingOccurrencesOfString:@"-Dark" withString:@" · 深色" options:NSCaseInsensitiveSearch range:NSMakeRange(0, label.length)];
    label = [label stringByReplacingOccurrencesOfString:@"CARWallpaper" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, label.length)];
    label = [label stringByReplacingOccurrencesOfString:@"-16" withString:@""];
    return [NSString stringWithFormat:@"原始壁纸 · %@", label];
}
static NSString *CCOriginalPath(NSString *filename) {
    return [CCOriginalsDirectory() stringByAppendingPathComponent:filename];
}
static BOOL CCWriteExclusive(NSString *dest, NSData *data, NSString **errorText) {
    int fd = open(dest.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) {
        struct stat existing;
        if (errno == EEXIST && stat(dest.fileSystemRepresentation, &existing) == 0 && existing.st_size > 0) return YES;
        if (errorText) *errorText = @"无法创建原始壁纸备份";
        return NO;
    }
    const uint8_t *bytes = data.bytes;
    NSUInteger left = data.length;
    BOOL ok = YES;
    while (left > 0) {
        ssize_t wrote = write(fd, bytes, left);
        if (wrote < 0 && errno == EINTR) continue;
        if (wrote <= 0) { ok = NO; break; }
        bytes += wrote;
        left -= (NSUInteger)wrote;
    }
    if (ok && fsync(fd) != 0) ok = NO;
    if (close(fd) != 0) ok = NO;
    if (!ok) unlink(dest.fileSystemRepresentation);
    if (!ok && errorText) *errorText = @"保存原始壁纸失败";
    return ok;
}
static NSString *CCOldestBackup(NSString *filename) {
    NSString *base = wq_backup_root();
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:base];
    NSString *oldestPath = nil;
    NSDate *oldestDate = nil;
    for (NSString *relative in enumerator) {
        if (![relative.lastPathComponent isEqualToString:filename]) continue;
        NSString *path = [base stringByAppendingPathComponent:relative];
        if (!wq_backup_original_path(path)) continue;
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if (![attributes.fileType isEqualToString:NSFileTypeRegular] || attributes.fileSize == 0) continue;
        NSDate *date = attributes.fileCreationDate ?: attributes.fileModificationDate;
        if (!oldestDate || [date compare:oldestDate] == NSOrderedAscending) {
            oldestDate = date;
            oldestPath = path;
        }
    }
    return oldestPath;
}
static NSString *CCCurrentTarget(NSString *filename, NSString *savedPath) {
    if (savedPath.length && CCAllowed(savedPath) && [savedPath.lastPathComponent isEqualToString:filename]) return savedPath;
    NSArray *roots;
    @synchronized (CCRoots) { roots = CCRoots.allObjects; }
    NSFileManager *files = NSFileManager.defaultManager;
    for (NSString *root in roots) {
        NSString *caches = [root stringByAppendingPathComponent:@"Library/Caches"];
        NSDirectoryEnumerator *enumerator = [files enumeratorAtPath:caches];
        for (NSString *relative in enumerator) {
            if (![relative.lastPathComponent isEqualToString:filename]) continue;
            NSString *full = [caches stringByAppendingPathComponent:relative];
            if (CCAllowed(full)) return full;
        }
    }
    return nil;
}
// The first bytes seen for a slot are the Apple wallpaper. Later replacements
// must not replace that file. An older rollback copy is preferred over the
// file now on disk, because the disk file may already have been replaced.
static BOOL CCPreserveOriginal(NSString *path, NSString **errorText) {
    NSString *filename = path.lastPathComponent;
    if (!CCOriginalName(filename)) {
        if (errorText) *errorText = @"壁纸文件名无法作为原始备份";
        return NO;
    }
    NSString *directory = CCOriginalsDirectory();
    NSString *dest = CCOriginalPath(filename);
    NSFileManager *files = NSFileManager.defaultManager;
    NSDictionary *existing = [files attributesOfItemAtPath:dest error:nil];
    if ([existing.fileType isEqualToString:NSFileTypeRegular] && existing.fileSize > 0) return YES;
    NSString *source = CCOldestBackup(filename) ?: path;
    NSData *data = [NSData dataWithContentsOfFile:source options:NSDataReadingMappedIfSafe error:nil];
    if (!data.length || !CCDecode(data)) {
        if (errorText) *errorText = @"无法读取苹果原始壁纸，已停止替换";
        return NO;
    }
    if (![files createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]) {
        if (errorText) *errorText = @"无法创建原始壁纸目录";
        return NO;
    }
    if (!CCWriteExclusive(dest, data, errorText)) return NO;
    wq_set_user_immutable(dest);
    NSDictionary *record = @{@"target": path, @"name": filename};
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    [json writeToFile:[dest stringByAppendingPathExtension:@"json"] atomically:YES];
    return YES;
}
static NSString *CCSnapshotRoot(void) {
    return [CCOriginalsDirectory().stringByDeletingLastPathComponent stringByAppendingPathComponent:@"ApplicationBackups"];
}
+ (NSArray<NSDictionary *> *)snapshots {
    NSMutableArray *items = NSMutableArray.new;
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:CCSnapshotRoot() error:nil]) {
        if (![[NSUUID alloc] initWithUUIDString:name]) continue;
        NSString *folder = [CCSnapshotRoot() stringByAppendingPathComponent:name];
        NSDictionary *record = [NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"manifest.plist"]];
        if (![record[@"files"] isKindOfClass:NSArray.class] || ![record[@"date"] isKindOfClass:NSDate.class]) continue;
        [items addObject:@{@"path":folder, @"name":[NSString stringWithFormat:@"应用前备份 · %lu 个文件", (unsigned long)[record[@"files"] count]], @"date":record[@"date"]}];
    }
    return [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"date"] compare:a[@"date"]]; }];
}
+ (NSDictionary *)saveSnapshot:(NSArray<NSDictionary *> *)targets {
    NSString *folder = [CCSnapshotRoot() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil]) return CCFail(@"无法保存应用前备份。");
    NSMutableArray *files = NSMutableArray.new;
    for (NSDictionary *target in targets) {
        NSString *path = target[@"path"];
        if (![path isKindOfClass:NSString.class] || !CCAllowed(path)) return CCFail(@"备份目标已变化，请重新查找。");
        NSDictionary *before = wq_file_version(path);
        if ([target[@"version"] isKindOfClass:NSDictionary.class] && ![target[@"version"] isEqual:before]) return CCFail(@"壁纸已变化，请重新查找后再应用。");
        NSData *data = wq_read(path, 0, NULL);
        if (!before || !data.length || ![before isEqual:wq_file_version(path)]) return CCFail(@"无法读取当前壁纸，未开始替换。");
        NSString *name = [NSString stringWithFormat:@"%lu.cpbitmap", (unsigned long)files.count];
        NSString *copy = [folder stringByAppendingPathComponent:name];
        if (![data writeToFile:copy options:NSDataWritingAtomic error:nil] || ![data isEqualToData:[NSData dataWithContentsOfFile:copy]]) return CCFail(@"备份校验失败，未开始替换。");
        [files addObject:@{@"target":path, @"file":name, @"digest":CCDigest(data)}];
    }
    if (![@{@"date":NSDate.date, @"files":files} writeToFile:[folder stringByAppendingPathComponent:@"manifest.plist"] atomically:YES]) return CCFail(@"无法保存备份记录。");
    NSArray *all = [self snapshots];
    for (NSUInteger i = 10; i < all.count; i++) {
        NSString *old = all[i][@"path"];
        if ([old.stringByDeletingLastPathComponent isEqualToString:CCSnapshotRoot()] && [[NSUUID alloc] initWithUUIDString:old.lastPathComponent]) [NSFileManager.defaultManager removeItemAtPath:old error:nil];
    }
    return @{@"ok":@YES};
}
+ (NSDictionary *)restoreDefaults:(NSDictionary<NSString *, NSData *> *)images {
    NSSet *allowed = [NSSet setWithArray:@[@"Black", @"Blue", @"Brown", @"DarkBlue", @"Green", @"Grey", @"Hero", @"Lilac", @"Purple", @"Red", @"Teal"]];
    if (images.count != 12) return CCFail(@"默认壁纸不完整，请重新下载。");
    NSMutableSet *groups = NSMutableSet.new;
    for (NSString *key in images) {
        NSArray *parts = [key componentsSeparatedByString:@"-"];
        if (parts.count != 2 || ![allowed containsObject:parts[0]] || ![@[@"Dark", @"Light"] containsObject:parts[1]]) return CCFail(@"默认壁纸配置无效。");
        [groups addObject:parts[0]];
    }
    if (groups.count != 6) return CCFail(@"默认壁纸配置无效。");
    NSDictionary *found = [self discover:YES];
    NSString *root = found[@"root"];
    if (![found[@"ok"] boolValue] || !root.length || !CCRegisterRoot(root)) return CCFail(found[@"message"] ?: @"未找到车机壁纸目录。");
    // Use the CarPlay wallpaper image cache, not unrelated files in Caches.
    NSString *directory = CCWallpaperDirectory(root);
    NSString *directoryError = nil;
    if (!CCEnsureWallpaperDirectory(root, &directoryError)) return CCFail(directoryError ?: @"无法创建壁纸缓存目录。");
    NSMutableDictionary *encoded = NSMutableDictionary.new;
    NSMutableArray *existing = NSMutableArray.new;
    NSString *temp = [CCOriginalsDirectory().stringByDeletingLastPathComponent stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:temp withIntermediateDirectories:YES attributes:nil error:nil];
    NSArray *existingNames = wq_list(directory, NULL);
    if (!existingNames) return CCFail(@"无法读取壁纸缓存目录。");
    for (NSString *key in images) {
        UIImage *image = [UIImage imageWithData:images[key]];
        NSString *source = [temp stringByAppendingPathComponent:[key stringByAppendingPathExtension:@"cpbitmap"]];
        NSDictionary *result = image ? [self encode:image to:source] : CCFail(@"原图无效。");
        if (![result[@"ok"] boolValue]) return result;
        NSString *prefix = [NSString stringWithFormat:@"CARWallpaper%@-", key];
        NSMutableArray *matches = NSMutableArray.new;
        for (NSString *name in existingNames) if (CCWallpaperName(name) && [name hasPrefix:prefix]) [matches addObject:name];
        if (matches.count > 1) return CCFail([NSString stringWithFormat:@"%@ 存在多个缓存版本，请先检查。", key]);
        NSString *name = matches.firstObject ?: [NSString stringWithFormat:@"CARWallpaper%@-16.cpbitmap", key];
        NSString *target = [directory stringByAppendingPathComponent:name];
        NSData *data = [NSData dataWithContentsOfFile:source];
        encoded[target] = data;
        struct stat st;
        if (wq_stat(target, &st)) { if (!S_ISREG(st.st_mode) || !CCAllowed(target)) return CCFail(@"目标缓存不可写入。"); [existing addObject:@{@"path":target}]; }
        else if (errno != ENOENT) return CCFail(@"无法读取目标缓存。");
    }
    NSDictionary *saved = [self saveSnapshot:existing];
    if (![saved[@"ok"] boolValue]) return saved;
    NSUInteger completed = 0;
    for (NSString *target in [[encoded allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSData *data = encoded[target];
        NSDictionary *version = wq_file_version(target);
        NSString *error = nil;
        BOOL ok = version ? wq_write_if_unchanged_get_version(target, data, version, NULL, &error) : wq_create_file(target, data, &error);
        if (!ok || ![wq_read(target, 0, NULL) isEqualToData:data]) return CCFail([NSString stringWithFormat:@"已恢复 %lu/12 个文件。%@", (unsigned long)completed, error ?: @"文件校验失败，可恢复应用前备份。"]);
        wq_set_user_immutable(target);
        CCKeepData(root, target, data);
        completed++;
    }
    for (NSString *target in encoded) {
        if (![wq_read(target, 0, NULL) isEqualToData:encoded[target]]) return CCFail(@"恢复后复核未通过，请恢复应用前备份。");
    }
    [NSFileManager.defaultManager removeItemAtPath:temp error:nil];
    return @{@"ok":@YES, @"message":@"默认壁纸已恢复。请重启 iPhone 后重新连接 CarPlay。"};
}
+ (NSDictionary *)apply:(NSDictionary *)target source:(NSString *)source {
    NSString *path = target[@"path"];
    if (![path isKindOfClass:NSString.class] || !CCAllowed(path)) return CCFail(@"目标不属于已确认的 CarPlayWallpaper 缓存，拒绝写入");
    NSDictionary *expected = target[@"version"];
    if (![expected isKindOfClass:NSDictionary.class] || ![expected isEqual:wq_file_version(path)]) return CCFail(@"缓存已发生变化，请重新扫描后再操作");
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (![source.stringByStandardizingPath hasPrefix:[documents stringByAppendingString:@"/"]]) return CCFail(@"源文件不属于本应用");
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:source error:nil];
    if (!attributes || ![attributes.fileType isEqualToString:NSFileTypeRegular] || attributes.fileSize == 0) return CCFail(@"源文件缺失或无效");
    NSData *data = [NSData dataWithContentsOfFile:source options:NSDataReadingMappedIfSafe error:nil];
    UIImage *newImage = CCDecode(data);
    // Intentionally accept different dimensions: write the source bytes as-is.
    if (!newImage.CGImage) return CCFail(@"源 CPBitmap 无法解码，未写入");
    NSString *error = nil;
    if (!CCPreserveOriginal(path, &error)) return CCFail(error ?: @"无法保存苹果原始壁纸，已停止替换");
    if (!wq_write_if_unchanged_get_version(path, data, expected, NULL, &error)) return CCFail(error);
    BOOL repairSaved = CCKeepData(CCRootForPath(path), path, data);
    if (!wq_set_user_immutable(path)) {
        return @{@"ok":@YES, @"message":@"已备份并写入，但没能锁定文件。下次连接车机时，系统可能会把它恢复成默认壁纸。"};
    }
    return @{@"ok":@YES, @"message":repairSaved ? @"壁纸已写入并回读核对，原图与修复副本已保留。重新连接车机前请先重启 iPhone。" : @"壁纸已写入并回读核对，但修复副本未能保存。请检查本机存储空间。"};
}
+ (NSDictionary *)verify:(NSDictionary *)target source:(NSString *)source {
    NSString *path = target[@"path"];
    if (![path isKindOfClass:NSString.class] || !CCAllowed(path)) return CCFail(@"壁纸位置已变化。");
    NSDictionary *before = wq_file_version(path);
    NSData *expected = [NSData dataWithContentsOfFile:source];
    NSData *actual = wq_read(path, 0, NULL);
    if (!before || !expected.length || ![expected isEqualToData:actual] || ![before isEqual:wq_file_version(path)])
        return CCFail(@"壁纸内容与本次写入不一致。");
    return @{@"ok":@YES};
}
+ (NSDictionary *)cacheRecoveryPlan:(NSDictionary *)records files:(NSArray *)files root:(NSString *)root {
    NSMutableSet *presentSlots = NSMutableSet.new;
    for (NSDictionary *file in files) {
        NSString *path = file[@"path"];
        if (![path isKindOfClass:NSString.class] || ![path.stringByDeletingLastPathComponent isEqualToString:CCWallpaperDirectory(root)]) continue;
        NSString *slot = CCWallpaperSlot(path);
        if (slot) [presentSlots addObject:slot];
    }
    NSMutableDictionary *slots = NSMutableDictionary.new;
    NSMutableSet *ambiguous = NSMutableSet.new;
    for (NSString *path in records) {
        NSDictionary *record = records[path];
        NSString *slot = CCWallpaperSlot(path);
        if (!slot || ![record isKindOfClass:NSDictionary.class] || ![record[@"root"] isEqual:root] ||
            ![path.stringByDeletingLastPathComponent isEqualToString:CCWallpaperDirectory(root)]) continue;
        if (slots[slot]) [ambiguous addObject:slot];
        slots[slot] = path;
    }
    NSMutableArray *paths = NSMutableArray.new;
    for (NSString *slot in [[slots allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if (![presentSlots containsObject:slot] && ![ambiguous containsObject:slot]) [paths addObject:slots[slot]];
    }
    return @{@"paths":paths, @"saved":@(slots.count), @"ambiguous":@(ambiguous.count)};
}
// Read only direct regular wallpaper children of a validated container's Caches.
// Keep a stable version and identity for the later copy-verify-cleanup transaction.
static NSDictionary *CCLooseWallpaper(NSString *root, NSString *name) {
    if (!CCWallpaperName(name) || ![wq_container_label(root) isEqual:CCIdentifier]) return nil;
    NSString *cursor = root;
    for (NSString *part in @[@"", @"Library", @"Caches"]) {
        if (part.length) cursor = [cursor stringByAppendingPathComponent:part];
        struct stat st;
        if (!wq_stat(cursor, &st) || !S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) return nil;
    }
    NSString *path = [cursor stringByAppendingPathComponent:name];
    NSDictionary *before = wq_file_version(path);
    struct stat st;
    if (!before || !wq_stat(path, &st) || !S_ISREG(st.st_mode) || S_ISLNK(st.st_mode)) return nil;
    NSData *data = wq_read(path, 0, NULL);
    if (!data.length || !CCDecode(data) || ![before isEqual:wq_file_version(path)]) return nil;
    return @{@"path":path, @"data":data, @"version":before, @"identity":wq_identity_for_stat(&st)};
}
static BOOL CCCleanupLooseWallpaper(NSString *root, NSDictionary *source, NSString *target, NSData *expected) {
    if (!source || ![source[@"data"] isEqual:expected] || !CCAllowed(target) ||
        ![source[@"path"] isEqual:[[root stringByAppendingPathComponent:@"Library/Caches"] stringByAppendingPathComponent:target.lastPathComponent]]) return NO;
    NSDictionary *current = CCLooseWallpaper(root, target.lastPathComponent);
    NSDictionary *targetVersion = wq_file_version(target);
    if (!current || ![current[@"version"] isEqual:source[@"version"]] ||
        ![current[@"identity"] isEqual:source[@"identity"]] || ![current[@"data"] isEqual:expected] ||
        !targetVersion || ![wq_read(target, 0, NULL) isEqual:expected] ||
        ![targetVersion isEqual:wq_file_version(target)]) return NO;
    // The WQ deletion API pins identity and backs up the source before unlinking.
    // Locked or concurrently changed files are left in place for a later retry.
    NSString *error = nil;
    BOOL removed = wq_delete_expecting(source[@"path"], source[@"identity"], &error);
    if (!removed) wq_log(@"CarVista loose wallpaper retained: %@: %@", source[@"path"], error);
    return removed;
}
+ (NSDictionary *)recoverySource:(NSData *)backup loose:(NSData *)loose {
    // Inputs have already passed CPBitmap decoding and stable-read checks.
    if (loose.length && (!backup.length || [loose isEqual:backup])) return @{@"source":@"loose", @"data":loose};
    if (backup.length) return @{@"source":@"backup", @"data":backup};
    return @{@"source":@"default"};
}
static NSString *CCDiagnosticDirectory(void) {
    return [CCRepairDirectory().stringByDeletingLastPathComponent stringByAppendingPathComponent:@"WallpaperDiagnostics"];
}
static NSDictionary *CCDirectoryEvidence(NSString *directory) {
    NSMutableDictionary *result = [@{@"path":directory} mutableCopy];
    struct stat dir;
    errno = 0;
    if (!wq_stat(directory, &dir)) { result[@"statErrno"] = @(errno); return result; }
    result[@"inode"] = @(dir.st_ino);
    result[@"flags"] = @(dir.st_flags);
    if (!S_ISDIR(dir.st_mode) || S_ISLNK(dir.st_mode)) { result[@"invalidDirectory"] = @YES; return result; }
    NSString *error = nil;
    NSArray *names = wq_list(directory, &error);
    result[@"listingSucceeded"] = @(names != nil);
    if (error) result[@"listingError"] = error;
    NSMutableArray *items = NSMutableArray.new;
    for (NSString *name in [names sortedArrayUsingSelector:@selector(compare:)]) {
        if ([name containsString:@"/"] || [name isEqual:@"."] || [name isEqual:@".."]) continue;
        NSString *path = [directory stringByAppendingPathComponent:name];
        NSMutableDictionary *item = [@{@"name":name, @"wallpaper":@(CCWallpaperName(name))} mutableCopy];
        struct stat st;
        errno = 0;
        if (!wq_stat(path, &st)) { item[@"statErrno"] = @(errno); [items addObject:item]; continue; }
        item[@"inode"] = @(st.st_ino); item[@"device"] = @(st.st_dev);
        item[@"bytes"] = @(st.st_size); item[@"mode"] = @(st.st_mode);
        item[@"uid"] = @(st.st_uid); item[@"gid"] = @(st.st_gid);
        item[@"flags"] = @(st.st_flags); item[@"immutable"] = @((st.st_flags & UF_IMMUTABLE) != 0);
        item[@"modifiedSeconds"] = @(st.st_mtimespec.tv_sec); item[@"modifiedNanoseconds"] = @(st.st_mtimespec.tv_nsec);
        item[@"changedSeconds"] = @(st.st_ctimespec.tv_sec); item[@"changedNanoseconds"] = @(st.st_ctimespec.tv_nsec);
        item[@"createdSeconds"] = @(st.st_birthtimespec.tv_sec); item[@"createdNanoseconds"] = @(st.st_birthtimespec.tv_nsec);
        if (CCWallpaperName(name) && S_ISREG(st.st_mode) && !S_ISLNK(st.st_mode)) {
            NSDictionary *version = wq_file_version(path);
            NSData *data = wq_read(path, 0, &error);
            item[@"stableRead"] = @(version && [version isEqual:wq_file_version(path)]);
            if (data) { item[@"sha256"] = CCDigest(data); item[@"decodable"] = @(CCDecode(data) != nil); }
            else if (error) item[@"readError"] = error;
        }
        [items addObject:item];
    }
    result[@"files"] = items;
    return result;
}
static NSDictionary *CCWallpaperEvidence(NSString *root) {
    NSDictionary *loose = CCDirectoryEvidence([root stringByAppendingPathComponent:@"Library/Caches"]);
    NSDictionary *mapped = CCDirectoryEvidence(CCWallpaperDirectory(root));
    NSMutableDictionary *a = NSMutableDictionary.new, *b = NSMutableDictionary.new;
    for (NSDictionary *item in loose[@"files"]) if ([item[@"wallpaper"] boolValue]) a[item[@"name"]] = item;
    for (NSDictionary *item in mapped[@"files"]) if ([item[@"wallpaper"] boolValue]) b[item[@"name"]] = item;
    NSMutableSet *names = [NSMutableSet setWithArray:a.allKeys]; [names addObjectsFromArray:b.allKeys];
    NSMutableArray *comparison = NSMutableArray.new;
    for (NSString *name in [[names allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *x = a[name], *y = b[name];
        [comparison addObject:@{@"name":name, @"inCaches":@(x != nil), @"inMappedCache":@(y != nil),
            @"sameSHA256":@(x[@"sha256"] && [x[@"sha256"] isEqual:y[@"sha256"]]),
            @"sameInode":@(x && y && [x[@"inode"] isEqual:y[@"inode"]] && [x[@"device"] isEqual:y[@"device"]])}];
    }
    return @{@"capturedAtEpoch":@(NSDate.date.timeIntervalSince1970), @"root":root,
        @"caches":loose, @"mappedCache":mapped, @"comparison":comparison};
}
static void CCSaveWallpaperEvidence(NSDictionary *record) {
    NSString *directory = CCDiagnosticDirectory();
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *name = [NSString stringWithFormat:@"%.6f-%@.json", NSDate.date.timeIntervalSince1970, NSUUID.UUID.UUIDString];
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    if (![data writeToFile:[directory stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil]) wq_log(@"CarVista: diagnostic evidence could not be saved");
    NSArray *names = [[fm contentsOfDirectoryAtPath:directory error:nil] sortedArrayUsingSelector:@selector(compare:)];
    for (NSUInteger i = 0; names.count > 20 && i < names.count - 20; i++) [fm removeItemAtPath:[directory stringByAppendingPathComponent:names[i]] error:nil];
}
+ (NSDictionary *)selfCheck {
    if ([CCKernelSession isCandidate]) {
        NSDictionary *session = [CCKernelSession prepare];
        if (![session[@"ok"] boolValue]) return session;
    }
    NSDictionary *scan = [self discover:NO];
    NSString *root = scan[@"root"];
    NSMutableDictionary *result = [scan mutableCopy];
    if (root.length) result[@"evidence"] = CCWallpaperEvidence(root);
    NSUInteger copies = 0;
    NSDictionary *records = CCRepairRecords();
    for (NSString *path in records) {
        NSDictionary *record = records[path];
        if ([record isKindOfClass:NSDictionary.class] && [record[@"root"] isEqual:root] && CCRepairData(record)) copies++;
    }
    result[@"validRepairCopies"] = @(copies);
    return result;
}
+ (NSArray *)wallpaperDiagnosticHistory {
    NSMutableArray *records = NSMutableArray.new;
    NSString *directory = CCDiagnosticDirectory();
    NSArray *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
        NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:name]];
        id record = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([record isKindOfClass:NSDictionary.class]) [records addObject:record];
    }
    return records;
}
+ (NSDictionary *)maintainWallpaperCache:(NSDictionary<NSString *, NSData *> *)defaults {
    CCSetup();
    NSString *root = [NSUserDefaults.standardUserDefaults stringForKey:@"CCContainer"];
    if (!root.length || (![CCKernelSession isReady] && !wq_app_group().length) || !CCRegisterRoot(root)) return @{@"ok":@NO, @"skipped":@YES};
    root = CCCanonical(root);
    NSDictionary *beforeEvidence = CCWallpaperEvidence(root);
    CCSaveWallpaperEvidence(@{@"stage":@"beforeAutomaticRecovery", @"snapshot":beforeEvidence});
    @try {
    NSSet *allowed = [NSSet setWithArray:@[@"Black", @"Blue", @"Brown", @"DarkBlue", @"Green", @"Grey", @"Hero", @"Lilac", @"Purple", @"Red", @"Teal"]];
    NSMutableSet *groups = NSMutableSet.new;
    for (NSString *key in defaults) {
        NSArray *parts = [key componentsSeparatedByString:@"-"];
        if (parts.count != 2 || ![allowed containsObject:parts[0]] || ![@[@"Dark", @"Light"] containsObject:parts[1]]) return CCFail(@"自动恢复默认壁纸配置无效。");
        [groups addObject:parts[0]];
    }
    if (defaults.count && (defaults.count != 12 || groups.count != 6)) return CCFail(@"自动恢复需要完整的六组深浅默认壁纸。");
    NSMutableArray *issues = NSMutableArray.new;
    NSArray *files = CCWalkContainer(root, issues, nil);
    CCKeepWallpapers(root, files);
    NSDictionary *records = CCRepairRecords();
    NSDictionary *plan = [self cacheRecoveryPlan:records files:files root:root];
    if ([plan[@"ambiguous"] unsignedIntegerValue]) return CCFail(@"同一槽位存在多个备份版本，未执行自动恢复。");
    NSMutableDictionary *savedSlots = NSMutableDictionary.new;
    for (NSString *path in records) {
        NSDictionary *record = records[path];
        if (![record isKindOfClass:NSDictionary.class] || ![record[@"root"] isEqual:root] ||
            ![path.stringByDeletingLastPathComponent isEqual:CCWallpaperDirectory(root)]) continue;
        NSString *slot = CCWallpaperSlot(path);
        if (!slot) continue;
        NSString *key = [slot substringFromIndex:[@"CARWallpaper" length]];
        // Never silently replace a saved custom group with a different server group.
        if ((defaults.count && !defaults[key]) || savedSlots[key]) return CCFail(@"本机槽位与默认配置不一致或存在多个版本，已保留现场。");
        savedSlots[key] = path;
    }
    NSMutableDictionary *looseSlots = NSMutableDictionary.new;
    NSMutableSet *ambiguousLoose = NSMutableSet.new;
    NSString *caches = [root stringByAppendingPathComponent:@"Library/Caches"];
    for (NSString *name in wq_list(caches, NULL)) {
        NSDictionary *candidate = CCLooseWallpaper(root, name);
        if (!candidate) continue;
        NSString *key = [CCWallpaperSlot(name) substringFromIndex:[@"CARWallpaper" length]];
        if (looseSlots[key]) [ambiguousLoose addObject:key];
        looseSlots[key] = candidate;
    }
    NSMutableSet *keys = [NSMutableSet setWithArray:defaults.allKeys];
    if (!defaults.count) {
        [keys addObjectsFromArray:savedSlots.allKeys];
        [keys addObjectsFromArray:looseSlots.allKeys];
        for (NSDictionary *file in files) {
            NSString *slot = CCWallpaperSlot(file[@"path"]);
            if (slot) [keys addObject:[slot substringFromIndex:[@"CARWallpaper" length]]];
        }
        NSMutableSet *localGroups = NSMutableSet.new;
        for (NSString *key in keys) [localGroups addObject:[key componentsSeparatedByString:@"-"].firstObject];
        if (keys.count != 12 || localGroups.count != 6) return @{@"ok":@NO, @"needsDefaults":@YES};
    }
    NSMutableDictionary *prepared = NSMutableDictionary.new;
    NSMutableDictionary *paths = NSMutableDictionary.new;
    NSMutableDictionary *sources = NSMutableDictionary.new;
    NSString *temp = [CCRepairDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![NSFileManager.defaultManager createDirectoryAtPath:temp withIntermediateDirectories:YES attributes:nil error:nil]) return CCFail(@"无法准备自动恢复文件。");
    @try {
        for (NSString *key in [[keys allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *path = savedSlots[key];
            NSData *data = path ? CCRepairData(records[path]) : nil;
            NSString *existingPath = nil;
            for (NSDictionary *file in files) {
                if ([CCWallpaperSlot(file[@"path"]) isEqual:[@"CARWallpaper" stringByAppendingString:key]]) {
                    if (existingPath) return CCFail(@"同一槽位存在多个缓存版本，未执行自动恢复。");
                    existingPath = file[@"path"];
                }
            }
            // Existing targets win filename/version selection, but never overwrite
            // the saved custom bytes with a system-regenerated default.
            if (existingPath) path = existingPath;
            NSDictionary *loose = nil;
            if (path) {
                // A saved/existing filename fixes the version: never guess another suffix.
                loose = CCLooseWallpaper(root, path.lastPathComponent);
            } else if (![ambiguousLoose containsObject:key]) {
                loose = looseSlots[key];
                if (loose) path = [CCWallpaperDirectory(root) stringByAppendingPathComponent:[loose[@"path"] lastPathComponent]];
            } else {
                return CCFail(@"根目录同一槽位存在多个版本，已保留文件，未自动选择。");
            }
            NSDictionary *choice = [self recoverySource:data loose:loose[@"data"]];
            data = choice[@"data"];
            if ([choice[@"source"] isEqual:@"loose"]) sources[key] = loose;
            if (!path) path = [CCWallpaperDirectory(root) stringByAppendingPathComponent:[NSString stringWithFormat:@"CARWallpaper%@-16.cpbitmap", key]];
            if (!data) {
                if (!defaults.count) return @{@"ok":@NO, @"needsDefaults":@YES};
                UIImage *image = [UIImage imageWithData:defaults[key]];
                NSString *encoded = [temp stringByAppendingPathComponent:[key stringByAppendingPathExtension:@"cpbitmap"]];
                if (!image || ![[self encode:image to:encoded][@"ok"] boolValue]) return CCFail(@"默认壁纸编码失败，未重建系统缓存。");
                data = [NSData dataWithContentsOfFile:encoded];
                if (!data.length || !CCDecode(data)) return CCFail(@"默认壁纸校验失败，未重建系统缓存。");
            }
            prepared[key] = data;
            paths[key] = path;
        }
        // Stage all twelve copies before touching the system hierarchy.
        for (NSString *key in prepared) {
            if (!CCKeepData(root, paths[key], prepared[key])) return CCFail(@"未能保存完整的十二张恢复副本，未重建系统缓存。");
        }
        NSUInteger repaired = 0, failed = 0, cleaned = 0;
        for (NSString *key in [[paths allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *path = paths[key];
            struct stat st;
            errno = 0;
            if (wq_stat(path, &st)) {
                if (!S_ISREG(st.st_mode) || S_ISLNK(st.st_mode)) failed++;
                else if (CCCleanupLooseWallpaper(root, sources[key], path, prepared[key])) cleaned++;
                continue;
            }
            if (errno != ENOENT) { failed++; continue; }
            NSDictionary *result = [self repairCache:@{@"path":path}];
            if ([result[@"ok"] boolValue]) {
                repaired++;
                if (CCCleanupLooseWallpaper(root, sources[key], path, prepared[key])) cleaned++;
            } else { failed++; wq_log(@"CarVista automatic repair: %@: %@", path, result[@"message"]); }
        }
        wq_log(@"CarVista automatic repair: saved=12, restored=%lu, failed=%lu, looseCleaned=%lu", (unsigned long)repaired, (unsigned long)failed, (unsigned long)cleaned);
        return @{@"ok":@(failed == 0), @"saved":@12, @"repaired":@(repaired), @"failed":@(failed), @"cleaned":@(cleaned)};
    } @finally {
        [NSFileManager.defaultManager removeItemAtPath:temp error:nil];
    }
    } @finally {
        CCSaveWallpaperEvidence(@{@"stage":@"afterAutomaticRecovery", @"beforeCapturedAtEpoch":beforeEvidence[@"capturedAtEpoch"], @"snapshot":CCWallpaperEvidence(root)});
    }
}
+ (NSDictionary *)repairCache:(NSDictionary *)target {
    NSString *path = target[@"path"];
    if (![path isKindOfClass:NSString.class]) return CCFail(@"壁纸位置无效，请重新查找。");
    path = CCCanonical(path);
    NSString *root = CCRootForPath(path);
    NSDictionary *record = CCRepairRecords()[path];
    if (!root || ![record isKindOfClass:NSDictionary.class] || ![record[@"root"] isEqual:root] ||
        ![wq_container_label(root) isEqualToString:CCIdentifier] || !CCOriginalName(path.lastPathComponent))
        return CCFail(@"此位置尚未经过本机确认，未执行补回。");
    if (![path.stringByDeletingLastPathComponent isEqualToString:CCWallpaperDirectory(root)] ||
        !CCWallpaperName(path.lastPathComponent))
        return CCFail(@"该记录不属于 CarPlay 图片缓存目录，未执行补回。");
    NSData *data = CCRepairData(record);
    if (!data) return CCFail(@"修复副本未通过完整性检查，未写入系统。");
    NSString *error = nil;
    if (!CCEnsureWallpaperDirectory(root, &error)) return CCFail(error ?: @"无法重建壁纸缓存目录。");
    struct stat st;
    errno = 0;
    if (wq_stat(path, &st) || errno != ENOENT)
        return CCFail(@"此位置已存在文件或暂时无法访问，未覆盖现有内容。请刷新列表。");
    // Exclusive creation: a file appearing concurrently must never be overwritten.
    if (!wq_create_file(path, data, &error)) return CCFail(error ?: @"未能补回该壁纸。");
    NSDictionary *writtenVersion = wq_file_version(path);
    if (!writtenVersion || !CCAllowed(path) || ![wq_read(path, 0, &error) isEqualToData:data] ||
        ![writtenVersion isEqual:wq_file_version(path)])
        return CCFail(@"补回后的内容未通过核对，请保留诊断报告后重试。");
    BOOL locked = wq_set_user_immutable(path);
    return @{@"ok":@YES, @"message":locked ? @"已重建原缓存位置并从本机副本补回壁纸，内容核对通过。请重新连接 CarPlay 检查效果。" : @"壁纸已补回并核对，但未能锁定；系统之后可能重新生成缓存。"};
}
+ (NSDictionary *)unlockWallpapers {
    NSDictionary *found = [self discover:NO];
    if (![found[@"ok"] boolValue]) return found;
    NSArray *files = found[@"files"];
    NSInteger cleared = 0, failed = 0;
    for (NSDictionary *file in files) {
        if ([file[@"missing"] boolValue]) continue;
        NSString *path = file[@"path"];
        if (![path isKindOfClass:NSString.class] || !CCAllowed(path) || !wq_clear_user_immutable(path)) failed++;
        else cleared++;
    }
    if (cleared == 0) return CCFail(failed ? @"没能解除壁纸锁定。" : @"没有可解锁的车机壁纸。请先在车机切换内置壁纸后再试。");
    if (failed) return @{@"ok":@NO, @"message":[NSString stringWithFormat:@"已解除 %ld 个，%ld 个未能解除。", (long)cleared, (long)failed]};
    return @{@"ok":@YES, @"message":[NSString stringWithFormat:@"已解除 %ld 个壁纸文件的锁定。其他软件现在可以替换。", (long)cleared]};
}
static void CCAdoptExistingOriginals(void) {
    NSString *base = wq_backup_root();
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:base];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *relative in enumerator) {
        if (![relative.pathExtension.lowercaseString isEqualToString:@"cpbitmap"]) continue;
        NSString *backup = [base stringByAppendingPathComponent:relative];
        NSString *target = wq_backup_original_path(backup);
        if (!CCOriginalName(target.lastPathComponent) || [seen containsObject:target.lastPathComponent]) continue;
        [seen addObject:target.lastPathComponent];
        CCPreserveOriginal(target, NULL);
    }
}
+ (NSArray<NSDictionary *> *)backups {
    CCAdoptExistingOriginals();
    NSMutableArray *items = NSMutableArray.new;
    NSString *base = CCOriginalsDirectory();
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:base error:nil];
    for (NSString *name in names) {
        if (!CCOriginalName(name)) continue;
        NSString *path = [base stringByAppendingPathComponent:name];
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if (![attributes.fileType isEqualToString:NSFileTypeRegular] || attributes.fileSize == 0) continue;
        NSData *json = [NSData dataWithContentsOfFile:[path stringByAppendingPathExtension:@"json"]];
        NSDictionary *record = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
        NSString *target = [record[@"target"] isKindOfClass:NSString.class] ? record[@"target"] : @"";
        [items addObject:@{@"path":path, @"original":target, @"name":CCOriginalDisplayName(name),
            @"date":attributes.fileCreationDate ?: attributes.fileModificationDate ?: NSDate.distantPast,
            @"bytes":@(attributes.fileSize), @"originalWallpaper":@YES}];
    }
    return [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] compare:b[@"name"]];
    }];
}
+ (NSDictionary *)restore:(NSString *)backup {
    CCSetup();
    if ([backup.stringByDeletingLastPathComponent isEqualToString:CCSnapshotRoot()] && [[NSUUID alloc] initWithUUIDString:backup.lastPathComponent]) {
        [self discover:YES];
        NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:[backup stringByAppendingPathComponent:@"manifest.plist"]];
        NSArray *files = manifest[@"files"];
        if (![files isKindOfClass:NSArray.class] || !files.count) return CCFail(@"此备份没有可恢复的文件。");
        NSMutableArray *targets = NSMutableArray.new;
        NSMutableDictionary *contents = NSMutableDictionary.new;
        for (NSDictionary *item in files) {
            NSString *file = item[@"file"], *target = item[@"target"];
            if (![file isKindOfClass:NSString.class] || ![file.lastPathComponent isEqualToString:file] || !CCAllowed(target)) return CCFail(@"备份目标不可用。");
            NSData *data = [NSData dataWithContentsOfFile:[backup stringByAppendingPathComponent:file]];
            if (!data.length || ![CCDigest(data) isEqual:item[@"digest"]]) return CCFail(@"备份完整性检查失败。");
            contents[target] = data;
            [targets addObject:@{@"path":target}];
        }
        NSDictionary *snapshot = [self saveSnapshot:targets];
        if (![snapshot[@"ok"] boolValue]) return snapshot;
        for (NSDictionary *item in files) {
            NSData *data = contents[item[@"target"]];
            NSString *target = item[@"target"], *error = nil;
            if (!wq_write_if_unchanged_get_version(target, data, wq_file_version(target), NULL, &error)) return CCFail(error);
            CCKeepData(CCRootForPath(target), target, data);
            wq_set_user_immutable(target);
        }
        return @{@"ok":@YES, @"message":@"备份已恢复，请重新连接 CarPlay 查看效果。"};
    }
    NSString *original = nil;
    NSString *originalRoot = [CCCanonical(CCOriginalsDirectory()) stringByAppendingString:@"/"];
    if ([CCCanonical(backup) hasPrefix:originalRoot]) {
        NSData *json = [NSData dataWithContentsOfFile:[backup stringByAppendingPathExtension:@"json"]];
        NSDictionary *record = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
        NSString *saved = [record[@"target"] isKindOfClass:NSString.class] ? record[@"target"] : nil;
        original = CCCurrentTarget(backup.lastPathComponent, saved);
    }
    if (!original) original = wq_backup_original_path(backup);
    if (!original || !CCAllowed(original)) return CCFail(@"请先扫描并确认原壁纸容器。只允许恢复仍存在的同一目标文件。");
    NSDictionary *expected = wq_file_version(original);
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:backup error:nil];
    if (!expected || ![attributes.fileType isEqualToString:NSFileTypeRegular] || attributes.fileSize == 0) return CCFail(@"目标或备份文件无效");
    NSData *data = [NSData dataWithContentsOfFile:backup options:NSDataReadingMappedIfSafe error:nil];
    if (!CCDecode(data)) return CCFail(@"备份无法解码，拒绝恢复");
    NSString *error = nil;
    NSDictionary *snapshot = [self saveSnapshot:@[@{@"path":original, @"version":expected}]];
    if (![snapshot[@"ok"] boolValue]) return snapshot;
    if (!wq_write_if_unchanged_get_version(original, data, expected, NULL, &error)) return CCFail(error);
    CCKeepData(CCRootForPath(original), original, data);
    if (!wq_set_user_immutable(original)) {
        return @{@"ok":@YES, @"message":@"恢复完成，但没能锁定文件。下次连接车机时，系统可能会把它恢复成默认壁纸。"};
    }
    return @{@"ok":@YES, @"message":@"恢复完成，并已锁定。请重启 iPhone 后连接 CarPlay 检查效果。"};
}

@end
