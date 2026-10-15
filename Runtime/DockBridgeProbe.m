#import <AppKit/AppKit.h>

int main(void)
{
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        BOOL expectsAccessory = getenv("EXPECT_ACCESSORY") != NULL;
        NSInteger policy = app.activationPolicy;
        printf("activation_policy=%ld expected=%ld\n", (long)policy,
               (long)(expectsAccessory ? NSApplicationActivationPolicyAccessory : NSApplicationActivationPolicyRegular));
        return policy == (expectsAccessory ? NSApplicationActivationPolicyAccessory : NSApplicationActivationPolicyRegular) ? 0 : 1;
    }
}
