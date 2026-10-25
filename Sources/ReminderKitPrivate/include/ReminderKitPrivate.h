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

/// The rich-link host policy enforced before a URL attachment is saved: YES only for
/// http/https URLs whose host is neither a private/loopback/fake-IP literal (including
/// IPv4-mapped IPv6 spellings) nor a name that resolves to such an address. Exposed so
/// the policy is testable without a Reminders store; performs no writes.
BOOL RKPLooksLikeWebURL(NSString *value);

NS_ASSUME_NONNULL_END
