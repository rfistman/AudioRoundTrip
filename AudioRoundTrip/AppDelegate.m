//
//  AppDelegate.m
//  AudioRoundTrip
//
//  Created by Gordon Childs on 10/8/18.
//  Copyright © 2018 Gordon Childs. All rights reserved.
//

#import "AppDelegate.h"
#import <AVFoundation/AVFoundation.h>
#include <AudioUnit/AudioUnit.h>
#include <mach/mach.h>
#import "AccelerateCorrelate.h"
#import "LameRingBuffer.h"
#import "impulse.h"

@interface AppDelegate ()

@end

static AudioUnit setupRemoteIOAudioUnit(void);

extern const uint64_t kBeatDurationHostTime;

const int kBufferSizeInSamples = 4096;

AudioUnit audioUnit;
AudioStreamBasicDescription inputASBD;

float *ping;
int pingPlaybackPosition;
int pingLengthFrames;


float *leftOutput;
float *rightOutput;
int outputWritePosition;
int outputLengthFrames;
AudioBufferList *outputABL;

int fileSizeInFrames;
float *fftedInput;
float *ringBufferFFTed;
float *correlationResult;

uint64_t inputAUStartHostTime;
double sampleRate;


AccCorrelate correlator;

UInt64 hostTimeZero = 0;
UInt64 playbackStartHostTime = 0;

@implementation AppDelegate

- (void)setupAudioSession {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    
    NSError *error;
    
    // interesting - default to speaker raising output latency.
    BOOL success = [session setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker error:&error];
    assert(success);
    
    if (false) {
        success = [session setMode:AVAudioSessionModeMeasurement error:&error];
        assert(success);
    }
    
    success = [session setActive:YES error:&error];
    assert(success);
    
    if (false) {
        success = [session setPreferredSampleRate:48000 error:&error];
        assert(success);
    }
    
    success = [session setPreferredIOBufferDuration:kBufferSizeInSamples/session.sampleRate error:&error];
    assert(success);
    
    NSLog(@"session sampleRate: %lf, preferred: %lf", session.sampleRate, session.preferredSampleRate);
    
    NSTimeInterval deviceLatency = session.outputLatency;
    NSTimeInterval inputLatency = session.inputLatency;
    NSTimeInterval bufferDur = session.IOBufferDuration;
    
    NSLog(@"latencies: %lf, if: %lf, bd: %lf (%lf samples)", deviceLatency, inputLatency, bufferDur, bufferDur * session.sampleRate);
    NSTimeInterval roundTripDuration = inputLatency + deviceLatency + bufferDur * 2;
    NSLog(@"round trip: %lfs, %lf, hosttime units: %lf, sr: %lf", roundTripDuration, roundTripDuration*session.sampleRate, roundTripDuration*1e9*3/125, session.sampleRate);

}

- (AVAudioPCMBuffer *)loadClick {
    NSURL *url = [[NSBundle mainBundle] URLForResource:@"Click" withExtension:@"wav"];
    NSError *error;
    // defaults to de-interleaved floating point, which is fine. expecting mono.
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:&error];
    assert(file);
    
    AVAudioFramePosition length = file.length;
    NSLog(@"Click length: %lli", length);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:(AVAudioFrameCount)length];
    BOOL success = [file readIntoBuffer:buffer error:&error];
    assert(success);
    
    double desiredSampleRate = [AVAudioSession sharedInstance].sampleRate;
    
    if (desiredSampleRate != file.processingFormat.sampleRate) {
        NSLog(@"Rate converting %f -> %f", file.processingFormat.sampleRate, desiredSampleRate);
        AVAudioFormat *desiredFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:desiredSampleRate channels:1];
        AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:file.processingFormat toFormat:desiredFormat];

        AVAudioFrameCount resampledLength = file.length*desiredSampleRate/file.processingFormat.sampleRate;
        AVAudioPCMBuffer *resampledBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:desiredFormat frameCapacity:resampledLength];

        __block BOOL haveVendedBuffer = NO;
        
        [converter convertToBuffer:resampledBuffer error:&error withInputFromBlock:^AVAudioBuffer*(AVAudioPacketCount inNumberOfPackets, AVAudioConverterInputStatus * outStatus) {
            if (haveVendedBuffer) {
                *outStatus = AVAudioConverterInputStatus_EndOfStream;
                return nil;
            } else {
                haveVendedBuffer = YES;
                *outStatus = AVAudioConverterInputStatus_HaveData;
                return buffer;
            }
        }];

        return resampledBuffer;
    }
    
    
    return buffer;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    ExampleCorrelate();
    ExampleCorrelate2();
    ExampleCorrelate3();

    [self setupAudioSession];
    
    AVAudioPCMBuffer *inputMatchBuffer = [self loadClick];
    int fileLength = inputMatchBuffer.frameLength;
    
    int lengthNPOT = 1 << (int)ceil(log2(2 * fileLength));  // NB: twice length of input
    float *fftedSamples = malloc(lengthNPOT * sizeof(float));
    assert(fftedSamples);
    correlator = NewAccCorr(lengthNPOT);

    // Don't dirtily do in place operations on floatChannelData[0], things go bad.
    float *inputMatchBufferSamples = calloc(1, lengthNPOT * sizeof(float));
    memcpy(inputMatchBufferSamples, inputMatchBuffer.floatChannelData[0], fileLength * sizeof(float));

    // normalize the vector first
    float l2Length = cblas_snrm2(fileLength, inputMatchBufferSamples, 1);
    cblas_sscal(fileLength, 1.0/l2Length, inputMatchBufferSamples, 1);
    NSLog(@"click l2 length = %f", l2Length);
    // NSLog(@"unitary check: %f", cblas_snrm2(fileLength, inputMatchBufferSamples, 1));

    ForwardFFT(&correlator, inputMatchBufferSamples, fftedSamples);    // vDSP real fft fwd scales by 2
    fileSizeInFrames = fileLength;
    fftedInput = fftedSamples;
    ringBufferFFTed = calloc(1, lengthNPOT * sizeof(float));
    assert(ringBufferFFTed);
    correlationResult = malloc(lengthNPOT*sizeof(float));
    assert(correlationResult);
    free(inputMatchBufferSamples);
    
    initLameRingBuffer(lengthNPOT + kBufferSizeInSamples);

    audioUnit = setupRemoteIOAudioUnit();

    OSStatus err;
    
    // seems dev is stereo float non interleaved, sim is packed signed int
    UInt32  size = sizeof(inputASBD);
    err = AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &inputASBD, &size);
    assert(noErr == err);

    AVAudioSession *session = [AVAudioSession sharedInstance];

    sampleRate = session.sampleRate;
    
    // create ping
    pingLengthFrames = num_samples_for_sample_rate(sampleRate);
    ping = malloc(sizeof(float) * pingLengthFrames);
    assert(ping);

    create_impulses(sampleRate, ping);
    
    outputLengthFrames = 1 * sampleRate;
    outputLengthFrames = (outputLengthFrames + kBufferSizeInSamples - 1)/kBufferSizeInSamples*kBufferSizeInSamples; // be divisible by buffer size
    leftOutput = malloc(sizeof(float) * outputLengthFrames);
    rightOutput = malloc(sizeof(float) * outputLengthFrames);
    outputABL = malloc(sizeof(AudioBufferList) + sizeof(AudioBuffer));  // give it two audio buffers for stereo non interleaved
    
    err = AudioUnitInitialize(audioUnit);
    assert(noErr == err);
    
    err = AudioOutputUnitStart(audioUnit);
    assert(noErr == err);
    
    return YES;
}

static OSStatus
InputCallback(
    void*                       inRefCon,
    AudioUnitRenderActionFlags* ioActionFlags,
    const AudioTimeStamp*       inTimeStamp,
    UInt32                      inBusNumber,
    UInt32                      inNumberFrames,
    AudioBufferList*            ioData)
{
    // uint64_t nowHostTime = mach_absolute_time();
    // printf("input hostTS: %lli, sampleTS: %lf, mach: %lli, %lf\n", inTimeStamp->mHostTime, inTimeStamp->mSampleTime, nowHostTime, audioSessionSampleRate * (nowHostTime-inTimeStamp->mHostTime)*125/3/1e9);
    if (false && outputWritePosition + inNumberFrames > outputLengthFrames) {
        printf("finished!\n");
        OSStatus err = AudioOutputUnitStop(audioUnit);
        assert(noErr == err);
        writeOutputToFile();
        return noErr;
    }
    
#if 0
    AudioBuffer        leftBuffer = {
        .mNumberChannels = 1,
        .mDataByteSize = (outputLengthFrames-outputWritePosition)*sizeof(leftOutput[0]),
        .mData = &leftOutput[outputWritePosition],
    };

    AudioBuffer        rightBuffer = {
        .mNumberChannels = 1,
        .mDataByteSize = (outputLengthFrames-outputWritePosition)*sizeof(rightOutput[0]),
        .mData = &rightOutput[outputWritePosition],
    };
#else
    // now writing to ring buffer, just give me what you've got
    AudioBuffer leftBuffer = {0};
    AudioBuffer rightBuffer = {0};
#endif
    
    outputABL->mNumberBuffers = 2;
    outputABL->mBuffers[0] = leftBuffer;
    outputABL->mBuffers[1] = rightBuffer;

    OSStatus err = AudioUnitRender(audioUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, outputABL);
    assert(noErr == err);   // maybe you're running this on the simulator

    if (0 == inputAUStartHostTime) {
        assert(inTimeStamp->mFlags & kAudioTimeStampHostTimeValid);
        inputAUStartHostTime = inTimeStamp->mHostTime;
        printf("Set in au starthosttime: %lli\n", inputAUStartHostTime);
    }
    
    // Do all ring buffer stuff from here because I haven't done any synchronization
    ringBufferWrite(outputABL->mBuffers[0].mData, inNumberFrames);

    // BUG: ring buffer sample time doesn't match inTimeStamp. nah. but I noted start hosttime.
    
    const int kNumValidDotProducts = (int)correlator.N-fileSizeInFrames+1;
    
    while (ringBufferAvailableFrames() >= correlator.N) {
        float *ringBufferSamples = ringBufferGetReadPointer();
        ForwardFFT(&correlator, ringBufferSamples, ringBufferFFTed);   // factor of 2
        Corrip(&correlator, fftedInput, ringBufferFFTed, correlationResult);    // doesn't like reusing arg as result, overwrites b
        
        float micDataLength = cblas_snrm2(fileSizeInFrames, ringBufferSamples, 1);
        double micDataLengthSquared = micDataLength*micDataLength;
        // printf("micDataLen: %f\n", micDataLength);
        
        for (int i = 0; i < kNumValidDotProducts; i++) {
            float dot = correlationResult[i];
            // printf("len %f, dot: %f\n", sqrt(micDataLengthSquared), dot);
    
            // 10%->1% on 5s. this strength reduction is a pretty good optimisation!
            float cosTheta = dot/(sqrt(micDataLengthSquared)*4*correlator.N);
//            float cosTheta = dot/(cblas_snrm2(fileSizeInFrames, ringBufferSamples+i, 1)*4*correlator.N);

            if (fabs(cosTheta) > 0.75) {
                uint64_t matchSampleTime = ringBufferStartSampleTime()+i;
                printf("%lli\t%f\n", matchSampleTime, cosTheta);
                if (hostTimeZero == 0) {
                    uint64_t hosttimeOffsetToMatch = matchSampleTime/sampleRate*1e9*3/125;  // rounding up?
                    hostTimeZero = inputAUStartHostTime + hosttimeOffsetToMatch;

                    printf("Setting hostTimeZero to %lli\n", hostTimeZero);
                    
                    uint64_t fudgeLagHostTime = 800.0/44100*1e9*3/125;  // our output seems to be 800ish samples late at 44.1kHz?
                    
                    playbackStartHostTime = hostTimeZero + 4*kBeatDurationHostTime - fudgeLagHostTime;
                    printf("Setting playbackStartHostTime to %lli\n", playbackStartHostTime);
                    
                    pingPlaybackPosition = 0;   // for reset. racy?
                }
            }
            
            double x0 = ringBufferSamples[i];
            double xn = ringBufferSamples[i + fileSizeInFrames];
            
            micDataLengthSquared += xn*xn - x0*x0;
        }
        
        ringBufferAdvanceReadPointer(kNumValidDotProducts);
    }
    
    outputWritePosition += inNumberFrames;
    
    return noErr;
}

static OSStatus
RenderCallback(
   void*                       inRefCon,
   AudioUnitRenderActionFlags* ioActionFlags,
   const AudioTimeStamp*       inTimeStamp,
   UInt32                      inBusNumber,
   UInt32                      inNumberFrames,
   AudioBufferList*            ioData)
{
    uint64_t    bufferEndHostTime = inTimeStamp->mHostTime + (inNumberFrames/sampleRate*1e9*3/125);
    int availFrames = pingLengthFrames - pingPlaybackPosition;

    if (0 == availFrames) {
        *ioActionFlags = kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }
    
    if (0 == pingPlaybackPosition && !(inTimeStamp->mHostTime <= playbackStartHostTime && playbackStartHostTime < bufferEndHostTime)) {
        *ioActionFlags = kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }

    int framesToPreTrim = 0;
    
    if (0 == pingPlaybackPosition) {
        // TODO: calculate position in first buffer
        uint64_t    hostTimeOffset = playbackStartHostTime - inTimeStamp->mHostTime;
        framesToPreTrim = hostTimeOffset * 125 / 3 / 1e9 * sampleRate;  // TODO: round up? probably should.

        printf("pre-trimming %i frames\n", framesToPreTrim);
        inNumberFrames -= framesToPreTrim;
    }

    // uint64_t nowHostTime = mach_absolute_time();
    // NB: assumption that timestamp hosttime > now hosttime
    // printf("output hostTS: %lli, sampleTS: %lf, mach: %lli, %lf\n", inTimeStamp->mHostTime, inTimeStamp->mSampleTime, nowHostTime, -audioSessionSampleRate * (inTimeStamp->mHostTime-nowHostTime)*125/3/1e9);
    int framesToCopy = MIN(availFrames, inNumberFrames);

    // assuming interleaved here
    for (int i = 0; i < ioData->mNumberBuffers; i++) {
        AudioBuffer *buffer = &ioData->mBuffers[i];
        bzero(buffer->mData, buffer->mDataByteSize);    // zero everything, handles trailing and leading trimming
        memcpy(buffer->mData + framesToPreTrim*sizeof(float), &ping[pingPlaybackPosition], sizeof(ping[0]) * framesToCopy);
    }
    
    pingPlaybackPosition += framesToCopy;
    
    return noErr;
}

static AudioUnit
setupRemoteIOAudioUnit() {
    AudioComponentDescription desc = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_RemoteIO,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };
    
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    assert(comp);
    
    AudioUnit au;
    OSStatus err = AudioComponentInstanceNew(comp, &au);
    assert(noErr == err);
    
    // enable input
    UInt32        flag = 1;
    err = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &flag, sizeof(flag));
    assert(noErr == err);

    AURenderCallbackStruct cb;
    cb.inputProc = InputCallback;
    cb.inputProcRefCon = NULL;
    err = AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &cb, sizeof(cb));
    assert(noErr == err);

    cb.inputProc = RenderCallback;
    cb.inputProcRefCon = NULL;
    err = AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    assert(noErr == err);
    
    return au;
}

static void
writeOutputToFile() {
    double sampleRate = [AVAudioSession sharedInstance].sampleRate;
    
    NSData *left = [NSData dataWithBytes:leftOutput length:outputLengthFrames*sizeof(leftOutput[0])];
    NSData *right = [NSData dataWithBytes:rightOutput length:outputLengthFrames*sizeof(rightOutput[0])];

    NSError *error;
    NSURL *folder = [[NSFileManager defaultManager] URLForDirectory:NSDocumentDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:true error:&error];

    NSURL *fileURL;
    BOOL success;

    fileURL = [folder URLByAppendingPathComponent:[NSString stringWithFormat:@"left-%lf.raw", sampleRate]];
    success = [left writeToURL:fileURL options:NSDataWritingAtomic error:&error];
    assert(success);

    fileURL = [folder URLByAppendingPathComponent:[NSString stringWithFormat:@"right-%lf.raw", sampleRate]];
    success = [right writeToURL:fileURL options:NSDataWritingAtomic error:&error];
    assert(success);
}

@end
