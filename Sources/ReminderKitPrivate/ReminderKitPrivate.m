#import "ReminderKitPrivate.h"

const char *RKPProbe(void) {
    // Linking with -framework ReminderKit validates the link path at build
    // time; NSClassFromString validates the framework loads at runtime
    // without instantiating anything.
    Class store = NSClassFromString(@"REMStore");
    return store != nil ? "reminderkit-ok" : "reminderkit-missing";
}
