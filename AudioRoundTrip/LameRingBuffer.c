//
//  LameRingBuffer.c
//  AudioRoundTrip
//
//  Created by Gordon Childs on 15/8/18.
//  Copyright © 2018 Gordon Childs. All rights reserved.
//

#include "LameRingBuffer.h"
#include <stdlib.h>
#include <string.h>
#include <assert.h>

static uint64_t inputBufferSampleTime;
static float *inputRingBuffer;
static int inputRingBufferReadPointer;
static int inputRingBufferWritePointer;
static int inputRingBufferCapacity;

void
initLameRingBuffer(int capacityInFrames) {
    inputRingBuffer = malloc(capacityInFrames*sizeof(float));
    assert(inputRingBuffer);
    inputRingBufferCapacity = capacityInFrames;
}

int
ringBufferAvailableFrames() {
    return inputRingBufferWritePointer-inputRingBufferReadPointer;
}

uint64_t
ringBufferStartSampleTime() {
    return inputBufferSampleTime;
}

float*
ringBufferGetReadPointer() {
    return &inputRingBuffer[inputRingBufferReadPointer];
}

void
ringBufferAdvanceReadPointer(int nframes) {
    inputRingBufferReadPointer += nframes;
    inputBufferSampleTime += nframes;
    assert(inputRingBufferReadPointer <= inputRingBufferWritePointer);
}

void
ringBufferWrite(float* in, int nframes) {
    if (inputRingBufferWritePointer + nframes > inputRingBufferCapacity) {
        // NSLog(@"write shifts ring buffer down");
        int availFrames = ringBufferAvailableFrames();
        memmove(&inputRingBuffer[0], &inputRingBuffer[inputRingBufferReadPointer], availFrames * sizeof(float));
        inputRingBufferWritePointer -= inputRingBufferReadPointer;
        inputRingBufferReadPointer = 0;
    }
    assert(inputRingBufferWritePointer + nframes <= inputRingBufferCapacity);
    memmove(&inputRingBuffer[inputRingBufferWritePointer], in, nframes*sizeof(float));
    inputRingBufferWritePointer += nframes;
}
