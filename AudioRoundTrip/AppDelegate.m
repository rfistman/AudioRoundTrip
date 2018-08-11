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

@interface AppDelegate ()

@end

static AudioUnit setupRemoteIOAudioUnit();

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


@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // TODO: ogle measurement mode latencies

    AVAudioSession *session = [AVAudioSession sharedInstance];
    
    NSError *error;
    
    BOOL success = [session setCategory:AVAudioSessionCategoryPlayAndRecord error:&error];
    assert(success);
    
    success = [session setActive:YES error:&error];
    assert(success);

    if (false) {
        success = [session setPreferredSampleRate:48000 error:&error];
        assert(success);
    }
    
    // iPhone X has stereo input, I don't want to think about that.
//    success = [session setPreferredInputNumberOfChannels:1 error:&error];
//    assert(success);
//    NSLog(@"input channels: %i", session.inputNumberOfChannels);
    
    double sampleRate = session.sampleRate;
    
    success = [session setPreferredIOBufferDuration:kBufferSizeInSamples/sampleRate error:&error];
    assert(success);
    
    NSLog(@"session sampleRate: %lf, preferred: %lf", session.sampleRate, session.preferredSampleRate);
    
    NSTimeInterval deviceLatency = session.outputLatency;
    NSTimeInterval inputLatency = session.inputLatency;
    NSTimeInterval bufferDur = session.IOBufferDuration;
    
    NSLog(@"latencies: %lf, if: %lf, bd: %lf (%lf samples)", deviceLatency, inputLatency, bufferDur, bufferDur * session.sampleRate);
    NSTimeInterval roundTripDuration = inputLatency + deviceLatency + bufferDur * 2;
    NSLog(@"round trip: %lfs, %lf, sr: %lf", roundTripDuration, roundTripDuration*session.sampleRate, session.sampleRate);

    audioUnit = setupRemoteIOAudioUnit();

    OSStatus err;
    
    // seems dev is stereo float non interleaved, sim is packed signed int
    UInt32  size = sizeof(inputASBD);
    err = AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &inputASBD, &size);
    assert(noErr == err);

    // create ping
    pingLengthFrames = 0.04 * sampleRate;
    ping = malloc(sizeof(float) * pingLengthFrames);
    
    for (int i = 0; i < pingLengthFrames; i++) {
        ping[i] = sin(2 * M_PI * (4*440) * i / sampleRate);
    }
    
    outputLengthFrames = 5 * sampleRate;
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
//    printf("input: %lli, %lf\n", inTimeStamp->mHostTime, inTimeStamp->mSampleTime);
    if (outputWritePosition + inNumberFrames > outputLengthFrames) {
        printf("finished!\n");
        OSStatus err = AudioOutputUnitStop(audioUnit);
        assert(noErr == err);
        writeOutputToFile();
        return noErr;
    }
    
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

    outputABL->mNumberBuffers = 2;
    outputABL->mBuffers[0] = leftBuffer;
    outputABL->mBuffers[1] = rightBuffer;

    OSStatus err = AudioUnitRender(audioUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, outputABL);
    assert(noErr == err);   // maybe you're running this on the simulator

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
//    printf("output: %lli, %lf\n", inTimeStamp->mHostTime, inTimeStamp->mSampleTime);
    int availFrames = pingLengthFrames - pingPlaybackPosition;
    
    int framesToCopy = MIN(availFrames, inNumberFrames);

    // assuming interleaved here
    for (int i = 0; i < ioData->mNumberBuffers; i++) {
        AudioBuffer *buffer = &ioData->mBuffers[i];
        bzero(buffer->mData, buffer->mDataByteSize);    // lazy zeroing of leftover frames.
        memcpy(buffer->mData, &ping[pingPlaybackPosition], sizeof(ping[0]) * framesToCopy);
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
