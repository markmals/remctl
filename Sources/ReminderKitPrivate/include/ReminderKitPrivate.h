#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Phase-0 probe. Returns a C string: "reminderkit-ok" when the private
/// ReminderKit framework's REMStore class resolves at runtime, otherwise
/// "reminderkit-missing". Performs no writes.
const char *RKPProbe(void);

/// Dispatch one private ReminderKit action. `request` mirrors the legacy
/// stdin JSON dict that the out-of-process `remctl-private` helper consumed
/// (must contain an "action" string in the allow-list).
///
/// Returns the response dict: on success
/// `{"status": <"created"|"updated"|"deleted">, "action": ..., ...}`; on
/// failure `{"status": "error", "message": ...}`.
///
/// NEVER throws, NEVER calls exit(). Any private-API fault (unrecognized
/// selector, save failure, etc.) is caught and returned as an error dict.
NSDictionary *RKPDispatch(NSDictionary *request);

NS_ASSUME_NONNULL_END
