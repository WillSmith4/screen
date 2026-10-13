#import "ScrcpyVideoDecoder.h"
#import "annexb.h"
#import <stdatomic.h>
#import <QuartzCore/QuartzCore.h>

@implementation ScrcpyVideoDecoder {
    CMVideoCodecType _codec;
    BOOL _requireHardware, _waitingForKeyframe, _closed;
    VTDecompressionSessionRef _session;
    CMVideoFormatDescriptionRef _format;
    NSMutableDictionary<NSNumber *, NSData *> *_parameters;
    NSObject *_outputLock;
    void (^_output)(CVPixelBufferRef, int64_t, BOOL);
    void (^_recovery)(OSStatus);
    dispatch_semaphore_t _slots;
    _Atomic(bool) _needsReset;
    int64_t _lastOutputPTS;
    CFAbsoluteTime _lastErrorLog;
    uint64_t _packets;
    _Atomic(uint64_t) _outputs, _lateOutputs, _emptyOutputs;
    CFTimeInterval _metricsStart, _lastPacketTime, _maxPacketGap;
}

- (instancetype)initWithCodec:(CMVideoCodecType)codec requireHardware:(BOOL)requireHardware
                      output:(void (^)(CVPixelBufferRef, int64_t, BOOL))output
                    recovery:(void (^)(OSStatus))recovery {
    if ((self = [super init])) {
        _codec = codec;
        _requireHardware = requireHardware;
        _output = [output copy];
        _recovery = [recovery copy];
        _parameters = [NSMutableDictionary dictionary];
        _outputLock = [NSObject new];
        _slots = dispatch_semaphore_create(3);
        _waitingForKeyframe = YES;
        _lastOutputPTS = INT64_MIN;
        _metricsStart = CACurrentMediaTime();
    }
    return self;
}

- (void)reportFailure:(OSStatus)status {
    atomic_store(&_needsReset, true);
    @synchronized (_outputLock) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - _lastErrorLog >= 5) {
            NSLog(@"[NativeVideo] decode recovery, status=%d", (int)status);
            _lastErrorLog = now;
        }
    }
    if (_recovery) { _recovery(status); }
}

- (void)drain {
    if (_session) { VTDecompressionSessionWaitForAsynchronousFrames(_session); }
}

- (void)reset {
    [self drain];
    if (_session) {
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    _waitingForKeyframe = YES;
    _lastOutputPTS = INT64_MIN;
    atomic_store(&_needsReset, false);
}

- (void)close {
    [self reset];
    _closed = YES;
    if (_format) { CFRelease(_format); _format = NULL; }
    [_parameters removeAllObjects];
}

- (void)dealloc {
    // Owners close and drain before releasing the decoder.
    if (_session) { VTDecompressionSessionInvalidate(_session); CFRelease(_session); }
    if (_format) { CFRelease(_format); }
}

- (BOOL)updateFormat {
    BOOL hevc = _codec == kCMVideoCodecType_HEVC;
    NSArray<NSNumber *> *types = hevc ? @[@32, @33, @34] : @[@7, @8];
    const uint8_t *pointers[3];
    size_t sizes[3];
    for (NSUInteger i = 0; i < types.count; ++i) {
        NSData *value = _parameters[types[i]];
        if (!value.length) { return NO; }
        pointers[i] = value.bytes;
        sizes[i] = value.length;
    }
    CMVideoFormatDescriptionRef format = NULL;
    OSStatus status = hevc
        ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault,
            types.count, pointers, sizes, 4, NULL, &format)
        : CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
            types.count, pointers, sizes, 4, &format);
    if (status != noErr) {
        [self reset];
        if (_format) { CFRelease(_format); _format = NULL; }
        [self reportFailure:status];
        return NO;
    }
    if (_session && !VTDecompressionSessionCanAcceptFormatDescription(_session, format)) {
        [self reset];
    }
    if (_format) { CFRelease(_format); }
    _format = format;
    return YES;
}

- (BOOL)createSession {
    NSDictionary *specification = @{};
    if (_requireHardware) {
        if (@available(iOS 17.0, *)) {
            specification = @{(__bridge NSString *)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @YES};
        } else {
            [self reportFailure:kVTVideoDecoderUnsupportedDataFormatErr];
            return NO;
        }
    }
    // Let VideoToolbox choose native 8/10-bit and full/video range. All accepted
    // buffers have IOSurface backing; no CPU YUV conversion/upload is needed.
    NSDictionary *attributes = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @[
            @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            @(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
            @(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)],
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    OSStatus status = VTDecompressionSessionCreate(kCFAllocatorDefault, _format,
        (__bridge CFDictionaryRef)specification, (__bridge CFDictionaryRef)attributes,
        NULL, &_session);
    if (status != noErr) { [self reportFailure:status]; return NO; }
    OSStatus realtimeStatus = VTSessionSetProperty(_session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    CFTypeRef hardware = NULL;
    OSStatus hardwareStatus = kVTPropertyNotSupportedErr;
    if (@available(iOS 17.0, *)) {
        hardwareStatus = VTSessionCopyProperty(_session, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                              kCFAllocatorDefault, &hardware);
    }
    NSLog(@"[NativeVideo] %@ VideoToolbox directly, hardwareRequired=%d hardware=%@ propertyStatus=%d realtimeStatus=%d inFlight<=3",
          _codec == kCMVideoCodecType_HEVC ? @"HEVC" : @"H264", _requireHardware,
          (__bridge id)hardware ?: @"unknown", (int)hardwareStatus, (int)realtimeStatus);
    if (hardware) { CFRelease(hardware); }
    return YES;
}

- (void)recordPacketArrival {
    CFTimeInterval now = CACurrentMediaTime();
    if (_lastPacketTime) { _maxPacketGap = MAX(_maxPacketGap, now - _lastPacketTime); }
    _lastPacketTime = now;
    ++_packets;
    double seconds = now - _metricsStart;
    if (seconds < 5) { return; }
    uint64_t outputs = atomic_exchange(&_outputs, 0);
    uint64_t late = atomic_exchange(&_lateOutputs, 0), empty = atomic_exchange(&_emptyOutputs, 0);
    NSLog(@"[NativeVideoStats] packets=%.1f/s output=%.1f/s maxPacketGapMs=%.1f late=%llu empty=%llu",
          _packets / seconds, outputs / seconds, _maxPacketGap * 1000,
          (unsigned long long)late, (unsigned long long)empty);
    _packets = 0;
    _maxPacketGap = 0;
    _metricsStart = now;
}

- (BOOL)submitAnnexB:(const uint8_t *)data size:(size_t)size ptsUS:(int64_t)pts keyframe:(BOOL)keyframe {
    if (_closed || !data || !size || size > INT32_MAX) { return NO; }
    if (atomic_load(&_needsReset)) { [self reset]; }
    BOOL hevc = _codec == kCMVideoCodecType_HEVC;
    BOOL changed = NO, hasPicture = NO, found = NO;
    NSMutableData *payload = [NSMutableData dataWithCapacity:size];
    size_t cursor = 0;
    struct sc_nal nal;
    while (sc_annexb_next(data, size, &cursor, &nal)) {
        if (!nal.size || (hevc && nal.size < 2)) { [self reportFailure:kVTVideoDecoderBadDataErr]; return NO; }
        found = YES;
        unsigned type = hevc ? (nal.data[0] >> 1) & 63 : nal.data[0] & 31;
        BOOL parameter = hevc ? (type >= 32 && type <= 34) : (type == 7 || type == 8);
        if (parameter) {
            NSData *value = [NSData dataWithBytes:nal.data length:nal.size];
            if (![_parameters[@(type)] isEqualToData:value]) { _parameters[@(type)] = value; changed = YES; }
            continue;
        }
        hasPicture |= hevc ? type <= 31 : (type >= 1 && type <= 5);
        keyframe |= hevc ? (type >= 16 && type <= 23) : type == 5;
        uint32_t length = CFSwapInt32HostToBig((uint32_t)nal.size);
        [payload appendBytes:&length length:4];
        [payload appendBytes:nal.data length:nal.size];
    }
    if (!found) { [self reportFailure:kVTVideoDecoderBadDataErr]; return NO; }
    if ((changed || !_format) && ![self updateFormat]) {
        // Never decode a new configuration with the previous format.
        if (hasPicture && !atomic_load(&_needsReset)) { [self reportFailure:kVTVideoDecoderBadDataErr]; }
        return !hasPicture && !atomic_load(&_needsReset);
    }
    if (!hasPicture) { return YES; } // Standalone codec configuration.
    [self recordPacketArrival];
    if (!_format || (_waitingForKeyframe && !keyframe)) {
        if (_recovery) { _recovery(kVTVideoDecoderBadDataErr); }
        return YES;
    }
    if (!_session && ![self createSession]) { return NO; }
    // Bound hardware work without breaking reference-frame dependencies. A
    // timeout requests a fresh IDR before any further inter-frame submission.
    if (dispatch_semaphore_wait(_slots, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC))) {
        [self reportFailure:kVTVideoDecoderMalfunctionErr];
        return NO;
    }
    CMBlockBufferRef block = NULL;
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL,
        payload.length, kCFAllocatorDefault, NULL, 0, payload.length, 0, &block);
    if (status == noErr) { status = CMBlockBufferReplaceDataBytes(payload.bytes, block, 0, payload.length); }
    CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMake(pts, 1000000), kCMTimeInvalid};
    size_t sampleSize = payload.length;
    if (status == noErr) {
        status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, _format,
            1, 1, &timing, 1, &sampleSize, &sample);
    }
    if (status == noErr) {
        _waitingForKeyframe = NO;
        status = VTDecompressionSessionDecodeFrameWithOutputHandler(_session, sample,
            kVTDecodeFrame_EnableAsynchronousDecompression, NULL,
            ^(OSStatus error, VTDecodeInfoFlags flags, CVImageBufferRef image, CMTime presentation, CMTime duration) {
                @autoreleasepool {
                    if (error != noErr) {
                        [self reportFailure:error];
                    } else if (image) {
                        int64_t outputPTS = CMTimeConvertScale(presentation, 1000000, kCMTimeRoundingMethod_Default).value;
                        @synchronized (self->_outputLock) {
                            // Late callbacks never move the visible image backwards.
                            if (outputPTS >= self->_lastOutputPTS && !atomic_load(&self->_needsReset)) {
                                self->_lastOutputPTS = outputPTS;
                                self->_output(image, outputPTS, keyframe);
                                atomic_fetch_add(&self->_outputs, 1);
                            } else {
                                atomic_fetch_add(&self->_lateOutputs, 1);
                            }
                        }
                    } else {
                        atomic_fetch_add(&self->_emptyOutputs, 1);
                    }
                    dispatch_semaphore_signal(self->_slots);
                }
            });
    }
    if (sample) { CFRelease(sample); }
    if (block) { CFRelease(block); }
    if (status != noErr) {
        dispatch_semaphore_signal(_slots); // No callback is made on submission failure.
        [self reportFailure:status];
        return NO;
    }
    return YES;
}
@end
