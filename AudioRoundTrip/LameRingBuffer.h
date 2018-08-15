//
//  LameRingBuffer.h
//  AudioRoundTrip
//
//  Created by Gordon Childs on 15/8/18.
//  Copyright © 2018 Gordon Childs. All rights reserved.
//

#ifndef LameRingBuffer_h
#define LameRingBuffer_h

#include <stdint.h>

int ringBufferAvailableFrames(void);
uint64_t ringBufferStartSampleTime(void);
float* ringBufferGetReadPointer(void);
void ringBufferAdvanceReadPointer(int nframes);
void ringBufferWrite(float* in, int nframes);
void initLameRingBuffer(int capacityInFrames);

#endif /* LameRingBuffer_h */
