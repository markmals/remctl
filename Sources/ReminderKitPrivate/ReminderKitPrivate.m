#import "ReminderKitPrivate.h"
#import <AppKit/AppKit.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>

#pragma mark - Private ReminderKit forward declarations
//
// Apple ships no public ReminderKit headers. These @interface forward
// declarations are ported VERBATIM from the legacy remctl-private.m helper:
// the implementation resolves the actual classes at runtime via
// NSClassFromString, and selector correctness is a RUNTIME property only —
// a typo here is an unrecognized-selector fault invisible to the compiler.
// Do NOT rename selectors or "fix" signatures.

@interface REMObjectID : NSObject
+ (id)objectIDWithURL:(NSURL *)url;
- (NSUUID *)uuid;
- (NSURL *)urlRepresentation;
@end

@interface REMStore : NSObject
- (id)fetchReminderWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchListWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchSmartListWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchListSectionWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchCustomSmartListWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchTemplateWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchPrimaryActiveCloudKitAccountWithError:(NSError **)error;
- (id)fetchDefaultAccountWithError:(NSError **)error;
@end

@interface REMSaveRequest : NSObject
- (instancetype)initWithStore:(REMStore *)store;
- (id)updateAccount:(id)account;
- (id)updateReminder:(id)reminder;
- (id)updateList:(id)list;
- (id)updateSmartList:(id)smartList;
- (id)updateTemplate:(id)templateObject;
- (id)addReminderWithTitle:(NSString *)title toReminderSubtaskContextChangeItem:(id)context;
- (id)addListWithName:(NSString *)name toAccountChangeItem:(id)accountChangeItem listObjectID:(id)objectID;
- (id)addListSectionWithDisplayName:(NSString *)name toListSectionContextChangeItem:(id)context;
- (id)addCustomSmartListWithName:(NSString *)name toAccountChangeItem:(id)accountChangeItem smartListObjectID:(id)objectID;
- (id)addTemplateWithName:(NSString *)name configuration:(id)configuration toAccountChangeItem:(id)accountChangeItem;
- (id)addListUsingTemplate:(id)templateObject toAccountChangeItem:(id)accountChangeItem;
- (BOOL)saveSynchronouslyWithError:(NSError **)error;
@end

@interface REMAccount : NSObject
- (id)capabilities;
- (id)remObjectID;
@end

@interface REMAccountChangeItem : NSObject
- (void)addListChangeItem:(id)listChangeItem;
- (void)addSmartListChangeItem:(id)smartListChangeItem;
@end

@interface REMAccountCapabilities : NSObject
- (BOOL)supportsCustomSmartLists;
@end

@interface REMSmartListChangeItem : NSObject
- (id)remObjectID;
- (id)appearanceContext;
- (id)customContext;
- (void)setColor:(id)color;
- (void)setFilterData:(NSData *)filterData;
- (void)setIsPinned:(BOOL)pinned;
- (void)setName:(NSString *)name;
- (void)setParentOwnerID:(id)objectID;
- (void)setSmartListType:(NSString *)smartListType;
- (void)removeFromParentWithAccountChangeItem:(id)accountChangeItem;
@end

@interface REMSmartListCustomContextChangeItem : NSObject
- (void)setName:(NSString *)name;
- (void)setColor:(id)color;
- (void)setBadge:(id)badge;
@end

@interface REMSmartList : NSObject
- (id)account;
- (id)remObjectID;
@end

@interface REMTemplate : NSObject
- (id)remObjectID;
@end

@interface REMTemplateChangeItem : NSObject
- (id)remObjectID;
- (void)removeFromParentAccount;
@end

@interface REMTemplateConfiguration : NSObject
- (instancetype)initWithSourceListID:(id)sourceListID shouldSaveCompleted:(BOOL)shouldSaveCompleted;
@end

@interface REMReminderChangeItem : NSObject
- (id)assignmentContext;
- (id)attachmentContext;
- (id)dueDateDeltaAlertContext;
- (id)flaggedContext;
- (id)hashtagContext;
- (id)subtaskContext;
- (id)urgentAlarmContext;
- (void)addAlarm:(id)alarm;
@end

@interface REMReminderAssignmentContextChangeItem : NSObject
- (id)addAssignmentWithAssigneeID:(id)assigneeID originatorID:(id)originatorID status:(NSInteger)status;
- (void)removeAllAssignments;
@end

@interface REMReminderDueDateDeltaAlertContextChangeItem : NSObject
- (id)addDueDateDeltaAlertWithDueDateDelta:(id)dueDateDelta;
- (void)removeAllFetchedDueDateDeltaAlerts;
- (void)removeDueDateDeltaAlertsWithIdentifiers:(NSArray *)identifiers;
@end

@interface REMDueDateDeltaInterval : NSObject
- (instancetype)initWithUnit:(NSInteger)unit count:(NSInteger)count;
@end

@interface REMReminderAttachmentContextChangeItem : NSObject
- (id)addImageAttachmentWithURL:(NSURL *)url width:(NSUInteger)width height:(NSUInteger)height error:(NSError **)error;
- (id)addURLAttachmentWithURL:(NSURL *)url;
@end

@interface REMReminderHashtagContextChangeItem : NSObject
- (id)addHashtagWithType:(NSInteger)type name:(NSString *)name;
@end

@interface REMReminderFlaggedContextChangeItem : NSObject
- (void)setFlagged:(NSInteger)flagged;
@end

@interface REMReminderUrgentAlarmContextChangeItem : NSObject
- (void)setIsUrgentStateEnabledForCurrentUser:(BOOL)value;
@end

@interface REMReminder : NSObject
- (id)list;
- (id)remObjectID;
@end

@interface REMListChangeItem : NSObject
- (id)remObjectID;
- (id)sectionsContextChangeItem;
- (id)appearanceContext;
- (id)groceryContextChangeItem;
- (void)setColor:(id)color;
- (void)setIsPinned:(BOOL)pinned;
- (void)setName:(NSString *)name;
- (void)setParentOwnerID:(id)objectID;
@end

@interface REMListGroceryContextChangeItem : NSObject
- (void)setShouldCategorizeGroceryItems:(BOOL)value;
- (void)setGroceryLocaleID:(NSString *)localeID;
- (void)categorizeGroceryItemsWithReminderIDs:(NSArray *)reminderIDs;
@end

@interface REMListAppearanceContextChangeItem : NSObject
- (void)setBadgeEmblem:(NSString *)emblem;
- (void)setBadge:(id)badge;
@end

@interface REMListBadge : NSObject
- (instancetype)initWithEmblem:(NSString *)emblem;
- (instancetype)initWithEmoji:(NSString *)emoji;
@end

@interface REMColor : NSObject
- (instancetype)initWithRed:(double)red green:(double)green blue:(double)blue alpha:(double)alpha colorSpace:(NSInteger)colorSpace daSymbolicColorName:(NSString *)daSymbolicColorName daHexString:(NSString *)daHexString ckSymbolicColorName:(NSString *)ckSymbolicColorName;
@end

@interface REMListSectionChangeItem : NSObject
- (id)remObjectID;
@end

@interface REMListSectionContextChangeItem : NSObject
- (void)setShouldUpdateSectionsOrdering:(BOOL)update;
- (void)setUnsavedMembershipsOfRemindersInSections:(id)memberships;
- (void)setUnsavedSectionIDsOrdering:(NSArray *)ordering;
@end

@interface REMMembership : NSObject
- (instancetype)initWithMemberIdentifier:(NSUUID *)memberIdentifier groupIdentifier:(NSUUID *)groupIdentifier isObsolete:(BOOL)isObsolete modifiedOn:(NSDate *)modifiedOn;
@end

@interface REMMemberships : NSObject
- (instancetype)initWithMemberships:(NSArray *)memberships;
@end

@interface REMStructuredLocation : NSObject
- (instancetype)initWithTitle:(NSString *)title locationUID:(NSString *)uid latitude:(double)lat longitude:(double)lon radius:(double)radius address:(NSString *)address routing:(NSString *)routing referenceFrameString:(NSString *)ref contactLabel:(NSString *)label mapKitHandle:(NSData *)handle;
@end

@interface REMAlarmLocationTrigger : NSObject
- (instancetype)initWithStructuredLocation:(id)location proximity:(NSInteger)proximity;
@end

@interface REMAlarm : NSObject
- (instancetype)initWithTrigger:(id)trigger;
@end

#pragma mark - Probe (Phase 0, unchanged)

const char *RKPProbe(void) {
    // Linking with -framework ReminderKit validates the link path at build
    // time; NSClassFromString validates the framework loads at runtime
    // without instantiating anything.
    Class store = NSClassFromString(@"REMStore");
    return store != nil ? "reminderkit-ok" : "reminderkit-missing";
}

#pragma mark - Error propagation
//
// The legacy helper used `fail(msg)` (which wrote a JSON error to stdout and
// exit(1)) as a control-flow exit. In-process we cannot exit. Two idioms
// replace it:
//   * Inside RKPDispatch, the RKP_FAIL(msg) macro `return`s an error dict.
//   * Helper functions take an `NSString **outError` out-parameter; they set
//     it (non-nil) and bail. Callers in RKPDispatch check it and RKP_FAIL.
// The RKP_PROPAGATE(callExpr) macro runs a helper and returns its error dict
// if the helper set *outError.

// Variadic so message expressions containing top-level commas survive the
// preprocessor — e.g. RKP_FAIL([NSString stringWithFormat:@"...", path]),
// whose comma is inside [] (which the preprocessor does NOT treat as a
// grouping that protects commas, unlike ()).
#define RKP_FAIL(...) \
    return @{@"status": @"error", @"message": ((__VA_ARGS__) ?: @"private helper failed")}

#define RKP_PROPAGATE(call) do { \
    NSString *_rkpErr = nil; \
    (call); \
    if (_rkpErr) { RKP_FAIL(_rkpErr); } \
} while (0)

static NSDictionary *errorDict(NSString *message) {
    return @{@"status": @"error", @"message": (message ?: @"private helper failed")};
}

#pragma mark - Forward declarations of helpers

static NSString *normalizedColorName(NSString *value);
static REMColor *makeREMColor(NSString *value, NSString **outError);

#pragma mark - Helpers ported from remctl-private.m

static void setCustomSmartListSupportedVersion(id change, NSString **outError) {
    NSNumber *version = @(20220430);
    @try {
        [change setValue:version forKey:@"minimumSupportedVersion"];
        [change setValue:version forKey:@"effectiveMinimumSupportedVersion"];
    } @catch (NSException *exception) {
        if (outError) *outError = [NSString stringWithFormat:@"Could not set custom smart list supported version: %@", exception.reason ?: exception.name];
    }
}

static void applyListAppearance(id change, NSDictionary *cmd, NSMutableDictionary *details, NSString *targetDescription, NSString **outError) {
    NSString *color = cmd[@"color"];
    if ([color isKindOfClass:[NSString class]] && color.length) {
        id colorTarget = change;
        if (![colorTarget respondsToSelector:@selector(setColor:)] && [change respondsToSelector:@selector(customContext)]) {
            id customContext = [change customContext];
            if ([customContext respondsToSelector:@selector(setColor:)]) {
                colorTarget = customContext;
            }
        }
        if (![colorTarget respondsToSelector:@selector(setColor:)]) {
            if (outError) *outError = [NSString stringWithFormat:@"%@ does not support color changes", targetDescription ?: @"Target"];
            return;
        }
        NSString *colorError = nil;
        REMColor *remColor = makeREMColor(color, &colorError);
        if (colorError) {
            if (outError) *outError = colorError;
            return;
        }
        [colorTarget setColor:remColor];
        details[@"color"] = normalizedColorName(color) ?: color;
    }

    NSString *symbol = cmd[@"symbol"];
    NSString *emoji = cmd[@"emoji"];
    if (([symbol isKindOfClass:[NSString class]] && symbol.length) || ([emoji isKindOfClass:[NSString class]] && emoji.length)) {
        id appearance = nil;
        id badgeTarget = nil;
        if ([change respondsToSelector:@selector(appearanceContext)]) {
            appearance = [change appearanceContext];
        }
        if (!appearance && [change respondsToSelector:@selector(setBadge:)]) {
            badgeTarget = change;
        }
        if (!appearance && !badgeTarget && [change respondsToSelector:@selector(customContext)]) {
            id customContext = [change customContext];
            if ([customContext respondsToSelector:@selector(setBadge:)]) {
                badgeTarget = customContext;
            }
        }
        if (!appearance && !badgeTarget) {
            if (outError) *outError = [NSString stringWithFormat:@"%@ does not support badge changes", targetDescription ?: @"Target"];
            return;
        }
        if (appearance && ![appearance respondsToSelector:@selector(setBadge:)] && ![appearance respondsToSelector:@selector(setBadgeEmblem:)]) {
            if (outError) *outError = [NSString stringWithFormat:@"Could not create %@ appearance context", targetDescription ?: @"target"];
            return;
        }
        if ([symbol isKindOfClass:[NSString class]] && symbol.length) {
            if (appearance && [appearance respondsToSelector:@selector(setBadgeEmblem:)]) {
                [appearance setBadgeEmblem:symbol];
            } else {
                id badge = [[REMListBadge alloc] initWithEmblem:symbol];
                [badgeTarget setBadge:badge];
            }
            details[@"symbol"] = symbol;
        }
        if ([emoji isKindOfClass:[NSString class]] && emoji.length) {
            id badge = [[REMListBadge alloc] initWithEmoji:emoji];
            if (appearance) {
                [appearance setBadge:badge];
            } else {
                [badgeTarget setBadge:badge];
            }
            details[@"emoji"] = emoji;
        }
    }
}

static void applyListGroceryMetadata(REMListChangeItem *change, NSDictionary *cmd, NSMutableDictionary *details, NSString **outError) {
    BOOL hasCategorizeFlag = cmd[@"shouldCategorizeGroceryItems"] && cmd[@"shouldCategorizeGroceryItems"] != [NSNull null];
    BOOL hasLocale = [cmd[@"groceryLocaleID"] isKindOfClass:[NSString class]] && [cmd[@"groceryLocaleID"] length] > 0;
    if (!hasCategorizeFlag && !hasLocale) {
        return;
    }
    if (![change respondsToSelector:@selector(groceryContextChangeItem)]) {
        if (outError) *outError = @"ReminderKit list change item does not support grocery metadata";
        return;
    }
    id groceryContext = [change groceryContextChangeItem];
    if (!groceryContext) {
        if (outError) *outError = @"Could not create ReminderKit grocery context";
        return;
    }
    if (hasCategorizeFlag) {
        if (![groceryContext respondsToSelector:@selector(setShouldCategorizeGroceryItems:)]) {
            if (outError) *outError = @"ReminderKit grocery context does not support grocery list conversion";
            return;
        }
        BOOL enabled = [cmd[@"shouldCategorizeGroceryItems"] boolValue];
        [(REMListGroceryContextChangeItem *)groceryContext setShouldCategorizeGroceryItems:enabled];
        details[@"shouldCategorizeGroceryItems"] = @(enabled);
    }
    if (hasLocale) {
        if (![groceryContext respondsToSelector:@selector(setGroceryLocaleID:)]) {
            if (outError) *outError = @"ReminderKit grocery context does not support grocery locale changes";
            return;
        }
        NSString *localeID = cmd[@"groceryLocaleID"];
        [(REMListGroceryContextChangeItem *)groceryContext setGroceryLocaleID:localeID];
        details[@"groceryLocaleID"] = localeID;
    }
}

static NSArray<NSString *> *stringArray(id value, NSString *field, NSString **outError) {
    if (!value || value == [NSNull null]) {
        return @[];
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return s.length ? @[s] : @[];
    }
    if (![value isKindOfClass:[NSArray class]]) {
        if (outError) *outError = [NSString stringWithFormat:@"%@ must be a string or array of strings", field];
        return nil;
    }
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (id item in (NSArray *)value) {
        if (![item isKindOfClass:[NSString class]]) {
            if (outError) *outError = [NSString stringWithFormat:@"%@ must contain only strings", field];
            return nil;
        }
        NSString *s = [(NSString *)item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (s.length) {
            [result addObject:s];
        }
    }
    return result;
}

static NSURL *reminderURL(NSString *ckIdentifier) {
    return [NSURL URLWithString:[NSString stringWithFormat:@"x-apple-reminderkit://REMCDReminder/%@", ckIdentifier]];
}

static NSURL *sectionURL(NSString *ckIdentifier) {
    return [NSURL URLWithString:[NSString stringWithFormat:@"x-apple-reminderkit://REMCDListSection/%@", ckIdentifier]];
}

static NSURL *shareeURL(NSString *ckIdentifier) {
    return [NSURL URLWithString:[NSString stringWithFormat:@"x-apple-reminderkit://REMCDSharee/%@", ckIdentifier]];
}

static NSURL *listURL(NSString *ckIdentifier) {
    return [NSURL URLWithString:[NSString stringWithFormat:@"x-apple-reminderkit://REMCDList/%@", ckIdentifier]];
}

static NSURL *smartListURL(NSString *ckIdentifier) {
    return [NSURL URLWithString:[NSString stringWithFormat:@"x-apple-reminderkit://REMCDSmartList/%@", ckIdentifier]];
}

static NSURL *templateURL(NSString *ckIdentifier) {
    return [NSURL URLWithString:[NSString stringWithFormat:@"x-apple-reminderkit://REMCDTemplate/%@", ckIdentifier]];
}

static BOOL ipv4AddressIsPrivateOrLocal(uint32_t address) {
    uint32_t ip = ntohl(address);
    return
        ((ip & 0xff000000) == 0x00000000) ||      // 0.0.0.0/8
        ((ip & 0xff000000) == 0x0a000000) ||      // 10.0.0.0/8
        ((ip & 0xff000000) == 0x7f000000) ||      // 127.0.0.0/8
        ((ip & 0xffc00000) == 0x64400000) ||      // 100.64.0.0/10
        ((ip & 0xfff00000) == 0xac100000) ||      // 172.16.0.0/12
        ((ip & 0xffff0000) == 0xa9fe0000) ||      // 169.254.0.0/16
        ((ip & 0xffff0000) == 0xc0a80000) ||      // 192.168.0.0/16
        ((ip & 0xffffff00) == 0xc0000000) ||      // 192.0.0.0/24
        ((ip & 0xffffff00) == 0xc0000200) ||      // 192.0.2.0/24
        ((ip & 0xffffff00) == 0xc6336400) ||      // 198.51.100.0/24
        ((ip & 0xffffff00) == 0xcb007100) ||      // 203.0.113.0/24
        ((ip & 0xf0000000) == 0xe0000000);        // multicast/reserved
}

static BOOL sockaddrIsPrivateOrLocal(const struct sockaddr *addr) {
    if (!addr) return YES;
    if (addr->sa_family == AF_INET) {
        const struct sockaddr_in *ipv4 = (const struct sockaddr_in *)addr;
        return ipv4AddressIsPrivateOrLocal(ipv4->sin_addr.s_addr);
    }
    if (addr->sa_family == AF_INET6) {
        const struct sockaddr_in6 *ipv6 = (const struct sockaddr_in6 *)addr;
        const struct in6_addr *address = &ipv6->sin6_addr;
        return IN6_IS_ADDR_UNSPECIFIED(address) ||
            IN6_IS_ADDR_LOOPBACK(address) ||
            IN6_IS_ADDR_LINKLOCAL(address) ||
            IN6_IS_ADDR_SITELOCAL(address) ||
            IN6_IS_ADDR_MULTICAST(address) ||
            address->s6_addr[0] == 0xfc ||
            address->s6_addr[0] == 0xfd;
    }
    return YES;
}

static BOOL hostResolvesOnlyToPublicAddresses(NSString *host) {
    if (![host isKindOfClass:[NSString class]] || host.length == 0) {
        return NO;
    }
    NSString *lower = [host lowercaseString];
    if ([lower isEqualToString:@"localhost"] || [lower hasSuffix:@".local"]) {
        return NO;
    }

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_UNSPEC;

    struct addrinfo *results = NULL;
    int status = getaddrinfo([host UTF8String], NULL, &hints, &results);
    if (status != 0 || !results) {
        if (results) freeaddrinfo(results);
        return NO;
    }

    BOOL safe = YES;
    for (struct addrinfo *cursor = results; cursor != NULL; cursor = cursor->ai_next) {
        if (sockaddrIsPrivateOrLocal(cursor->ai_addr)) {
            safe = NO;
            break;
        }
    }
    freeaddrinfo(results);
    return safe;
}

static BOOL looksLikeWebURL(NSString *value) {
    NSURL *url = [NSURL URLWithString:value];
    if (!url || url.host.length == 0) {
        return NO;
    }
    NSString *scheme = [url.scheme lowercaseString];
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        return NO;
    }
    return hostResolvesOnlyToPublicAddresses(url.host);
}

static NSData *decodedBase64Data(NSString *value, NSString *field, NSString **outError) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) {
        if (outError) *outError = [NSString stringWithFormat:@"%@ is required", field];
        return nil;
    }
    NSData *data = [[NSData alloc] initWithBase64EncodedString:value options:0];
    if (!data || data.length == 0) {
        if (outError) *outError = [NSString stringWithFormat:@"%@ must be base64-encoded data", field];
        return nil;
    }
    if (data.length > 65536) {
        if (outError) *outError = [NSString stringWithFormat:@"%@ is too large", field];
        return nil;
    }
    return data;
}

static NSString *normalizedColorName(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return nil;
    if ([trimmed hasPrefix:@"#"]) return [trimmed uppercaseString];
    return [trimmed lowercaseString];
}

static REMColor *makeREMColor(NSString *value, NSString **outError) {
    NSString *name = normalizedColorName(value);
    if (!name) return nil;
    // ReminderKit rejects cyan as a symbolic private color on current macOS,
    // but accepts the same RGB value through the custom hex initializer path.
    if ([name isEqualToString:@"cyan"]) {
        name = @"#5AC8FA";
    }
    NSDictionary<NSString *, NSDictionary *> *colors = @{
        @"red": @{@"hex": @"#FF2968", @"r": @1.0, @"g": @0.1607843137254902, @"b": @0.40784313725490196, @"ck": @"red"},
        @"orange": @{@"hex": @"#FF8D28", @"r": @1.0, @"g": @0.5529411764705883, @"b": @0.1568627450980392, @"ck": @"orange"},
        @"yellow": @{@"hex": @"#FFCC00", @"r": @1.0, @"g": @0.8, @"b": @0.0, @"ck": @"yellow"},
        @"green": @{@"hex": @"#63DA38", @"r": @0.38823529411764707, @"g": @0.8549019607843137, @"b": @0.2196078431372549, @"ck": @"green"},
        @"blue": @{@"hex": @"#0088FF", @"r": @0.0, @"g": @0.5333333333333333, @"b": @1.0, @"ck": @"blue"},
        @"purple": @{@"hex": @"#CC73E1", @"r": @0.8, @"g": @0.45098039215686275, @"b": @0.8823529411764706, @"ck": @"purple"},
        @"brown": @{@"hex": @"#A2845E", @"r": @0.6352941176470588, @"g": @0.5176470588235295, @"b": @0.3686274509803922, @"ck": @"brown"},
        @"gray": @{@"hex": @"#5B626A", @"r": @0.3568627450980392, @"g": @0.3843137254901961, @"b": @0.41568627450980394, @"ck": @"gray"},
        @"cyan": @{@"hex": @"#5AC8FA", @"r": @0.35294117647058826, @"g": @0.7843137254901961, @"b": @0.9803921568627451, @"ck": @"cyan"},
        @"teal": @{@"hex": @"#30B0C7", @"r": @0.18823529411764706, @"g": @0.6901960784313725, @"b": @0.7803921568627451, @"ck": @"teal"},
    };
    NSDictionary *entry = colors[name];
    if (entry) {
        return [[REMColor alloc]
            initWithRed:[entry[@"r"] doubleValue]
            green:[entry[@"g"] doubleValue]
            blue:[entry[@"b"] doubleValue]
            alpha:1.0
            colorSpace:2
            daSymbolicColorName:entry[@"ck"]
            daHexString:entry[@"hex"]
            ckSymbolicColorName:entry[@"ck"]];
    }

    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^#[0-9A-F]{6}$" options:0 error:nil];
    if (![regex firstMatchInString:name options:0 range:NSMakeRange(0, name.length)]) {
        if (outError) *outError = [NSString stringWithFormat:@"Unsupported list color: %@", value];
        return nil;
    }
    unsigned int r = 0, g = 0, b = 0;
    NSScanner *scanner = [NSScanner scannerWithString:[name substringFromIndex:1]];
    unsigned int rgb = 0;
    [scanner scanHexInt:&rgb];
    r = (rgb >> 16) & 0xff;
    g = (rgb >> 8) & 0xff;
    b = rgb & 0xff;
    return [[REMColor alloc]
        initWithRed:(double)r / 255.0
        green:(double)g / 255.0
        blue:(double)b / 255.0
        alpha:1.0
        colorSpace:2
        daSymbolicColorName:@"custom"
        daHexString:name
        ckSymbolicColorName:@"custom"];
}

static NSArray<NSDictionary *> *subtaskSpecArray(NSDictionary *cmd, NSString **outError) {
    id value = cmd[@"subtasks"];
    if (value && value != [NSNull null]) {
        if (![value isKindOfClass:[NSArray class]]) {
            if (outError) *outError = @"subtasks must be an array of objects";
            return nil;
        }
        NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
        for (id item in (NSArray *)value) {
            if (![item isKindOfClass:[NSDictionary class]]) {
                if (outError) *outError = @"subtasks must contain only objects";
                return nil;
            }
            NSString *title = [(NSDictionary *)item objectForKey:@"title"];
            if (![title isKindOfClass:[NSString class]] || title.length == 0) {
                if (outError) *outError = @"Each subtask object requires a title";
                return nil;
            }
            [result addObject:item];
        }
        return result;
    }

    NSString *titlesError = nil;
    NSArray<NSString *> *titles = stringArray(cmd[@"titles"], @"titles", &titlesError);
    if (titlesError) {
        if (outError) *outError = titlesError;
        return nil;
    }
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSString *title in titles) {
        [result addObject:@{@"title": title}];
    }
    return result;
}

#pragma mark - Dispatch

NSDictionary *RKPDispatch(NSDictionary *request) {
    @try {
        @autoreleasepool {
            if (![request isKindOfClass:[NSDictionary class]]) {
                return errorDict(@"Invalid request");
            }
            NSDictionary *cmd = request;
            NSString *action = cmd[@"action"];
            NSSet<NSString *> *allowedActions = [NSSet setWithArray:@[
                @"add_private_metadata",
                @"add_url_attachments",
                @"add_tags",
                @"add_subtasks",
                @"assign_section",
                @"add_section_and_assign",
                @"assign_sharee",
                @"clear_assignment",
                @"add_attachments",
                @"set_flagged",
                @"set_urgent",
                @"set_early_reminder",
                @"add_location_alarm",
                @"create_list",
                @"set_list_appearance",
                @"set_list_pinned",
                @"set_smart_list_pinned",
                @"categorize_grocery_items",
                @"create_smart_list",
                @"update_smart_list",
                @"delete_smart_list",
                @"create_template",
                @"apply_template",
                @"delete_template",
            ]];
            if (![action isKindOfClass:[NSString class]] || ![allowedActions containsObject:action]) {
                RKP_FAIL(@"Unknown action");
            }

            NSError *error = nil;

            if ([action isEqualToString:@"create_list"]) {
                NSString *name = cmd[@"name"];
                if (![name isKindOfClass:[NSString class]] || name.length == 0) {
                    RKP_FAIL(@"name is required");
                }
                REMStore *store = [REMStore new];
                REMAccount *account = [store fetchPrimaryActiveCloudKitAccountWithError:&error];
                if (!account) {
                    account = [store fetchDefaultAccountWithError:&error];
                }
                if (!account) {
                    RKP_FAIL(error.localizedDescription ?: @"No active Reminders account found");
                }

                REMSaveRequest *save = [[REMSaveRequest alloc] initWithStore:store];
                id accountChange = [save updateAccount:account];
                if (!accountChange) {
                    RKP_FAIL(@"Could not create ReminderKit account change item");
                }
                REMListChangeItem *change = [save addListWithName:name toAccountChangeItem:accountChange listObjectID:nil];
                if (!change) {
                    RKP_FAIL(@"Could not create ReminderKit list change item");
                }
                if ([change respondsToSelector:@selector(setParentOwnerID:)]) {
                    [change setParentOwnerID:[account remObjectID]];
                }
                if ([accountChange respondsToSelector:@selector(addListChangeItem:)]) {
                    [accountChange addListChangeItem:change];
                }
                NSMutableDictionary *details = [NSMutableDictionary dictionaryWithDictionary:@{
                    @"status": @"created",
                    @"action": action,
                    @"name": name,
                }];
                RKP_PROPAGATE(applyListAppearance(change, cmd, details, @"List", &_rkpErr));
                RKP_PROPAGATE(applyListGroceryMetadata(change, cmd, details, &_rkpErr));

                if (![save saveSynchronouslyWithError:&error]) {
                    RKP_FAIL(error.localizedDescription ?: @"ReminderKit list save failed");
                }
                id objectID = [change remObjectID];
                NSString *uuid = objectID && [objectID respondsToSelector:@selector(uuid)] ? [[objectID uuid] UUIDString] : @"";
                NSString *url = objectID && [objectID respondsToSelector:@selector(urlRepresentation)] ? [[objectID urlRepresentation] absoluteString] : @"";
                details[@"id"] = uuid ?: @"";
                details[@"url"] = url ?: @"";
                return details;
            }
            if ([action isEqualToString:@"create_smart_list"]) {
                NSString *name = cmd[@"name"];
                if (![name isKindOfClass:[NSString class]] || name.length == 0) {
                    RKP_FAIL(@"name is required");
                }
                NSString *filterError = nil;
                NSData *filterData = decodedBase64Data(cmd[@"filterData"], @"filterData", &filterError);
                if (filterError) { RKP_FAIL(filterError); }
                REMStore *store = [REMStore new];
                REMAccount *account = [store fetchPrimaryActiveCloudKitAccountWithError:&error];
                if (!account) {
                    account = [store fetchDefaultAccountWithError:&error];
                }
                if (!account) {
                    RKP_FAIL(error.localizedDescription ?: @"No active Reminders account found");
                }
                REMAccountCapabilities *capabilities = [account capabilities];
                if (!capabilities || ![capabilities supportsCustomSmartLists]) {
                    RKP_FAIL(@"The selected Reminders account does not support custom smart lists");
                }

                REMSaveRequest *save = [[REMSaveRequest alloc] initWithStore:store];
                id accountChange = [save updateAccount:account];
                if (!accountChange) {
                    RKP_FAIL(@"Could not create ReminderKit account change item");
                }
                REMSmartListChangeItem *change = [save
                    addCustomSmartListWithName:name
                    toAccountChangeItem:accountChange
                    smartListObjectID:nil];
                if (!change) {
                    RKP_FAIL(@"Could not create ReminderKit smart list change item");
                }
                // addCustomSmartListWithName creates storage, but Reminders only treats it
                // as a live custom smart list after account ownership is explicit.
                if ([change respondsToSelector:@selector(setParentOwnerID:)]) {
                    [change setParentOwnerID:[account remObjectID]];
                }
                if ([accountChange respondsToSelector:@selector(addSmartListChangeItem:)]) {
                    [accountChange addSmartListChangeItem:change];
                }
                id customContext = [change respondsToSelector:@selector(customContext)] ? [change customContext] : nil;
                if (customContext && [customContext respondsToSelector:@selector(setName:)]) {
                    [(REMSmartListCustomContextChangeItem *)customContext setName:name];
                }
                // Reminders' edit UI ignores filterData when this stays at the default 0.
                RKP_PROPAGATE(setCustomSmartListSupportedVersion(change, &_rkpErr));
                [change setSmartListType:@"com.apple.reminders.smartlist.custom"];
                [change setFilterData:filterData];

                NSMutableDictionary *details = [NSMutableDictionary dictionaryWithDictionary:@{
                    @"status": @"created",
                    @"action": action,
                    @"name": name,
                }];
                RKP_PROPAGATE(applyListAppearance(change, cmd, details, @"Smart list", &_rkpErr));

                if (![save saveSynchronouslyWithError:&error]) {
                    RKP_FAIL(error.localizedDescription ?: @"ReminderKit smart list save failed");
                }
                id objectID = [change remObjectID];
                NSString *uuid = objectID && [objectID respondsToSelector:@selector(uuid)] ? [[objectID uuid] UUIDString] : @"";
                NSString *url = objectID && [objectID respondsToSelector:@selector(urlRepresentation)] ? [[objectID urlRepresentation] absoluteString] : @"";
                details[@"id"] = uuid ?: @"";
                details[@"url"] = url ?: @"";
                return details;
            }
            if ([action isEqualToString:@"update_smart_list"]) {
                NSString *smartListID = cmd[@"smartListId"];
                if (![smartListID isKindOfClass:[NSString class]] || smartListID.length == 0) {
                    RKP_FAIL(@"smartListId is required");
                }
                NSData *filterData = nil;
                if (cmd[@"filterData"] && cmd[@"filterData"] != [NSNull null]) {
                    NSString *filterError = nil;
                    filterData = decodedBase64Data(cmd[@"filterData"], @"filterData", &filterError);
                    if (filterError) { RKP_FAIL(filterError); }
                }
                NSString *name = cmd[@"name"];
                if (name && ![name isKindOfClass:[NSString class]]) {
                    RKP_FAIL(@"name must be a string");
                }
                BOOL hasAppearanceChange =
                    ([cmd[@"color"] isKindOfClass:[NSString class]] && [cmd[@"color"] length] > 0) ||
                    ([cmd[@"symbol"] isKindOfClass:[NSString class]] && [cmd[@"symbol"] length] > 0) ||
                    ([cmd[@"emoji"] isKindOfClass:[NSString class]] && [cmd[@"emoji"] length] > 0);
                if (!filterData && (!name || name.length == 0) && !hasAppearanceChange) {
                    RKP_FAIL(@"name, filterData, or appearance metadata is required");
                }
                NSURL *objectURL = smartListURL(smartListID);
                id objectID = [REMObjectID objectIDWithURL:objectURL];
                if (!objectID) {
                    RKP_FAIL(@"Could not build ReminderKit smart list object ID");
                }
                REMStore *store = [REMStore new];
                REMSmartList *smartList = [store fetchCustomSmartListWithObjectID:objectID error:&error];
                if (!smartList) {
                    RKP_FAIL(error.localizedDescription ?: @"Custom smart list not found");
                }
                REMSaveRequest *save = [[REMSaveRequest alloc] initWithStore:store];
                REMSmartListChangeItem *change = [save updateSmartList:smartList];
                if (!change) {
                    RKP_FAIL(@"Could not create ReminderKit smart list change item");
                }
                [change setSmartListType:@"com.apple.reminders.smartlist.custom"];
                RKP_PROPAGATE(setCustomSmartListSupportedVersion(change, &_rkpErr));
                if (filterData) {
                    [change setFilterData:filterData];
                }
                if (name.length > 0) {
                    [change setName:name];
                }
                NSMutableDictionary *details = [NSMutableDictionary dictionaryWithDictionary:@{
                    @"status": @"updated",
                    @"action": action,
                    @"id": smartListID,
                }];
                RKP_PROPAGATE(applyListAppearance(change, cmd, details, @"Smart list", &_rkpErr));
                if (![save saveSynchronouslyWithError:&error]) {
                    RKP_FAIL(error.localizedDescription ?: @"ReminderKit smart list update failed");
                }
                return details;
            }
            if ([action isEqualToString:@"delete_smart_list"]) {
                NSString *smartListID = cmd[@"smartListId"];
                if (![smartListID isKindOfClass:[NSString class]] || smartListID.length == 0) {
                    RKP_FAIL(@"smartListId is required");
                }
                NSURL *objectURL = smartListURL(smartListID);
                id objectID = [REMObjectID objectIDWithURL:objectURL];
                if (!objectID) {
                    RKP_FAIL(@"Could not build ReminderKit smart list object ID");
                }
                REMStore *store = [REMStore new];
                REMSmartList *smartList = [store fetchCustomSmartListWithObjectID:objectID error:&error];
                if (!smartList) {
                    RKP_FAIL(error.localizedDescription ?: @"Custom smart list not found");
                }
                REMAccount *account = [smartList account];
                if (!account) {
                    account = [store fetchPrimaryActiveCloudKitAccountWithError:&error];
                }
                if (!account) {
                    account = [store fetchDefaultAccountWithError:&error];
                }
                if (!account) {
                    RKP_FAIL(error.localizedDescription ?: @"No active Reminders account found");
                }

                REMSaveRequest *save = [[REMSaveRequest alloc] initWithStore:store];
                id accountChange = [save updateAccount:account];
                if (!accountChange) {
                    RKP_FAIL(@"Could not create ReminderKit account change item");
                }
                REMSmartListChangeItem *change = [save updateSmartList:smartList];
                if (!change) {
                    RKP_FAIL(@"Could not create ReminderKit smart list change item");
                }
                [change removeFromParentWithAccountChangeItem:accountChange];
                if (![save saveSynchronouslyWithError:&error]) {
                    RKP_FAIL(error.localizedDescription ?: @"ReminderKit smart list delete failed");
                }
                return @{
                    @"status": @"deleted",
                    @"action": action,
                    @"id": smartListID,
                };
            }
            if ([action isEqualToString:@"create_template"]) {
                NSString *name = cmd[@"name"];
                if (![name isKindOfClass:[NSString class]] || name.length == 0) {
                    RKP_FAIL(@"name is required");
                }
                NSString *listID = cmd[@"listId"];
                if (![listID isKindOfClass:[NSString class]] || listID.length == 0) {
                    RKP_FAIL(@"listId is required");
                }
                BOOL includeCompleted = [cmd[@"includeCompleted"] boolValue];
                NSURL *listObjectURL = listURL(listID);
                id listObjectID = [REMObjectID objectIDWithURL:listObjectURL];
                if (!listObjectID) {
                    RKP_FAIL(@"Could not build ReminderKit source list object ID");
                }
                REMStore *store = [REMStore new];
                id list = [store fetchListWithObjectID:listObjectID error:&error];
                if (!list) {
                    RKP_FAIL(error.localizedDescription ?: @"Source list not found");
                }
                REMAccount *account = [store fetchPrimaryActiveCloudKitAccountWithError:&error];
                if (!account) {
                    account = [store fetchDefaultAccountWithError:&error];
                }
                if (!account) {
                    RKP_FAIL(error.localizedDescription ?: @"No active Reminders account found");
                }
                REMSaveRequest *save = [[REMSaveRequest alloc] initWithStore:store];
                id accountChange = [save updateAccount:account];
                if (!accountChange) {
                    RKP_FAIL(@"Could not create ReminderKit account change item");
                }
                REMTemplateConfiguration *configuration = [[REMTemplateConfiguration alloc]
                    initWithSourceListID:listObjectID
                    shouldSaveCompleted:includeCompleted];
                REMTemplateChangeItem *change = [save
                    addTemplateWithName:name
                    configuration:configuration
                    toAccountChangeItem:accountChange];
                if (!change) {
                    RKP_FAIL(@"Could not create ReminderKit template change item");
                }
                if (![save saveSynchronouslyWithError:&error]) {
                    RKP_FAIL(error.localizedDescription ?: @"ReminderKit template save failed");
                }
                id objectID = [change remObjectID];
                NSString *uuid = objectID && [objectID respondsToSelector:@selector(uuid)] ? [[objectID uuid] UUIDString] : @"";
                NSString *url = objectID && [objectID respondsToSelector:@selector(urlRepresentation)] ? [[objectID urlRepresentation] absoluteString] : @"";
                return @{
                    @"status": @"created",
                    @"action": action,
                    @"name": name,
                    @"sourceListId": listID,
                    @"includeCompleted": @(includeCompleted),
                    @"id": uuid ?: @"",
                    @"url": url ?: @"",
                };
            }
            if ([action isEqualToString:@"apply_template"]) {
                NSString *templateID = cmd[@"templateId"];
                if (![templateID isKindOfClass:[NSString class]] || templateID.length == 0) {
                    RKP_FAIL(@"templateId is required");
                }
                NSURL *objectURL = templateURL(templateID);
                id objectID = [REMObjectID objectIDWithURL:objectURL];
                if (!objectID) {
                    RKP_FAIL(@"Could not build ReminderKit template object ID");
                }
                REMStore *store = [REMStore new];
                REMTemplate *templateObject = [store fetchTemplateWithObjectID:objectID error:&error];
                if (!templateObject) {
                    RKP_FAIL(error.localizedDescription ?: @"Template not found");
                }
                REMAccount *account = [store fetchPrimaryActiveCloudKitAccountWithError:&error];
                if (!account) {
                    account = [store fetchDefaultAccountWithError:&error];
                }
                if (!account) {
                    RKP_FAIL(error.localizedDescription ?: @"No active Reminders account found");
                }
                REMSaveRequest *save = [[REMSaveRequest alloc] initWithStore:store];
                id accountChange = [save updateAccount:account];
                if (!accountChange) {
                    RKP_FAIL(@"Could not create ReminderKit account change item");
                }
                REMListChangeItem *change = [save addListUsingTemplate:templateObject toAccountChangeItem:accountChange];
                if (!change) {
                    RKP_FAIL(@"Could not create ReminderKit list from template change item");
                }
                if (![save saveSynchronouslyWithError:&error]) {
                    RKP_FAIL(error.localizedDescription ?: @"ReminderKit template application failed");
                }
                id newObjectID = [change remObjectID];
                NSString *uuid = newObjectID && [newObjectID respondsToSelector:@selector(uuid)] ? [[newObjectID uuid] UUIDString] : @"";
                NSString *url = newObjectID && [newObjectID respondsToSelector:@selector(urlRepresentation)] ? [[newObjectID urlRepresentation] absoluteString] : @"";
                return @{
                    @"status": @"created",
                    @"action": action,
                    @"templateId": templateID,
                    @"id": uuid ?: @"",
                    @"url": url ?: @"",
                };
            }
            if ([action isEqualToString:@"delete_template"]) {
                NSString *templateID = cmd[@"templateId"];
                if (![templateID isKindOfClass:[NSString class]] || templateID.length == 0) {
                    RKP_FAIL(@"templateId is required");
                }
                NSURL *objectURL = templateURL(templateID);
                id objectID = [REMObjectID objectIDWithURL:objectURL];
                if (!objectID) {
                    RKP_FAIL(@"Could not build ReminderKit template object ID");
                }
                REMStore *store = [REMStore new];
                REMTemplate *templateObject = [store fetchTemplateWithObjectID:objectID error:&error];
                if (!templateObject) {
                    RKP_FAIL(error.localizedDescription ?: @"Template not found");
                }
                REMSaveRequest *save = [[REMSaveRequest alloc] initWithStore:store];
                REMTemplateChangeItem *change = [save updateTemplate:templateObject];
                if (!change) {
                    RKP_FAIL(@"Could not create ReminderKit template change item");
                }
                [change removeFromParentAccount];
                if (![save saveSynchronouslyWithError:&error]) {
                    RKP_FAIL(error.localizedDescription ?: @"ReminderKit template delete failed");
                }
                return @{
                    @"status": @"deleted",
                    @"action": action,
                    @"id": templateID,
                };
            }
            if ([action isEqualToString:@"set_list_appearance"]) {
                NSString *listID = cmd[@"listId"];
                if (![listID isKindOfClass:[NSString class]] || listID.length == 0) {
                    RKP_FAIL(@"listId is required");
                }
                NSURL *objectURL = listURL(listID);
                id objectID = [REMObjectID objectIDWithURL:objectURL];
                if (!objectID) {
                    RKP_FAIL(@"Could not build ReminderKit list object ID");
                }
                REMStore *store = [REMStore new];
                id list = [store fetchListWithObjectID:objectID error:&error];
                if (!list) {
                    RKP_FAIL(error.localizedDescription ?: @"List not found");
                }
                REMSaveRequest *save = [[REMSaveRequest alloc] initWithStore:store];
                REMListChangeItem *change = [save updateList:list];
                if (!change) {
                    RKP_FAIL(@"Could not create ReminderKit list change item");
                }

                NSMutableDictionary *details = [NSMutableDictionary dictionaryWithDictionary:@{
                    @"status": @"updated",
                    @"action": action,
                    @"listId": listID,
                }];
                NSString *newName = cmd[@"name"];
                if ([newName isKindOfClass:[NSString class]] && newName.length) {
                    [change setName:newName];
                    details[@"name"] = newName;
                }
                RKP_PROPAGATE(applyListAppearance(change, cmd, details, @"List", &_rkpErr));
                RKP_PROPAGATE(applyListGroceryMetadata(change, cmd, details, &_rkpErr));

                if (![save saveSynchronouslyWithError:&error]) {
                    RKP_FAIL(error.localizedDescription ?: @"ReminderKit list save failed");
                }
                return details;
            }
            if ([action isEqualToString:@"set_list_pinned"]) {
                NSString *listID = cmd[@"listId"];
                if (![listID isKindOfClass:[NSString class]] || listID.length == 0) {
                    RKP_FAIL(@"listId is required");
                }
                NSNumber *pinned = cmd[@"pinned"];
                if (![pinned isKindOfClass:[NSNumber class]]) {
                    RKP_FAIL(@"pinned is required");
                }
                NSURL *objectURL = listURL(listID);
                id objectID = [REMObjectID objectIDWithURL:objectURL];
                if (!objectID) {
                    RKP_FAIL(@"Could not build ReminderKit list object ID");
                }
                REMStore *store = [REMStore new];
                id list = [store fetchListWithObjectID:objectID error:&error];
                if (!list) {
                    RKP_FAIL(error.localizedDescription ?: @"List not found");
                }
                REMSaveRequest *save = [[REMSaveRequest alloc] initWithStore:store];
                REMListChangeItem *change = [save updateList:list];
                if (!change) {
                    RKP_FAIL(@"Could not create ReminderKit list change item");
                }
                if (![change respondsToSelector:@selector(setIsPinned:)]) {
                    RKP_FAIL(@"ReminderKit list change item does not support pinning");
                }
                [change setIsPinned:[pinned boolValue]];
                if (![save saveSynchronouslyWithError:&error]) {
                    RKP_FAIL(error.localizedDescription ?: @"ReminderKit list pin save failed");
                }
                return @{
                    @"status": @"updated",
                    @"action": action,
                    @"listId": listID,
                    @"pinned": @([pinned boolValue]),
                };
            }
            if ([action isEqualToString:@"set_smart_list_pinned"]) {
                NSString *smartListID = cmd[@"smartListId"];
                if (![smartListID isKindOfClass:[NSString class]] || smartListID.length == 0) {
                    RKP_FAIL(@"smartListId is required");
                }
                NSNumber *pinned = cmd[@"pinned"];
                if (![pinned isKindOfClass:[NSNumber class]]) {
                    RKP_FAIL(@"pinned is required");
                }
                NSURL *objectURL = smartListURL(smartListID);
                id objectID = [REMObjectID objectIDWithURL:objectURL];
                if (!objectID) {
                    RKP_FAIL(@"Could not build ReminderKit smart list object ID");
                }
                REMStore *store = [REMStore new];
                id smartList = nil;
                if ([store respondsToSelector:@selector(fetchSmartListWithObjectID:error:)]) {
                    smartList = [store fetchSmartListWithObjectID:objectID error:&error];
                }
                if (!smartList) {
                    smartList = [store fetchCustomSmartListWithObjectID:objectID error:&error];
                }
                if (!smartList) {
                    RKP_FAIL(error.localizedDescription ?: @"Smart list not found");
                }
                REMSaveRequest *save = [[REMSaveRequest alloc] initWithStore:store];
                REMSmartListChangeItem *change = [save updateSmartList:smartList];
                if (!change) {
                    RKP_FAIL(@"Could not create ReminderKit smart list change item");
                }
                if (![change respondsToSelector:@selector(setIsPinned:)]) {
                    RKP_FAIL(@"ReminderKit smart list change item does not support pinning");
                }
                [change setIsPinned:[pinned boolValue]];
                if (![save saveSynchronouslyWithError:&error]) {
                    RKP_FAIL(error.localizedDescription ?: @"ReminderKit smart list pin save failed");
                }
                return @{
                    @"status": @"updated",
                    @"action": action,
                    @"smartListId": smartListID,
                    @"pinned": @([pinned boolValue]),
                };
            }
            if ([action isEqualToString:@"categorize_grocery_items"]) {
                NSString *listID = cmd[@"listId"];
                if (![listID isKindOfClass:[NSString class]] || listID.length == 0) {
                    RKP_FAIL(@"listId is required");
                }
                NSString *reminderIDsError = nil;
                NSArray<NSString *> *reminderIDs = stringArray(cmd[@"reminderIds"], @"reminderIds", &reminderIDsError);
                if (reminderIDsError) { RKP_FAIL(reminderIDsError); }
                if (reminderIDs.count == 0) {
                    RKP_FAIL(@"At least one reminder ID is required");
                }
                NSURL *objectURL = listURL(listID);
                id objectID = [REMObjectID objectIDWithURL:objectURL];
                if (!objectID) {
                    RKP_FAIL(@"Could not build ReminderKit list object ID");
                }
                REMStore *store = [REMStore new];
                id list = [store fetchListWithObjectID:objectID error:&error];
                if (!list) {
                    RKP_FAIL(error.localizedDescription ?: @"List not found");
                }
                REMSaveRequest *save = [[REMSaveRequest alloc] initWithStore:store];
                REMListChangeItem *change = [save updateList:list];
                if (!change) {
                    RKP_FAIL(@"Could not create ReminderKit list change item");
                }
                if (![change respondsToSelector:@selector(groceryContextChangeItem)]) {
                    RKP_FAIL(@"ReminderKit list change item does not support grocery categorization");
                }
                id groceryContext = [change groceryContextChangeItem];
                if (!groceryContext || ![groceryContext respondsToSelector:@selector(categorizeGroceryItemsWithReminderIDs:)]) {
                    RKP_FAIL(@"ReminderKit grocery context does not support item categorization");
                }
                NSMutableArray *uuids = [NSMutableArray array];
                for (NSString *reminderID in reminderIDs) {
                    NSURL *reminderObjectURL = reminderURL(reminderID);
                    id reminderObjectID = [REMObjectID objectIDWithURL:reminderObjectURL];
                    if (!reminderObjectID || ![reminderObjectID respondsToSelector:@selector(uuid)]) {
                        RKP_FAIL([NSString stringWithFormat:@"Could not build ReminderKit reminder object ID: %@", reminderID]);
                    }
                    [uuids addObject:[reminderObjectID uuid]];
                }
                @try {
                    [(REMListGroceryContextChangeItem *)groceryContext categorizeGroceryItemsWithReminderIDs:uuids];
                } @catch (NSException *exception) {
                    RKP_FAIL([NSString stringWithFormat:@"ReminderKit grocery categorization failed: %@", exception.reason ?: exception.name]);
                }
                if (![save saveSynchronouslyWithError:&error]) {
                    RKP_FAIL(error.localizedDescription ?: @"ReminderKit grocery categorization save failed");
                }
                return @{
                    @"status": @"updated",
                    @"action": action,
                    @"listId": listID,
                    @"remindersCategorized": @(reminderIDs.count),
                };
            }

            // ---- Reminder-scoped actions (shared tail) ----
            NSString *reminderID = cmd[@"id"];
            if (![reminderID isKindOfClass:[NSString class]] || reminderID.length == 0) {
                RKP_FAIL(@"id is required");
            }

            NSString *urlsError = nil;
            NSArray<NSString *> *urls = stringArray(cmd[@"urls"], @"urls", &urlsError);
            if (urlsError) { RKP_FAIL(urlsError); }
            NSString *tagsError = nil;
            NSArray<NSString *> *tags = stringArray(cmd[@"tags"], @"tags", &tagsError);
            if (tagsError) { RKP_FAIL(tagsError); }
            NSURL *objectURL = reminderURL(reminderID);
            id objectID = [REMObjectID objectIDWithURL:objectURL];
            if (!objectID) {
                RKP_FAIL(@"Could not build ReminderKit object ID");
            }

            REMStore *store = [REMStore new];
            id reminder = [store fetchReminderWithObjectID:objectID error:&error];
            if (!reminder) {
                RKP_FAIL(error.localizedDescription ?: @"Reminder not found");
            }

            REMSaveRequest *save = [[REMSaveRequest alloc] initWithStore:store];
            REMReminderChangeItem *change = [save updateReminder:reminder];
            if (!change) {
                RKP_FAIL(@"Could not create ReminderKit change item");
            }

            NSInteger addedURLs = 0;
            NSInteger addedTags = 0;
            NSInteger addedImages = 0;
            NSInteger addedSubtasks = 0;
            NSMutableDictionary *details = [NSMutableDictionary dictionaryWithDictionary:@{
                @"status": @"updated",
                @"id": reminderID,
                @"action": action ?: @"",
            }];

            if ([action isEqualToString:@"add_private_metadata"]) {
                if (urls.count == 0 && tags.count == 0) {
                    RKP_FAIL(@"At least one URL or tag is required");
                }
            } else if ([action isEqualToString:@"add_url_attachments"]) {
                if (urls.count == 0) { RKP_FAIL(@"At least one URL is required"); }
            } else if ([action isEqualToString:@"add_tags"]) {
                if (tags.count == 0) { RKP_FAIL(@"At least one tag is required"); }
            } else if ([action isEqualToString:@"add_subtasks"]) {
                NSString *subtaskError = nil;
                NSArray<NSDictionary *> *subtaskSpecs = subtaskSpecArray(cmd, &subtaskError);
                if (subtaskError) { RKP_FAIL(subtaskError); }
                if (subtaskSpecs.count == 0) { RKP_FAIL(@"At least one subtask is required"); }
                id subtaskContext = [change subtaskContext];
                NSMutableArray *subtaskURLs = [NSMutableArray array];
                NSMutableArray *subtaskDetails = [NSMutableArray array];
                for (NSDictionary *subtaskSpec in subtaskSpecs) {
                    NSString *title = subtaskSpec[@"title"];
                    id subtask = [save addReminderWithTitle:title toReminderSubtaskContextChangeItem:subtaskContext];
                    if (!subtask) { RKP_FAIL([NSString stringWithFormat:@"Could not create subtask: %@", title]); }
                    id subtaskID = [subtask remObjectID];
                    NSString *subtaskURL = subtaskID ? ([[subtaskID urlRepresentation] absoluteString] ?: @"") : @"";
                    NSString *subtaskIdentifier = subtaskID && [subtaskID respondsToSelector:@selector(uuid)] ? [[subtaskID uuid] UUIDString] : @"";
                    if (subtaskURL.length) [subtaskURLs addObject:subtaskURL];
                    [subtaskDetails addObject:@{
                        @"id": subtaskIdentifier ?: @"",
                        @"title": title ?: @"",
                        @"url": subtaskURL ?: @"",
                    }];
                    addedSubtasks += 1;
                }
                details[@"subtaskURLs"] = subtaskURLs;
                details[@"subtasks"] = subtaskDetails;
            } else if ([action isEqualToString:@"assign_section"]) {
                NSString *sectionID = cmd[@"sectionId"];
                if (![sectionID isKindOfClass:[NSString class]] || sectionID.length == 0) { RKP_FAIL(@"sectionId is required"); }
                id sectionObjectID = [REMObjectID objectIDWithURL:sectionURL(sectionID)];
                id section = [store fetchListSectionWithObjectID:sectionObjectID error:&error];
                if (!section) { RKP_FAIL(error.localizedDescription ?: @"Section not found"); }
                id listChange = [save updateList:[reminder list]];
                id sectionContext = [listChange sectionsContextChangeItem];
                id membership = [[REMMembership alloc] initWithMemberIdentifier:[objectID uuid] groupIdentifier:[sectionObjectID uuid] isObsolete:NO modifiedOn:[NSDate date]];
                id memberships = [[REMMemberships alloc] initWithMemberships:@[membership]];
                [sectionContext setUnsavedMembershipsOfRemindersInSections:memberships];
                details[@"sectionId"] = sectionID;
            } else if ([action isEqualToString:@"add_section_and_assign"]) {
                NSString *name = cmd[@"name"];
                if (![name isKindOfClass:[NSString class]] || name.length == 0) { RKP_FAIL(@"name is required"); }
                id listChange = [save updateList:[reminder list]];
                id sectionContext = [listChange sectionsContextChangeItem];
                id sectionChange = [save addListSectionWithDisplayName:name toListSectionContextChangeItem:sectionContext];
                id sectionObjectID = [sectionChange remObjectID];
                if (!sectionObjectID) { RKP_FAIL(@"Could not create section object ID"); }
                id membership = [[REMMembership alloc] initWithMemberIdentifier:[objectID uuid] groupIdentifier:[sectionObjectID uuid] isObsolete:NO modifiedOn:[NSDate date]];
                id memberships = [[REMMemberships alloc] initWithMemberships:@[membership]];
                [sectionContext setUnsavedMembershipsOfRemindersInSections:memberships];
                [sectionContext setUnsavedSectionIDsOrdering:@[sectionObjectID]];
                [sectionContext setShouldUpdateSectionsOrdering:YES];
                details[@"sectionURL"] = [[sectionObjectID urlRepresentation] absoluteString] ?: @"";
            } else if ([action isEqualToString:@"assign_sharee"]) {
                NSString *assigneeID = cmd[@"assigneeId"];
                NSString *originatorID = cmd[@"originatorId"];
                if (![assigneeID isKindOfClass:[NSString class]] || assigneeID.length == 0) { RKP_FAIL(@"assigneeId is required"); }
                if (![originatorID isKindOfClass:[NSString class]] || originatorID.length == 0) { RKP_FAIL(@"originatorId is required"); }
                id assignmentContext = [change assignmentContext];
                if (!assignmentContext || ![assignmentContext respondsToSelector:@selector(addAssignmentWithAssigneeID:originatorID:status:)]) {
                    RKP_FAIL(@"ReminderKit reminder change item does not support assignment");
                }
                id assigneeObjectID = [REMObjectID objectIDWithURL:shareeURL(assigneeID)];
                id originatorObjectID = [REMObjectID objectIDWithURL:shareeURL(originatorID)];
                if (!assigneeObjectID) { RKP_FAIL(@"Could not build ReminderKit assignee object ID"); }
                if (!originatorObjectID) { RKP_FAIL(@"Could not build ReminderKit originator object ID"); }
                [assignmentContext removeAllAssignments];
                id assignment = [(REMReminderAssignmentContextChangeItem *)assignmentContext addAssignmentWithAssigneeID:assigneeObjectID originatorID:originatorObjectID status:1];
                if (!assignment) { RKP_FAIL(@"Could not create ReminderKit assignment"); }
                details[@"assigneeId"] = assigneeID;
                details[@"originatorId"] = originatorID;
            } else if ([action isEqualToString:@"clear_assignment"]) {
                id assignmentContext = [change assignmentContext];
                if (!assignmentContext || ![assignmentContext respondsToSelector:@selector(removeAllAssignments)]) {
                    RKP_FAIL(@"ReminderKit reminder change item does not support assignment");
                }
                [assignmentContext removeAllAssignments];
                details[@"assignmentCleared"] = @YES;
            } else if ([action isEqualToString:@"add_attachments"]) {
                NSString *filesError = nil;
                NSArray<NSString *> *files = stringArray(cmd[@"files"], @"files", &filesError);
                if (filesError) { RKP_FAIL(filesError); }
                NSString *imagesError = nil;
                NSArray<NSString *> *images = stringArray(cmd[@"images"], @"images", &imagesError);
                if (imagesError) { RKP_FAIL(imagesError); }
                if (files.count > 0) { RKP_FAIL(@"Generic file/PDF attachments are not supported; use images only"); }
                if (images.count == 0) { RKP_FAIL(@"At least one image path is required"); }
                id attachmentContext = [change attachmentContext];
                for (NSString *path in images) {
                    if (![[NSFileManager defaultManager] isReadableFileAtPath:path]) {
                        RKP_FAIL([NSString stringWithFormat:@"Image is not readable: %@", path]);
                    }
                    NSURL *fileURL = [NSURL fileURLWithPath:path];
                    NSUInteger width = [cmd[@"width"] unsignedIntegerValue];
                    NSUInteger height = [cmd[@"height"] unsignedIntegerValue];
                    NSImage *image = [[NSImage alloc] initWithContentsOfURL:fileURL];
                    if (!image || image.size.width <= 0 || image.size.height <= 0) {
                        RKP_FAIL([NSString stringWithFormat:@"Image attachment must be a readable image file: %@", path]);
                    }
                    if (width == 0 || height == 0) {
                        width = (NSUInteger)lrint(image.size.width);
                        height = (NSUInteger)lrint(image.size.height);
                    }
                    id attachment = [attachmentContext addImageAttachmentWithURL:fileURL width:width height:height error:&error];
                    if (!attachment) { RKP_FAIL(error.localizedDescription ?: [NSString stringWithFormat:@"Image attachment failed: %@", path]); }
                    addedImages += 1;
                }
            } else if ([action isEqualToString:@"set_flagged"]) {
                [[change flaggedContext] setFlagged:[cmd[@"flagged"] boolValue] ? 1 : 0];
                details[@"flagged"] = @([cmd[@"flagged"] boolValue]);
            } else if ([action isEqualToString:@"set_urgent"]) {
                [[change urgentAlarmContext] setIsUrgentStateEnabledForCurrentUser:[cmd[@"urgent"] boolValue]];
                details[@"urgent"] = @([cmd[@"urgent"] boolValue]);
            } else if ([action isEqualToString:@"set_early_reminder"]) {
                id context = [change dueDateDeltaAlertContext];
                if (!context) { RKP_FAIL(@"Reminder does not support Early Reminder changes"); }
                NSArray *existingIdentifiers = cmd[@"existingIdentifiers"];
                if ([existingIdentifiers isKindOfClass:[NSArray class]] && existingIdentifiers.count) {
                    NSMutableArray *uuids = [NSMutableArray array];
                    for (id rawIdentifier in existingIdentifiers) {
                        if (![rawIdentifier isKindOfClass:[NSString class]]) continue;
                        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:(NSString *)rawIdentifier];
                        if (uuid) [uuids addObject:uuid];
                    }
                    if (uuids.count) {
                        [context removeDueDateDeltaAlertsWithIdentifiers:uuids];
                        details[@"earlyReminderRemoved"] = @(uuids.count);
                    }
                }
                [context removeAllFetchedDueDateDeltaAlerts];
                if ([cmd[@"clear"] boolValue]) {
                    details[@"earlyReminderCleared"] = @YES;
                } else {
                    NSInteger unit = [cmd[@"unit"] integerValue];
                    NSInteger count = [cmd[@"count"] integerValue];
                    if (unit < 0 || unit > 4) { RKP_FAIL(@"Early Reminder unit must be between 0 and 4"); }
                    if (count == 0) { RKP_FAIL(@"Early Reminder count cannot be 0"); }
                    REMDueDateDeltaInterval *delta = [[REMDueDateDeltaInterval alloc] initWithUnit:unit count:count];
                    id alert = [context addDueDateDeltaAlertWithDueDateDelta:delta];
                    if (!alert) { RKP_FAIL(@"Could not create Early Reminder delta alert"); }
                    details[@"earlyReminder"] = @{@"unit": @(unit), @"count": @(count)};
                }
            } else if ([action isEqualToString:@"add_location_alarm"]) {
                NSString *title = cmd[@"title"] ?: @"Location";
                double lat = [cmd[@"latitude"] doubleValue];
                double lon = [cmd[@"longitude"] doubleValue];
                double radius = [cmd[@"radius"] doubleValue];
                NSInteger proximity = [cmd[@"proximity"] integerValue];
                if (radius <= 0.0) radius = 100.0;
                if (proximity != 1 && proximity != 2) proximity = 1;
                if (lat < -90.0 || lat > 90.0) { RKP_FAIL(@"latitude must be between -90 and 90"); }
                if (lon < -180.0 || lon > 180.0) { RKP_FAIL(@"longitude must be between -180 and 180"); }
                REMStructuredLocation *location = [[REMStructuredLocation alloc]
                    initWithTitle:title
                    locationUID:[[NSUUID UUID] UUIDString]
                    latitude:lat
                    longitude:lon
                    radius:radius
                    address:cmd[@"address"]
                    routing:nil
                    referenceFrameString:nil
                    contactLabel:nil
                    mapKitHandle:nil];
                id trigger = [[REMAlarmLocationTrigger alloc] initWithStructuredLocation:location proximity:proximity];
                id alarm = [[REMAlarm alloc] initWithTrigger:trigger];
                [change addAlarm:alarm];
                details[@"locationTitle"] = title;
            }

            if (([action isEqualToString:@"add_private_metadata"] || [action isEqualToString:@"add_url_attachments"]) && urls.count) {
                id attachmentContext = [change attachmentContext];
                for (NSString *urlString in urls) {
                    if (!looksLikeWebURL(urlString)) {
                        RKP_FAIL([NSString stringWithFormat:@"Invalid web URL: %@", urlString]);
                    }
                    NSURL *url = [NSURL URLWithString:urlString];
                    [attachmentContext addURLAttachmentWithURL:url];
                    addedURLs += 1;
                }
            }
            if (([action isEqualToString:@"add_private_metadata"] || [action isEqualToString:@"add_tags"]) && tags.count) {
                id hashtagContext = [change hashtagContext];
                for (NSString *tag in tags) {
                    [hashtagContext addHashtagWithType:1 name:tag];
                    addedTags += 1;
                }
            }

            if (![save saveSynchronouslyWithError:&error]) {
                RKP_FAIL(error.localizedDescription ?: @"ReminderKit save failed");
            }

            details[@"urlsAdded"] = @(addedURLs);
            details[@"tagsAdded"] = @(addedTags);
            details[@"imagesAdded"] = @(addedImages);
            details[@"subtasksAdded"] = @(addedSubtasks);
            return details;
        }
    } @catch (NSException *e) {
        return errorDict(e.reason ?: @"private API fault");
    }
}
