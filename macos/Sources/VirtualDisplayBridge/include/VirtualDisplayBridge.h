#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin wrapper around the private CoreGraphics CGVirtualDisplay API.
/// Classes are looked up at runtime so no private symbols are linked.
@interface EDVirtualDisplay : NSObject

@property (nonatomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, readonly) unsigned int maxPixelsWide;
@property (nonatomic, readonly) unsigned int maxPixelsHigh;

+ (BOOL)isSupported;

- (nullable instancetype)initWithName:(NSString *)name
                        maxPixelsWide:(unsigned int)maxPixelsWide
                        maxPixelsHigh:(unsigned int)maxPixelsHigh
                    sizeInMillimeters:(CGSize)sizeInMillimeters
                               serial:(unsigned int)serial NS_SWIFT_NAME(init(name:maxPixelsWide:maxPixelsHigh:sizeInMillimeters:serial:));

/// Width/height are in points when hiDPI is YES (backing store is 2x).
- (BOOL)applyModeWidth:(unsigned int)width
                height:(unsigned int)height
           refreshRate:(double)refreshRate
                 hiDPI:(BOOL)hiDPI NS_SWIFT_NAME(applyMode(width:height:refreshRate:hiDPI:));

@end

NS_ASSUME_NONNULL_END
