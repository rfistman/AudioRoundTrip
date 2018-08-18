#include <math.h>
#include <stdio.h>
#include <assert.h>

// TODO: ramp in/out?

const double IMPULSE_TONE_FREQUENCY = 880;//261.6;
const int IMPULSE_FREQUENCY = 2;	// bad name. every half second

int
num_samples_for_sample_rate(double sample_rate) {
	return sample_rate * 10;
}

void
create_impulses(double sample_rate, float* dst) {
	int samples_to_output = num_samples_for_sample_rate(sample_rate);
	int pulse_num = 0;

	const int IMPULSE_DURATION_SAMPLES = 0.04*sample_rate;	// ~220 samples. less causes distortion on iphonex?
	const int CHUNK_SIZE = sample_rate/IMPULSE_FREQUENCY;

	printf("samples to do %i, impulse duration: %i, chunk size: %i @ %lfHz\n",
					samples_to_output, IMPULSE_DURATION_SAMPLES, CHUNK_SIZE, sample_rate);

	while (samples_to_output > 0) {
		float x;

		// do impulse
		int note = pulse_num % (12+1);
		double alpha = pow(2, (double)(note)/12);

		// TODO: make it end on zero too
		for (int i = 0; i < IMPULSE_DURATION_SAMPLES; i++) {
			x = sin(2 * M_PI * IMPULSE_TONE_FREQUENCY * alpha * i / sample_rate);
			//x = sin(2 * M_PI * IMPULSE_TONE_FREQUENCY * (2*(pulse_num % 3) + 1)* i / SAMPLE_RATE);
			*dst++ = x;
		}

		// do silence
		int remaining_silence = CHUNK_SIZE-IMPULSE_DURATION_SAMPLES;
		assert(remaining_silence > 0);
		for (int i = 0; i < remaining_silence; i++) *dst++ = 0;

		pulse_num++;

		samples_to_output -= CHUNK_SIZE;
	}
}


