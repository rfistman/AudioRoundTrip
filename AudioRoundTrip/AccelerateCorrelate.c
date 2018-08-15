//
//  AccelerateCorrelate.c
//  AudioRoundTrip
//
//  Created by Gordon Childs on 14/8/18.
//  Copyright © 2018 Gordon Childs. All rights reserved.
//

// ha ha
// https://stackoverflow.com/a/33476285/22147

#include "AccelerateCorrelate.h"

#include <Accelerate/Accelerate.h>

typedef struct {
    FFTSetup    setup;
    vDSP_Length log2N;
    vDSP_Length N;
} AccCorrelate;

AccCorrelate
NewAccCorr(int N) {
    int log2N = ceil(log2(N));
    
    AccCorrelate    res = {
        .setup = vDSP_create_fftsetup(log2N, FFT_RADIX2),
        .log2N = log2N,
        .N = N
    };
    return res;
}

void
AccCorrDelete(AccCorrelate *f) {
    vDSP_destroy_fftsetup(f->setup);
}

static void
FFT(AccCorrelate *f, float *s, DSPSplitComplex *io) {
    // pretend real signal is interleaved complex and convert to split for zrip
    vDSP_ctoz((DSPComplex *)s, 2, io, 1, f->N/2);
    
    // in place real/packed fft
    vDSP_fft_zrip(f->setup, io, 1, f->log2N, kFFTDirection_Forward);
}

// TODO: freqFn in?
static void
IFFT(AccCorrelate *f, DSPSplitComplex *io, float *res) {
    vDSP_fft_zrip(f->setup, io, 1, f->log2N, kFFTDirection_Inverse);
    vDSP_ztoc(io, 1, (DSPComplex *)res, 2, f->N/2); // convert back
}
    
// overwrite a, I guess. f for N
static void
Corrip(AccCorrelate *f, float* a, DSPSplitComplex *asplit, float* b, float* res) {
    int halfN = f->N / 2;
    // I think that's how it's laid out
    a[0] *= b[0];
    a[halfN] *= b[halfN];
    // multiply remaining complex elts
    // a long winded way to do pointer arithmetic
    float *a_x = &a[1];
    float *a_y = &a[halfN+1];
    float *b_x = &b[1];
    float *b_y = &b[halfN+1];
    DSPSplitComplex A = { .realp = a_x, .imagp = a_y };
    DSPSplitComplex B = { .realp = b_x, .imagp = b_y };
    vDSP_zvcmul(&A, 1, &B, 1, &A, 1, halfN-1);
    
    IFFT(f, asplit, res);
    // TODO? just figure out offset from even/odd values?
    vDSP_ztoc(asplit, 1, (DSPComplex *)res, 2, halfN);
}

void
AccCorrelateFN(float *bp, float *ap, float *res, int N) {
    // Reusable. TODO: reuse
    AccCorrelate f = NewAccCorr(N);
    float aw[N];
    DSPSplitComplex aws = { .realp = aw, .imagp = aw + N/2 };
    FFT(&f, ap, &aws);

    float bw[N];
    DSPSplitComplex bws = { .realp = bw, .imagp = bw + N/2 };
    FFT(&f, bp, &bws);

    // b*a(n) = a*b(-n) aka offset of a in b
    Corrip(&f, bw, &bws, aw, res);   // NB: a, b switcharoo
    AccCorrDelete(&f);
}

// a*b into c, all distinct
// n^2, for testing
void
naiveRollingCorrelate(float *a, float *b, float *c, int N) {
    for (int j = 0; j < N; j++) {
        float s = 0;
        for (int i = 0; i < N; i++) {
            s += a[i] * b[(i+j)%N];
        }
        c[j] = s;
    }
}

void
ExampleCorrelate() {
    const int N = 8;
    float a[N] = {0, -9, 8, 1, 2, -3, 0, 7};
    float b[N] = {1, 2, -3, 0, -5, 5, 1, 9};
    int expected[N] = {-4, 36, -46, 80, -32, 42, -42, 26};
    float naiveRes[N];
    float fftRes[N];
    
    naiveRollingCorrelate(a, b, naiveRes, N);

    bool match = true;
    for (int i = 0; i < N; i++) {
        printf("%.8f, ", naiveRes[i]);
        if (round(naiveRes[i]) != expected[i]) match = false;
    }
    if (!match) printf("BAD!");
    printf("\n");
    
    AccCorrelateFN(a, b, fftRes, N);
    
    match = true;
    for (int i = 0; i < N; i++) {
        fftRes[i] /= (4*N); // whut?
        printf("%.8f, ", fftRes[i]);
        if (round(fftRes[i]) != expected[i]) match = false;
    }
    if (!match) printf("BAD!");
    printf("\n");
}

