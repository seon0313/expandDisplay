#import "VirtualDisplayBridge.h"

// ---- Private CoreGraphics API declarations (macOS 10.14+) ----
@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (copy, nonatomic) void (^terminationHandler)(id, CGVirtualDisplay *);
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplayMode : NSObject
@property (readonly, nonatomic) unsigned int width;
@property (readonly, nonatomic) unsigned int height;
@property (readonly, nonatomic) double refreshRate;
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end
// --------------------------------------------------------------

@implementation EDVirtualDisplay {
    id _display;
}

+ (BOOL)isSupported {
    return NSClassFromString(@"CGVirtualDisplay") != nil
        && NSClassFromString(@"CGVirtualDisplayDescriptor") != nil
        && NSClassFromString(@"CGVirtualDisplaySettings") != nil
        && NSClassFromString(@"CGVirtualDisplayMode") != nil;
}

- (instancetype)initWithName:(NSString *)name
               maxPixelsWide:(unsigned int)maxPixelsWide
               maxPixelsHigh:(unsigned int)maxPixelsHigh
           sizeInMillimeters:(CGSize)sizeInMillimeters
                      serial:(unsigned int)serial {
    self = [super init];
    if (!self) return nil;
    if (![EDVirtualDisplay isSupported]) return nil;

    CGVirtualDisplayDescriptor *desc = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    if ([desc respondsToSelector:@selector(setDispatchQueue:)]) {
        [desc setDispatchQueue:dispatch_get_main_queue()];
    } else {
        desc.queue = dispatch_get_main_queue();
    }
    desc.name = name;
    desc.maxPixelsWide = maxPixelsWide;
    desc.maxPixelsHigh = maxPixelsHigh;
    desc.sizeInMillimeters = sizeInMillimeters;
    desc.serialNum = serial;
    desc.productID = 0xED01;
    desc.vendorID = 0x5E0D;
    desc.terminationHandler = ^(id a, CGVirtualDisplay *b) {};

    CGVirtualDisplay *display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:desc];
    if (!display) return nil;
    _display = display;
    _maxPixelsWide = maxPixelsWide;
    _maxPixelsHigh = maxPixelsHigh;
    return self;
}

- (CGDirectDisplayID)displayID {
    return [(CGVirtualDisplay *)_display displayID];
}

- (BOOL)applyModeWidth:(unsigned int)width
                height:(unsigned int)height
           refreshRate:(double)refreshRate
                 hiDPI:(BOOL)hiDPI {
    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    CGVirtualDisplayMode *mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc]
                                  initWithWidth:width height:height refreshRate:refreshRate];
    settings.modes = @[mode];
    return [(CGVirtualDisplay *)_display applySettings:settings];
}

@end
