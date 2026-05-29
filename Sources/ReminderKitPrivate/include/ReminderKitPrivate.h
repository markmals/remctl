#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Phase-0 probe. Returns a C string: "reminderkit-ok" when the private
/// ReminderKit framework's REMStore class resolves at runtime, otherwise
/// "reminderkit-missing". Performs no writes. Replaced by the real private
/// API surface in Phase 3.
const char *RKPProbe(void);

NS_ASSUME_NONNULL_END
