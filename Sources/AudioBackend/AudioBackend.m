#import "AudioBackend.h"
#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <stdatomic.h>
#import <math.h>

_Static_assert(ATOMIC_LONG_LOCK_FREE == 2, "64-bit callback counters must be lock-free");

static AudioObjectPropertyAddress Address(AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress){selector, scope, kAudioObjectPropertyElementMain};
}

static BOOL ReadProperty(AudioObjectID object, AudioObjectPropertySelector selector,
                         AudioObjectPropertyScope scope, void *value, UInt32 size) {
    AudioObjectPropertyAddress address = Address(selector, scope);
    return AudioObjectGetPropertyData(object, &address, 0, NULL, &size, value) == noErr;
}

static NSArray<NSNumber *> *ObjectList(AudioObjectID object, AudioObjectPropertySelector selector,
                                       AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = Address(selector, scope);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(object, &address, 0, NULL, &size) != noErr ||
        size == 0 || size % sizeof(AudioObjectID) != 0) return @[];
    AudioObjectID *ids = calloc(size / sizeof(AudioObjectID), sizeof(AudioObjectID));
    if (!ids) return @[];
    OSStatus status = AudioObjectGetPropertyData(object, &address, 0, NULL, &size, ids);
    NSMutableArray<NSNumber *> *result = [NSMutableArray array];
    if (status == noErr) for (NSUInteger i = 0; i < size / sizeof(AudioObjectID); i++) [result addObject:@(ids[i])];
    free(ids);
    return result;
}

@interface AVAudioProcess ()
@property(nonatomic) pid_t pid;
@property(nonatomic) AudioObjectID objectID;
@property(nonatomic) BOOL runningOutput;
@property(nonatomic) BOOL usesDefaultOutput;
@property(nonatomic, copy, nullable) NSString *bundleID;
@end
@implementation AVAudioProcess
@end

@implementation AVSystemAudio
+ (AudioObjectID)defaultOutputID {
    AudioObjectID device = kAudioObjectUnknown;
    ReadProperty(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice,
                 kAudioObjectPropertyScopeGlobal, &device, sizeof(device));
    return device;
}
+ (nullable NSString *)defaultOutputName {
    AudioObjectID device = self.defaultOutputID;
    if (device == kAudioObjectUnknown) return nil;
    CFStringRef name = NULL;
    if (!ReadProperty(device, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, &name, sizeof(name))) return nil;
    return CFBridgingRelease(name);
}
+ (nullable NSString *)defaultOutputUID {
    AudioObjectID device = self.defaultOutputID;
    if (device == kAudioObjectUnknown) return nil;
    CFStringRef uid = NULL;
    if (!ReadProperty(device, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, &uid, sizeof(uid))) return nil;
    return CFBridgingRelease(uid);
}
+ (NSArray<AVAudioProcess *> *)outputProcesses {
    AudioObjectID output = self.defaultOutputID;
    NSMutableArray<AVAudioProcess *> *result = [NSMutableArray array];
    for (NSNumber *number in ObjectList(kAudioObjectSystemObject, kAudioHardwarePropertyProcessObjectList,
                                        kAudioObjectPropertyScopeGlobal)) {
        AudioObjectID object = number.unsignedIntValue;
        pid_t pid = 0;
        UInt32 active = 0;
        if (!ReadProperty(object, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, &pid, sizeof(pid)) ||
            !ReadProperty(object, kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal, &active, sizeof(active)) ||
            pid <= 0 || active == 0 || pid == getpid()) continue;
        NSArray<NSNumber *> *devices = ObjectList(object, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput);
        BOOL defaultRoute = [devices containsObject:@(output)];
        CFStringRef bundleID = NULL;
        ReadProperty(object, kAudioProcessPropertyBundleID, kAudioObjectPropertyScopeGlobal, &bundleID, sizeof(bundleID));
        AVAudioProcess *process = [AVAudioProcess new];
        process.pid = pid;
        process.objectID = object;
        process.runningOutput = YES;
        process.usesDefaultOutput = defaultRoute;
        process.bundleID = CFBridgingRelease(bundleID);
        [result addObject:process];
    }
    return result;
}
@end

float AVClampedGain(float gain) { return isfinite(gain) ? fmaxf(0, fminf(1, gain)) : 1; }
float AVGainRampStep(float current, float target, unsigned int remaining) {
    return remaining ? current + (target - current) / (float)remaining : target;
}

@interface AVTapSession () {
@public
    AudioObjectID _tapID;
    AudioObjectID _aggregateID;
    AudioDeviceIOProcID _ioProcID;
    AudioObjectID _outputDevice;
    NSArray<NSNumber *> *_processIDs;
    _Atomic float _targetGain;
    float _currentGain;
    unsigned int _rampRemaining;
    unsigned int _rampFrames;
    _Atomic bool _faulted;
    _Atomic uint64_t _callbacks;
    _Atomic uint64_t _nonzeroFrames;
    BOOL _active;
}
@end

static OSStatus TapIOProc(AudioObjectID device, const AudioTimeStamp *now,
                          const AudioBufferList *input, const AudioTimeStamp *inputTime,
                          AudioBufferList *output, const AudioTimeStamp *outputTime, void *userData) {
    AVTapSession *session = (__bridge AVTapSession *)userData;
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    if (!output) return noErr;
    // The aggregate owns the physical output; clear every buffer before mixing this tap.
    for (UInt32 i = 0; i < output->mNumberBuffers; i++) {
        if (output->mBuffers[i].mData) memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
    }
    atomic_fetch_add_explicit(&session->_callbacks, 1, memory_order_relaxed);
    if (!input || input->mNumberBuffers == 0 || output->mNumberBuffers == 0) return noErr;

    // This first version accepts stereo Float32 as one interleaved or two planar buffers.
    BOOL inputInterleaved = input->mNumberBuffers == 1 && input->mBuffers[0].mNumberChannels == 2;
    BOOL inputPlanar = input->mNumberBuffers == 2 && input->mBuffers[0].mNumberChannels == 1 && input->mBuffers[1].mNumberChannels == 1;
    BOOL outputInterleaved = output->mNumberBuffers == 1 && output->mBuffers[0].mNumberChannels == 2;
    BOOL outputPlanar = output->mNumberBuffers == 2 && output->mBuffers[0].mNumberChannels == 1 && output->mBuffers[1].mNumberChannels == 1;
    if ((!inputInterleaved && !inputPlanar) || (!outputInterleaved && !outputPlanar)) {
        atomic_store_explicit(&session->_faulted, true, memory_order_relaxed);
        return noErr;
    }
    UInt32 inFrames = input->mBuffers[0].mDataByteSize / (inputInterleaved ? 8 : 4);
    UInt32 outFrames = output->mBuffers[0].mDataByteSize / (outputInterleaved ? 8 : 4);
    if (!input->mBuffers[0].mData || !output->mBuffers[0].mData || inFrames < outFrames ||
        (inputPlanar && (!input->mBuffers[1].mData || input->mBuffers[1].mDataByteSize < outFrames * 4)) ||
        (outputPlanar && (!output->mBuffers[1].mData || output->mBuffers[1].mDataByteSize < outFrames * 4))) {
        atomic_store_explicit(&session->_faulted, true, memory_order_relaxed);
        return noErr;
    }
    const float *in0 = input->mBuffers[0].mData;
    const float *in1 = inputPlanar ? input->mBuffers[1].mData : NULL;
    float *out0 = output->mBuffers[0].mData;
    float *out1 = outputPlanar ? output->mBuffers[1].mData : NULL;
    float target = atomic_load_explicit(&session->_targetGain, memory_order_relaxed);
    if (target != session->_currentGain && session->_rampRemaining == 0) session->_rampRemaining = session->_rampFrames;
    uint64_t nonzero = 0;
    for (UInt32 frame = 0; frame < outFrames; frame++) {
        if (session->_rampRemaining) {
            session->_currentGain = AVGainRampStep(session->_currentGain, target, session->_rampRemaining);
            session->_rampRemaining--;
        } else session->_currentGain = target;
        float left = inputInterleaved ? in0[frame * 2] : in0[frame];
        float right = inputInterleaved ? in0[frame * 2 + 1] : in1[frame];
        if (left != 0 || right != 0) nonzero++;
        if (outputInterleaved) { out0[frame * 2] = left * session->_currentGain; out0[frame * 2 + 1] = right * session->_currentGain; }
        else { out0[frame] = left * session->_currentGain; out1[frame] = right * session->_currentGain; }
    }
    atomic_fetch_add_explicit(&session->_nonzeroFrames, nonzero, memory_order_relaxed);
    return noErr;
}

@implementation AVTapSession
- (instancetype)initWithProcessObjectIDs:(NSArray<NSNumber *> *)processIDs outputDevice:(AudioObjectID)outputDevice gain:(float)gain {
    if ((self = [super init])) {
        _processIDs = [processIDs copy]; _outputDevice = outputDevice;
        _tapID = kAudioObjectUnknown; _aggregateID = kAudioObjectUnknown;
        _currentGain = AVClampedGain(gain);
        atomic_init(&_targetGain, _currentGain); atomic_init(&_faulted, false);
        atomic_init(&_callbacks, 0); atomic_init(&_nonzeroFrames, 0);
    }
    return self;
}
- (BOOL)active { return _active; }
- (BOOL)faulted { return atomic_load_explicit(&_faulted, memory_order_relaxed); }
- (uint64_t)nonzeroFrameCount { return atomic_load_explicit(&_nonzeroFrames, memory_order_relaxed); }
- (uint64_t)callbackCount { return atomic_load_explicit(&_callbacks, memory_order_relaxed); }
- (void)setGain:(float)gain { atomic_store_explicit(&_targetGain, AVClampedGain(gain), memory_order_relaxed); }

- (BOOL)start:(NSError **)error {
    if (_active) return YES;
    OSStatus status = noErr;
    NSString *stage = @"Creating the process tap";
    NSDictionary *aggregate = nil;
    CATapDescription *description = [[CATapDescription alloc] initStereoMixdownOfProcesses:_processIDs];
    description.name = @"AppVolume temporary tap";
    description.privateTap = YES;
    description.muteBehavior = CATapMutedWhenTapped;
    NSString *deviceUID = [AVSystemAudio defaultOutputUID];
    if (!atomic_is_lock_free(&_targetGain)) goto fail;
    if (!deviceUID || _outputDevice != [AVSystemAudio defaultOutputID]) goto fail;
    description.deviceUID = deviceUID;
    status = AudioHardwareCreateProcessTap(description, &_tapID);
    if (status != noErr) goto fail;

    stage = @"Reading tap format";
    AudioStreamBasicDescription tapFormat = {0};
    if (!ReadProperty(_tapID, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, &tapFormat, sizeof(tapFormat)) ||
        tapFormat.mFormatID != kAudioFormatLinearPCM || !(tapFormat.mFormatFlags & kAudioFormatFlagIsFloat) ||
        !(tapFormat.mFormatFlags & kAudioFormatFlagIsPacked) ||
        (tapFormat.mFormatFlags & kAudioFormatFlagIsBigEndian) ||
        tapFormat.mBitsPerChannel != 32 || tapFormat.mChannelsPerFrame != 2 || tapFormat.mSampleRate <= 0 ||
        tapFormat.mBytesPerFrame != ((tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 4 : 8)) goto fail;

    stage = @"Checking output device";
    // An input-bearing physical device introduces extra aggregate input buffers; bypass it safely.
    AudioObjectPropertyAddress inputAddress = Address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput);
    UInt32 inputBytes = 0;
    if (AudioObjectGetPropertyDataSize(_outputDevice, &inputAddress, 0, NULL, &inputBytes) != noErr) goto fail;
    AudioBufferList *physicalInputs = calloc(1, inputBytes);
    if (!physicalInputs) goto fail;
    status = AudioObjectGetPropertyData(_outputDevice, &inputAddress, 0, NULL, &inputBytes, physicalInputs);
    UInt32 physicalInputChannels = 0;
    if (status == noErr) for (UInt32 i = 0; i < physicalInputs->mNumberBuffers; i++) physicalInputChannels += physicalInputs->mBuffers[i].mNumberChannels;
    free(physicalInputs);
    if (status != noErr || physicalInputChannels != 0) goto fail;

    stage = @"Creating private aggregate device";
    aggregate = @{
        @kAudioAggregateDeviceUIDKey: [NSString stringWithFormat:@"com.ericchiu.AppVolume.%@", NSUUID.UUID.UUIDString],
        @kAudioAggregateDeviceNameKey: @"AppVolume temporary device",
        @kAudioAggregateDeviceIsPrivateKey: @YES,
        @kAudioAggregateDeviceSubDeviceListKey: @[@{@kAudioSubDeviceUIDKey: deviceUID}],
        @kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
        @kAudioAggregateDeviceTapListKey: @[@{@kAudioSubTapUIDKey: description.UUID.UUIDString,
                                             @kAudioSubTapDriftCompensationKey: @YES}]
    };
    status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregate, &_aggregateID);
    if (status != noErr) goto fail;
    stage = @"Checking aggregate format";
    AudioStreamBasicDescription outputFormat = {0};
    if (!ReadProperty(_aggregateID, kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeOutput, &outputFormat, sizeof(outputFormat)) ||
        outputFormat.mFormatID != kAudioFormatLinearPCM || !(outputFormat.mFormatFlags & kAudioFormatFlagIsFloat) ||
        !(outputFormat.mFormatFlags & kAudioFormatFlagIsPacked) ||
        (outputFormat.mFormatFlags & kAudioFormatFlagIsBigEndian) ||
        outputFormat.mBitsPerChannel != 32 || outputFormat.mChannelsPerFrame != 2 ||
        outputFormat.mBytesPerFrame != ((outputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 4 : 8) ||
        fabs(outputFormat.mSampleRate - tapFormat.mSampleRate) > 1) goto fail;
    _rampFrames = MAX(1, (unsigned int)(tapFormat.mSampleRate * 0.008));
    stage = @"Creating audio callback";
    status = AudioDeviceCreateIOProcID(_aggregateID, TapIOProc, (__bridge void *)self, &_ioProcID);
    if (status != noErr) goto fail;
    stage = @"Starting audio";
    status = AudioDeviceStart(_aggregateID, _ioProcID);
    if (status != noErr) goto fail;
    _active = YES;
    return YES;
fail:
    [self stop];
    if (error) *error = [NSError errorWithDomain:@"AppVolume.Audio" code:status ?: -1
                                        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ failed (%d). Original playback restored.", stage, (int)status]}];
    return NO;
}
- (void)stop {
    // AudioDeviceStop joins the running callback before its context may be released.
    if (_ioProcID) {
        AudioDeviceStop(_aggregateID, _ioProcID);
        AudioDeviceDestroyIOProcID(_aggregateID, _ioProcID);
        _ioProcID = NULL;
    }
    if (_aggregateID != kAudioObjectUnknown) {
        AudioHardwareDestroyAggregateDevice(_aggregateID);
        _aggregateID = kAudioObjectUnknown;
    }
    if (_tapID != kAudioObjectUnknown) {
        AudioHardwareDestroyProcessTap(_tapID);
        _tapID = kAudioObjectUnknown;
    }
    _active = NO;
}
- (void)dealloc { [self stop]; }
@end
