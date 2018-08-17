//
//  ViewController.m
//  AudioRoundTrip
//
//  Created by Gordon Childs on 10/8/18.
//  Copyright © 2018 Gordon Childs. All rights reserved.
//

#import "ViewController.h"
#import <mach/mach.h>

extern UInt64 hostTimeZero;
const uint64_t kBeatDurationHostTime = 500000000*3/125;  // bleah. half a second
const uint64_t kFlashDurationHostTime = 200000000*3/125;    // 200ms
static int currentBeat = -1;

@interface ViewController ()
@property (weak, nonatomic) IBOutlet UIView *flashingView;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
  
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self selector:@selector(pollFlashFlag)];
    [link addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    // ooh, now there's preferredFramesPerSecond which defaults to 60.
    // set to 0 for something faster maybe? anyway, just doing core animation
}

- (void)pollFlashFlag {
    if (hostTimeZero == 0) return;
    
    uint64_t h = mach_absolute_time()-hostTimeZero;
    int i = floor(((double)h)/kBeatDurationHostTime);    // conversion seems ok
    
    int colourType = 0; // white
    
    if (i < 4) {
        if (i != currentBeat) printf("BIP[%i]\n", i);
        colourType = 1; // red
    } else {
        if (i != currentBeat) printf("Note[%i]\n", (i-4)%13);
        colourType = 2; // green
    }
    currentBeat = i;
    
    uint64_t    beatRem = h-i*kBeatDurationHostTime;

    UIColor *colours[3] = { UIColor.whiteColor, UIColor.redColor, UIColor.greenColor };
    if (beatRem < kFlashDurationHostTime) {
        self.flashingView.backgroundColor = colours[colourType];
    } else {
        self.flashingView.backgroundColor = UIColor.whiteColor;
    }
}

@end
