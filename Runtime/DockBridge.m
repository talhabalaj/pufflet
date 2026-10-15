#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>

static BOOL (*originalSetActivationPolicy)(id, SEL, NSApplicationActivationPolicy);

static BOOL launcherSetActivationPolicy(id application, SEL selector, NSApplicationActivationPolicy policy)
{
    // Wine windows remain interactive; the native launcher owns the Dock entry.
    if (policy == NSApplicationActivationPolicyRegular)
        policy = NSApplicationActivationPolicyAccessory;
    return originalSetActivationPolicy(application, selector, policy);
}

__attribute__((constructor)) static void installDockBridge(void)
{
    const char *enabled = getenv("STEAM_LIBRARY_DOCK_BRIDGE");
    const char *prefix = getenv("WINEPREFIX");
    const char *expectedPrefix = getenv("STEAM_LIBRARY_PREFIX");
    if (!enabled || strcmp(enabled, "1") || !prefix || !expectedPrefix || strcmp(prefix, expectedPrefix))
        return;
    Method method = class_getInstanceMethod(NSApplication.class, @selector(setActivationPolicy:));
    if (method)
        originalSetActivationPolicy = (void *)method_setImplementation(method, (IMP)launcherSetActivationPolicy);
}
