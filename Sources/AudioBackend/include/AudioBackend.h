#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

@interface AVAudioProcess : NSObject
@property(nonatomic, readonly) pid_t pid;
@property(nonatomic, readonly) AudioObjectID objectID;
@property(nonatomic, readonly) BOOL runningOutput;
@property(nonatomic, readonly) BOOL usesDefaultOutput;
@property(nonatomic, readonly, nullable) NSString *bundleID;
@end

@interface AVSystemAudio : NSObject
+ (AudioObjectID)defaultOutputID;
+ (nullable NSString *)defaultOutputName;
+ (nullable NSString *)defaultOutputUID;
+ (NSArray<AVAudioProcess *> *)outputProcesses;
@end

@interface AVTapSession : NSObject
@property(nonatomic, readonly) BOOL active;
@property(nonatomic, readonly) BOOL faulted;
@property(nonatomic, readonly) uint64_t nonzeroFrameCount;
@property(nonatomic, readonly) uint64_t callbackCount;
- (instancetype)initWithProcessObjectIDs:(NSArray<NSNumber *> *)processIDs
                             outputDevice:(AudioObjectID)outputDevice
                                     gain:(float)gain;
- (BOOL)start:(NSError * _Nullable * _Nullable)error;
- (void)setGain:(float)gain;
- (void)stop;
@end

float AVClampedGain(float gain);
float AVGainRampStep(float current, float target, unsigned int remaining);

NS_ASSUME_NONNULL_END
