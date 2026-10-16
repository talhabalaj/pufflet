#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <ApplicationServices/ApplicationServices.h>
#include <stdlib.h>
#include <string.h>

static void (*originalFinishLaunching)(id, SEL);
static BOOL (*originalSetActivationPolicy)(id, SEL, NSApplicationActivationPolicy);

static BOOL isGameProcess(void)
{
    // Wine's argv names the Windows image, including for server-created children.
    // Only images in a Steam game directory may promote. Renderer, launch host,
    // PID ancestry and the runtime bundle name play no part in this decision.
    for (NSString *argument in NSProcessInfo.processInfo.arguments) {
        NSString *path = [[argument stringByReplacingOccurrencesOfString:@"/" withString:@"\\"] lowercaseString];
        if (![path hasSuffix:@".exe"]) continue;
        NSString *name = [path componentsSeparatedByString:@"\\"].lastObject;
        if ([name containsString:@"crashhandler"] || [name hasPrefix:@"unins"] ||
            [@[@"explorer.exe", @"services.exe", @"winedevice.exe", @"rpcss.exe", @"plugplay.exe",
               @"svchost.exe", @"steamservice.exe", @"dockhost.exe", @"wine-process-guard.exe"] containsObject:name]) return NO;
        return [path containsString:@"\\steamapps\\common\\"];
    }
    return NO;
}

static void makeHelperBackground(void)
{
    // Prohibited activation alone still leaves a LaunchServices UI application
    // in the Dock's grouped "running in background" list. Set the process type,
    // using the public self-only transform API (never another process's PSN).
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
