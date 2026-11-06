#import "AccessoryUSB.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/usb/IOUSBLib.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// ---- Android Open Accessory protocol ----
static const UInt16 kAOAVendorGoogle = 0x18D1;
static const UInt8 kAOAGetProtocol = 51;
static const UInt8 kAOASendString = 52;
static const UInt8 kAOAStart = 53;

static NSString *const kAccManufacturer = @"seon0313";
static NSString *const kAccModel = @"ExpandDisplay";
static NSString *const kAccDescription = @"ExpandDisplay - use this phone as a Mac display";
static NSString *const kAccVersion = @"1.0";
static NSString *const kAccURI = @"https://github.com/seon0313/expandDisplay/releases";
static NSString *const kAccSerial = @"ED0001";

static BOOL isAccessoryPID(UInt16 pid) { return pid >= 0x2D00 && pid <= 0x2D05; }

// Vendors of Android phones we try to switch into accessory mode.
static BOOL isAndroidVendor(UInt16 vid) {
    static const UInt16 vendors[] = {
        0x04E8, // Samsung
        0x18D1, // Google
        0x2717, // Xiaomi
        0x2A70, // OnePlus
        0x22B8, // Motorola
        0x1004, // LG
        0x12D1, // Huawei
        0x0FCE, // Sony
        0x22D9, // OPPO
        0x2D95, // vivo
        0x0B05, // ASUS
        0x05C6, // Qualcomm
        0x19D2, // ZTE
        0x0BB4, // HTC
        0x2B4C, // Nothing
        0x1949, // Lab126
    };
    for (size_t i = 0; i < sizeof(vendors) / sizeof(vendors[0]); i++) {
        if (vendors[i] == vid) return YES;
    }
    return NO;
}

static UInt32 numberProp(io_service_t s, CFStringRef key) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    UInt32 out = 0;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberSInt32Type, &out);
    if (v) CFRelease(v);
    return out;
}

static NSString *stringProp(io_service_t s, CFStringRef key) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, key, kCFAllocatorDefault, 0);
    if (!v) return nil;
    if (CFGetTypeID(v) != CFStringGetTypeID()) { CFRelease(v); return nil; }
    return CFBridgingRelease(v);
}

static IOUSBDeviceInterface650 **openDevice(io_service_t s) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(s, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score) != KERN_SUCCESS || !plugin) {
        return NULL;
    }
    IOUSBDeviceInterface650 **dev = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID650), (LPVOID *)&dev);
    IODestroyPlugInInterface(plugin);
    return dev;
}

static IOUSBInterfaceInterface700 **openInterface(io_service_t s) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(s, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score) != KERN_SUCCESS || !plugin) {
        return NULL;
    }
    IOUSBInterfaceInterface700 **intf = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID700), (LPVOID *)&intf);
    IODestroyPlugInInterface(plugin);
    return intf;
}

static IOReturn controlRequest(IOUSBDeviceInterface650 **dev, UInt8 dirIn, UInt8 request, UInt16 index, void *data, UInt16 length) {
    IOUSBDevRequestTO r = {0};
    r.bmRequestType = USBmakebmRequestType(dirIn ? kUSBIn : kUSBOut, kUSBVendor, kUSBDevice);
    r.bRequest = request;
    r.wValue = 0;
    r.wIndex = index;
    r.wLength = length;
    r.pData = data;
    r.noDataTimeout = 1000;
    r.completionTimeout = 1500;
    // DeviceRequest does not require the device to be opened.
    return (*dev)->DeviceRequestTO(dev, &r);
}

/// Ask the phone to re-enumerate in accessory mode. Returns YES if the phone accepted.
static BOOL switchToAccessory(io_service_t s) {
    IOUSBDeviceInterface650 **dev = openDevice(s);
    if (!dev) return NO;
    BOOL ok = NO;
    UInt8 proto[2] = {0, 0};
    if (controlRequest(dev, 1, kAOAGetProtocol, 0, proto, 2) == kIOReturnSuccess) {
        UInt16 version = (UInt16)(proto[0] | (proto[1] << 8));
        if (version >= 1) {
            NSArray<NSString *> *strings = @[kAccManufacturer, kAccModel, kAccDescription, kAccVersion, kAccURI, kAccSerial];
            ok = YES;
            for (UInt16 i = 0; i < strings.count && ok; i++) {
                const char *str = strings[i].UTF8String;
                ok = controlRequest(dev, 0, kAOASendString, i, (void *)str, (UInt16)(strlen(str) + 1)) == kIOReturnSuccess;
            }
            if (ok) ok = controlRequest(dev, 0, kAOAStart, 0, NULL, 0) == kIOReturnSuccess;
        }
    }
    (*dev)->Release(dev);
    return ok;
}

// =====================================================================

@implementation EDAccessoryConnection {
    IOUSBDeviceInterface650 **_dev;
    IOUSBInterfaceInterface700 **_intf;
    UInt8 _inPipe;
    UInt8 _outPipe;
    UInt16 _outMaxPacket;
    dispatch_queue_t _writeQueue;
    BOOL _closed;
    BOOL _notified;
    NSLock *_lock;
}

- (nullable instancetype)initWithService:(io_service_t)service {
    self = [super init];
    if (!self) return nil;
    _lock = [NSLock new];
    _writeQueue = dispatch_queue_create("expanddisplay.usb.write", DISPATCH_QUEUE_SERIAL);
    _deviceName = stringProp(service, CFSTR("USB Product Name"))
        ?: stringProp(service, CFSTR(kUSBProductString)) ?: @"Android (USB)";

    _dev = openDevice(service);
    if (!_dev) return nil;

    // The interface may take a moment to appear after re-enumeration.
    for (int attempt = 0; attempt < 20 && !_intf; attempt++) {
        [self findInterface];
        if (!_intf) {
            if (attempt == 3) [self configureDevice];
            usleep(100 * 1000);
        }
    }
    if (!_intf) {
        (*_dev)->Release(_dev);
        _dev = NULL;
        return nil;
    }
    return self;
}

- (void)configureDevice {
    if ((*_dev)->USBDeviceOpen(_dev) != kIOReturnSuccess) return;
    IOUSBConfigurationDescriptorPtr cfg = NULL;
    if ((*_dev)->GetConfigurationDescriptorPtr(_dev, 0, &cfg) == kIOReturnSuccess && cfg) {
        (*_dev)->SetConfiguration(_dev, cfg->bConfigurationValue);
    }
    (*_dev)->USBDeviceClose(_dev);
}

- (void)findInterface {
    IOUSBFindInterfaceRequest req;
    req.bInterfaceClass = kIOUSBFindInterfaceDontCare;
    req.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    req.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    req.bAlternateSetting = kIOUSBFindInterfaceDontCare;
    io_iterator_t it = 0;
    if ((*_dev)->CreateInterfaceIterator(_dev, &req, &it) != kIOReturnSuccess) return;

    io_service_t s;
    while (!_intf && (s = IOIteratorNext(it))) {
        IOUSBInterfaceInterface700 **intf = openInterface(s);
        IOObjectRelease(s);
        if (!intf) continue;
        UInt8 cls = 0, sub = 0;
        (*intf)->GetInterfaceClass(intf, &cls);
        (*intf)->GetInterfaceSubClass(intf, &sub);
        // Accessory interface: vendor class 0xFF; skip the ADB interface (subclass 0x42).
        if (cls != 0xFF || sub == 0x42) { (*intf)->Release(intf); continue; }

        IOReturn kr = (*intf)->USBInterfaceOpen(intf);
        if (kr != kIOReturnSuccess) kr = (*intf)->USBInterfaceOpenSeize(intf);
        if (kr != kIOReturnSuccess) { (*intf)->Release(intf); continue; }

        UInt8 n = 0;
        (*intf)->GetNumEndpoints(intf, &n);
        UInt8 inPipe = 0, outPipe = 0;
        UInt16 outMax = 512;
        for (UInt8 p = 1; p <= n; p++) {
            UInt8 dir, num, type, interval;
            UInt16 maxPacket;
            if ((*intf)->GetPipeProperties(intf, p, &dir, &num, &type, &maxPacket, &interval) != kIOReturnSuccess) continue;
            if (type != kUSBBulk) continue;
            if (dir == kUSBIn && !inPipe) inPipe = p;
            if (dir == kUSBOut && !outPipe) { outPipe = p; outMax = maxPacket; }
        }
        if (inPipe && outPipe) {
            _intf = intf;
            _inPipe = inPipe;
            _outPipe = outPipe;
            _outMaxPacket = outMax ?: 512;
        } else {
            (*intf)->USBInterfaceClose(intf);
            (*intf)->Release(intf);
        }
    }
    IOObjectRelease(it);
}

- (void)startReading {
    [NSThread detachNewThreadWithBlock:^{
        [NSThread currentThread].qualityOfService = NSQualityOfServiceUserInteractive;
        const UInt32 cap = 64 * 1024;
        uint8_t *buf = malloc(cap);
        while (!self->_closed) {
            UInt32 size = cap;
            IOReturn kr = (*self->_intf)->ReadPipe(self->_intf, self->_inPipe, buf, &size);
            if (kr == kIOUSBPipeStalled) {
                (*self->_intf)->ClearPipeStallBothEnds(self->_intf, self->_inPipe);
                continue;
            }
            if (kr != kIOReturnSuccess) break;
            if (size > 0 && self.onData) self.onData([NSData dataWithBytes:buf length:size]);
        }
        free(buf);
        [self close];
        // Tear down on the write queue so no write can be using the interface concurrently.
        dispatch_sync(self->_writeQueue, ^{ [self releaseInterface]; });
        [self notifyClosed];
    }];
}

- (void)write:(NSData *)data completion:(void (^)(BOOL))completion {
    dispatch_async(_writeQueue, ^{
        BOOL ok = !self->_closed && self->_intf;
        const uint8_t *p = data.bytes;
        NSUInteger left = data.length;
        while (ok && left > 0) {
            UInt32 n = (UInt32)MIN(left, (NSUInteger)(256 * 1024));
            IOReturn kr = (*self->_intf)->WritePipeTO(self->_intf, self->_outPipe, (void *)p, n, 2000, 5000);
            ok = (kr == kIOReturnSuccess);
            p += n;
            left -= n;
        }
        // A transfer that ends exactly on a packet boundary needs a zero-length packet,
        // otherwise the phone's read waits for more data (adds a frame of latency).
        if (ok && data.length > 0 && data.length % self->_outMaxPacket == 0) {
            (*self->_intf)->WritePipeTO(self->_intf, self->_outPipe, (void *)p, 0, 1000, 1000);
        }
        if (!ok) [self close];
        if (completion) completion(ok);
    });
}

- (void)close {
    [_lock lock];
    BOOL wasClosed = _closed;
    _closed = YES;
    [_lock unlock];
    if (wasClosed || !_intf) return;
    (*_intf)->AbortPipe(_intf, _inPipe);
    (*_intf)->AbortPipe(_intf, _outPipe);
}

- (void)releaseInterface {
    [_lock lock];
    if (_intf) {
        (*_intf)->USBInterfaceClose(_intf);
        (*_intf)->Release(_intf);
        _intf = NULL;
    }
    if (_dev) {
        (*_dev)->Release(_dev);
        _dev = NULL;
    }
    [_lock unlock];
}

- (void)notifyClosed {
    [_lock lock];
    BOOL already = _notified;
    _notified = YES;
    [_lock unlock];
    if (!already && self.onClose) self.onClose();
}

@end

// =====================================================================

@implementation EDAccessoryManager {
    IONotificationPortRef _port;
    io_iterator_t _addedIter;
    dispatch_queue_t _work;
}

static void devicesAdded(void *ref, io_iterator_t it) {
    EDAccessoryManager *self = (__bridge EDAccessoryManager *)ref;
    io_service_t s;
    while ((s = IOIteratorNext(it))) {
        [self handleDevice:s];
        IOObjectRelease(s);
    }
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _enabled = YES;
        _work = dispatch_queue_create("expanddisplay.usb.manager", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)start {
    if (_port) return;
    _port = IONotificationPortCreate(kIOMainPortDefault);
    IONotificationPortSetDispatchQueue(_port, dispatch_get_main_queue());
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostDevice");
    if (IOServiceAddMatchingNotification(_port, kIOFirstMatchNotification, match, devicesAdded,
                                         (__bridge void *)self, &_addedIter) == KERN_SUCCESS) {
        devicesAdded((__bridge void *)self, _addedIter); // arm + handle already-connected devices
    }
    [self status:@"USB: 케이블 대기 중"];
}

- (void)stop {
    if (_addedIter) { IOObjectRelease(_addedIter); _addedIter = 0; }
    if (_port) { IONotificationPortDestroy(_port); _port = NULL; }
}

- (void)status:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.onStatus) self.onStatus(s); });
}

- (void)handleDevice:(io_service_t)s {
    if (!_enabled) return;
    UInt16 vid = (UInt16)numberProp(s, CFSTR("idVendor"));
    UInt16 pid = (UInt16)numberProp(s, CFSTR("idProduct"));

    if (vid == kAOAVendorGoogle && isAccessoryPID(pid)) {
        IOObjectRetain(s);
        dispatch_async(_work, ^{
            EDAccessoryConnection *c = [[EDAccessoryConnection alloc] initWithService:s];
            IOObjectRelease(s);
            if (!c) {
                [self status:@"USB: 액세서리 인터페이스를 열지 못했습니다"];
                return;
            }
            [self status:@"USB: 연결됨 (폰에서 앱을 열어 주세요)"];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.onAccessory) self.onAccessory(c);
            });
        });
        return;
    }

    if (!isAndroidVendor(vid)) return;
    IOObjectRetain(s);
    dispatch_async(_work, ^{
        BOOL ok = switchToAccessory(s);
        IOObjectRelease(s);
        [self status:ok ? @"USB: 폰을 액세서리 모드로 전환 중…" : @"USB: 이 기기는 액세서리 모드를 지원하지 않습니다"];
    });
}

@end
