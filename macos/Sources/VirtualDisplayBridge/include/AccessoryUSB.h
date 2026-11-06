#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A bulk IN/OUT channel to an Android phone in USB accessory (AOA) mode.
@interface EDAccessoryConnection : NSObject
@property (nonatomic, readonly, copy) NSString *deviceName;
/// Called on an internal read thread.
@property (nonatomic, copy, nullable) void (^onData)(NSData *data);
/// Called once, on an internal thread, when the link goes away.
@property (nonatomic, copy, nullable) void (^onClose)(void);

- (void)startReading;
/// Writes asynchronously (in order); completion runs on an internal queue.
- (void)write:(NSData *)data completion:(nullable void (^)(BOOL ok))completion;
- (void)close;
@end

/// Watches USB: switches Android phones into accessory mode and reports accessory links.
@interface EDAccessoryManager : NSObject
@property (nonatomic) BOOL enabled;
/// Main thread.
@property (nonatomic, copy, nullable) void (^onAccessory)(EDAccessoryConnection *connection);
/// Main thread.
@property (nonatomic, copy, nullable) void (^onStatus)(NSString *status);
- (void)start;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
