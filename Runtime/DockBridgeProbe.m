#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

int main(void)
{
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        ProcessSerialNumber current = {0, kCurrentProcess};
        NSDictionary *info = CFBridgingRelease(ProcessInformationCopyDictionary(&current, kProcessDictionaryIncludeAllInformationMask));
        BOOL background = [info[@"LSBackgroundOnly"] boolValue];
        BOOL expectsBackground = getenv("EXPECT_BACKGROUND") != NULL;
        printf("activation_policy=%ld background_only=%d expected_background=%d\n", (long)app.activationPolicy, background, expectsBackground);
        return expectsBackground ? (background && app.activationPolicy != NSApplicationActivationPolicyRegular ? 0 : 1) : (app.activationPolicy == NSApplicationActivationPolicyRegular ? 0 : 1);
    }
}
