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

void
ForwardFFT(AccCorrelate *f, float *src, float *dst) {
    DSPSplitComplex io = { .realp = dst, .imagp = dst + f->N/2 };
    FFT(f, src, &io);
}

// a & b in frequency domain (accelerate packed format)
// overwrites b! hope that's ok. f for N
// scales by N!
void
Corrip(AccCorrelate *f, float* a, float* b, float* res) {
    int halfN = f->N / 2;
    // I think that's how it's laid out
    b[0] *= a[0];
    b[halfN] *= a[halfN];
    // multiply remaining complex elts
    // a long winded way to do pointer arithmetic
    float *a_x = &a[1];
    float *a_y = &a[halfN+1];
    float *b_x = &b[1];
    float *b_y = &b[halfN+1];
    DSPSplitComplex A = { .realp = a_x, .imagp = a_y };
    DSPSplitComplex B = { .realp = b_x, .imagp = b_y };
    vDSP_zvcmul(&A, 1, &B, 1, &B, 1, halfN-1);  // B <- A~*B
    
    DSPSplitComplex bsplit = { .realp = b, .imagp = b + halfN };
    IFFT(f, &bsplit, res);
    // TODO? just figure out offset from even/odd values?
    vDSP_ztoc(&bsplit, 1, (DSPComplex *)res, 2, halfN);
}

static void
AccCorrelateFN(float *ap, float *bp, float *res, int N) {
    // Reusable. TODO: reuse
    AccCorrelate f = NewAccCorr(N);

    float aw[N];
    DSPSplitComplex aws = { .realp = aw, .imagp = aw + N/2 };
    FFT(&f, ap, &aws);

    float bw[N];
    DSPSplitComplex bws = { .realp = bw, .imagp = bw + N/2 };
    FFT(&f, bp, &bws);
    
    // b*a(n) = a*b(-n) aka offset of a in b
    Corrip(&f, aw, bw, res);

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
        // https://www.mikeash.com/pyblog/friday-qa-2012-10-26-fourier-transforms-and-ffts.html
        // TODO: use cblas_sscal
        // real forward scales by 2 and there are 2, real inverse scales by N, so 4N.
        // https://developer.apple.com/library/archive/documentation/Performance/Conceptual/vDSP_Programming_Guide/UsingFourierTransforms/UsingFourierTransforms.html
        fftRes[i] /= (4*N); // Accelerate real scaling factors
        printf("%.8f, ", fftRes[i]);
        if (round(fftRes[i]) != expected[i]) match = false;
    }
    if (!match) printf("BAD!");
    printf("\n");
    
    float l2norm[2] = { 3, 4 };
    printf("cblas_snrm2(3, 4): %f\n", cblas_snrm2(2, l2norm, 1));   // should be 5
}

void
ExampleCorrelate2() {
    const int N_small = 4;
    const int N = 8;
    float a[N] = { 1, 9, 7, 7, 0, 0, 0, 0};
    float b[N] = { 2, -2, 2, 1, 9, 7, 7, 1};

    float aUnit[N];
    float aLen = cblas_snrm2(N_small, a, 1);
    for (int i = 0; i < N; i++) aUnit[i] = a[i];    // copy and do in-place scale
    cblas_sscal(N_small, 1.0/aLen, aUnit, 1);   // no out-of-place version?

    AccCorrelate f = NewAccCorr(N);

    float aFFTed[N];
    ForwardFFT(&f, aUnit, aFFTed);  // scaled by 2

    float bFFTed[N];
    ForwardFFT(&f, b, bFFTed);  // scaled by 2

    float  corrRes[N];
    Corrip(&f, aFFTed, bFFTed, corrRes);
    
    float cosThetas[N_small+1]; // I think there are N_small + 1 valid positions! whoooooops!
    for (int i = 0; i <= N_small; i++) {
        float bSubLen = cblas_snrm2(N_small, b+i, 1);
        cosThetas[i] = corrRes[i]/(bSubLen*4*N);
    }
    
    float bSub0Len = cblas_snrm2(N_small, b, 1);
    float bSubLenSquared = bSub0Len * bSub0Len;

    float cosThetas2[N_small+1];

    for (int i = 0; i <= N_small; i++) {
        float bSubLen = sqrt(bSubLenSquared);
        cosThetas2[i] = corrRes[i]/(bSubLen*4*N);
        float xn = b[i+N_small];
        float x0 = b[i];
        bSubLenSquared += xn*xn - x0*x0;
    }

    AccCorrDelete(&f);
}

