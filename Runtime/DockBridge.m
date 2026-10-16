#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <ApplicationServices/ApplicationServices.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <limits.h>

static void (*originalFinishLaunching)(id, SEL);
static BOOL (*originalSetActivationPolicy)(id, SEL, NSApplicationActivationPolicy);

static NSString *nativeImagePath(NSString *image)
{
    NSString *path = [image stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    if ([path hasPrefix:@"//?/unix/"]) return [path substringFromIndex:8];
    if ([path hasPrefix:@"/"]) return path;
    if (path.length > 3 && [path characterAtIndex:1] == ':' && [path characterAtIndex:2] == '/') {
        NSString *prefix = [NSString stringWithUTF8String:getenv("WINEPREFIX")];
        NSString *drive = [[path substringToIndex:2] lowercaseString];
        return [[prefix stringByAppendingPathComponent:[@"dosdevices" stringByAppendingPathComponent:drive]]
                stringByAppendingPathComponent:[path substringFromIndex:3]];
    }
    return nil; // Do not guess an image from its basename or an argument.
}

static NSString *allowedImage(void)
{
    const char *explicit = getenv("STEAM_LIBRARY_DOCK_ALLOW");
    if (explicit) return strlen(explicit) < PATH_MAX ? nativeImagePath([NSString stringWithUTF8String:explicit]) : nil;
    NSString *prefix = [NSString stringWithUTF8String:getenv("WINEPREFIX")];
    NSString *record = [prefix stringByAppendingPathComponent:@".pufflet-dock-allow"];
    int fd = open(record.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return nil;
    struct stat info;
    char bytes[PATH_MAX];
    ssize_t count = -1;
    if (!fstat(fd, &info) && S_ISREG(info.st_mode) && info.st_uid == geteuid() &&
        !(info.st_mode & 0077) && info.st_size > 0 && info.st_size < PATH_MAX)
        count = read(fd, bytes, sizeof(bytes));
    close(fd);
    if (count <= 0 || count >= PATH_MAX || memchr(bytes, 0, (size_t)count)) return nil;
    NSString *path = [[NSString alloc] initWithBytes:bytes length:(NSUInteger)count encoding:NSUTF8StringEncoding];
    return [path hasPrefix:@"/"] ? path : nil;
}

static BOOL isGameProcess(void)
{
    static dispatch_once_t once;
    static BOOL allowed;
    dispatch_once(&once, ^{
        // The host's flag stays on. Only the exact selected image may promote;
        // a sibling GUI executable in the game directory is still a helper.
        for (NSString *argument in NSProcessInfo.processInfo.arguments) {
            NSString *path = [[argument stringByReplacingOccurrencesOfString:@"/" withString:@"\\"] lowercaseString];
            if (![path hasSuffix:@".exe"]) continue;
            NSString *name = [path componentsSeparatedByString:@"\\"].lastObject;
            if ([name containsString:@"crashhandler"] || [name hasPrefix:@"unins"] ||
                [@[@"explorer.exe", @"services.exe", @"winedevice.exe", @"rpcss.exe", @"plugplay.exe",
                   @"svchost.exe", @"steamservice.exe", @"steam.exe", @"dockhost.exe", @"wine-process-guard.exe"] containsObject:name]) return;
            NSString *candidate = nativeImagePath(argument), *expected = allowedImage();
            struct stat image, selected;
            allowed = candidate && expected && !stat(candidate.fileSystemRepresentation, &image) &&
                !stat(expected.fileSystemRepresentation, &selected) && S_ISREG(image.st_mode) &&
                image.st_dev == selected.st_dev && image.st_ino == selected.st_ino;
            return; // Wine's first EXE argument is its image; later arguments grant nothing.
        }
    });
    return allowed;
}

static void makeHelperBackground(void)
{
    // Set process type as well as refusing promotion, using the public self-only
    // transform API. Literal Dock presentation is a separate visual check.
    ProcessSerialNumber current = {0, kCurrentProcess};
    TransformProcessType(&current, kProcessTransformToBackgroundApplication);
}

static void launcherFinishLaunching(id application, SEL selector)
{
    originalFinishLaunching(application, selector);
    if (!isGameProcess()) makeHelperBackground();
}

static BOOL launcherSetActivationPolicy(id application, SEL selector, NSApplicationActivationPolicy policy)
{
    BOOL helper = !isGameProcess();
    if (policy == NSApplicationActivationPolicyRegular && helper) policy = NSApplicationActivationPolicyProhibited;
    BOOL result = originalSetActivationPolicy(application, selector, policy);
    if (helper) makeHelperBackground();
    return result;
}

__attribute__((constructor)) static void installDockBridge(void)
{
    const char *enabled = getenv("STEAM_LIBRARY_DOCK_BRIDGE");
    const char *prefix = getenv("WINEPREFIX");
    const char *expectedPrefix = getenv("STEAM_LIBRARY_PREFIX");
    if (!enabled || strcmp(enabled, "1") || !prefix || !expectedPrefix || strcmp(prefix, expectedPrefix)) return;
    Method method = class_getInstanceMethod(NSApplication.class, @selector(setActivationPolicy:));
    if (method) originalSetActivationPolicy = (void *)method_setImplementation(method, (IMP)launcherSetActivationPolicy);
    method = class_getInstanceMethod(NSApplication.class, @selector(finishLaunching));
    if (method) originalFinishLaunching = (void *)method_setImplementation(method, (IMP)launcherFinishLaunching);
}
