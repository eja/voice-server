#ifndef AUDIO_H
#define AUDIO_H

#import <Foundation/Foundation.h>

BOOL convertAiffToWav(NSURL* sourceURL, NSURL* destinationURL, NSError** error);

#endif
