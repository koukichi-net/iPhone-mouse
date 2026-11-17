#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside @try/@catch. Returns nil if no exception was raised,
/// otherwise "<name>: <reason>". CoreBluetooth reports some misuse by raising
/// NSException, which Swift cannot catch.
NSString * _Nullable HPTryCatch(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
