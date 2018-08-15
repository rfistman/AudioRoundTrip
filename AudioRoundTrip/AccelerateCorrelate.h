//
//  AccelerateCorrelate.h
//  AudioRoundTrip
//
//  Created by Gordon Childs on 14/8/18.
//  Copyright © 2018 Gordon Childs. All rights reserved.
//

#ifndef AccelerateCorrelate_h
#define AccelerateCorrelate_h

#include <stdio.h>


#include <Accelerate/Accelerate.h>

typedef struct {
    FFTSetup    setup;
    vDSP_Length log2N;
    vDSP_Length N;
} AccCorrelate;

AccCorrelate NewAccCorr(int N);
void AccCorrDelete(AccCorrelate *f);

void ForwardFFT(AccCorrelate *f, float *src, float *dst);
void Corrip(AccCorrelate *f, float* a, float* b, float* res);

void ExampleCorrelate(void);

#endif /* AccelerateCorrelate_h */
