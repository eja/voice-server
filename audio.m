/* Copyright (C) 2025 by Ubaldo Porcheddu <ubaldo@eja.it> */

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

#import "audio.h"

BOOL convertAiffToWav(NSURL* sourceURL, NSURL* destinationURL, NSError** error) {
    AVAsset* sourceAsset = [AVURLAsset URLAssetWithURL:sourceURL options:nil];
    if (!sourceAsset) {
        if (error) *error = [NSError errorWithDomain:@"SpeechServerError" code:1001 userInfo:@{NSLocalizedDescriptionKey: @"Failed to load AIFF asset"}];
        return NO;
    }
    AVAssetReader* reader = [AVAssetReader assetReaderWithAsset:sourceAsset error:error];
    if (!reader) return NO;
    AVAssetTrack* audioTrack = [[sourceAsset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (!audioTrack) {
        if (error) *error = [NSError errorWithDomain:@"SpeechServerError" code:1002 userInfo:@{NSLocalizedDescriptionKey: @"No audio track in AIFF file"}];
        return NO;
    }

    AudioChannelLayout channelLayout;
    memset(&channelLayout, 0, sizeof(AudioChannelLayout));
    channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
    NSDictionary* readerOutputSettings = @{ AVFormatIDKey: @(kAudioFormatLinearPCM) };
    AVAssetReaderTrackOutput* readerOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:readerOutputSettings];
    if (![reader canAddOutput:readerOutput]) {
        if (error) *error = [NSError errorWithDomain:@"SpeechServerError" code:1003 userInfo:@{NSLocalizedDescriptionKey: @"Cannot add reader output"}];
        return NO;
    }
    [reader addOutput:readerOutput];

    Float64 sourceSampleRate = [audioTrack nominalFrameRate];
    if (sourceSampleRate <= 0) {
        NSArray *formatDescriptions = audioTrack.formatDescriptions;
        if (formatDescriptions.count > 0) {
            CMAudioFormatDescriptionRef formatDesc = (__bridge CMAudioFormatDescriptionRef)formatDescriptions[0];
            const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc);
            if (asbd) {
                sourceSampleRate = asbd->mSampleRate;
            }
        }
    }
    if (sourceSampleRate <= 0) {
        NSLog(@"Warning: Could not determine source sample rate, defaulting to 44100 Hz.");
        sourceSampleRate = 44100.0;
    }

    AVAssetWriter* writer = [AVAssetWriter assetWriterWithURL:destinationURL fileType:AVFileTypeWAVE error:error];
    if (!writer) return NO;
    NSDictionary* writerOutputSettings = @{
        AVFormatIDKey : @(kAudioFormatLinearPCM),
        AVSampleRateKey : @(sourceSampleRate),
        AVNumberOfChannelsKey : @1,
        AVChannelLayoutKey : [NSData dataWithBytes:&channelLayout length:sizeof(AudioChannelLayout)],
        AVLinearPCMBitDepthKey : @16,
        AVLinearPCMIsNonInterleaved : @NO,
        AVLinearPCMIsFloatKey : @NO,
        AVLinearPCMIsBigEndianKey : @NO
    };
    AVAssetWriterInput* writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:writerOutputSettings];
    writerInput.expectsMediaDataInRealTime = NO;
    if (![writer canAddInput:writerInput]) {
        if (error) *error = [NSError errorWithDomain:@"SpeechServerError" code:1004 userInfo:@{NSLocalizedDescriptionKey: @"Cannot add writer input"}];
        return NO;
    }
    [writer addInput:writerInput];

    if (![reader startReading]) { if (error) *error = reader.error; return NO; }
    if (![writer startWriting]) { if (error) *error = writer.error; return NO; }
    [writer startSessionAtSourceTime:kCMTimeZero];

    dispatch_queue_t conversionQueue = dispatch_queue_create("aiff_wav_q", DISPATCH_QUEUE_SERIAL);
    dispatch_group_t conversionGroup = dispatch_group_create();
    __block BOOL success = YES;
    __block NSError* operationError = nil;
    __block int totalBufferCount = 0;

    dispatch_group_enter(conversionGroup);

    __block BOOL isReaderFinished = NO;
    __block BOOL finalizing = NO;

    [writerInput requestMediaDataWhenReadyOnQueue:conversionQueue usingBlock:^{
        if (finalizing) {
            NSLog(@"[Conversion:%@] Block invoked after finalization started, ignoring.", destinationURL.lastPathComponent);
            return;
        }

        int buffersInThisBlock = 0;
        while (writerInput.readyForMoreMediaData && !isReaderFinished && success) {
            CMSampleBufferRef sampleBuffer = [readerOutput copyNextSampleBuffer];
            if (sampleBuffer) {
                buffersInThisBlock++;
                totalBufferCount++;
                if (totalBufferCount > 0 && totalBufferCount % 200 == 0) {
                    NSLog(@"[Conversion:%@] Processing buffer %d (block %d). writerInput.ready=%d", destinationURL.lastPathComponent, totalBufferCount, buffersInThisBlock, writerInput.readyForMoreMediaData);
                }

                if (![writerInput appendSampleBuffer:sampleBuffer]) {
                    operationError = writer.error ?: [NSError errorWithDomain:@"SpeechServerError" code:1005 userInfo:@{NSLocalizedDescriptionKey: @"appendSampleBuffer failed"}];
                    NSLog(@"[Conversion:%@] appendSampleBuffer failed after total %d buffers", destinationURL.lastPathComponent, totalBufferCount);
                    success = NO;
                }
                CFRelease(sampleBuffer);
            } else {
                isReaderFinished = YES;
                NSLog(@"[Conversion:%@] copyNextSampleBuffer returned NULL after total %d buffers. reader.status=%ld", destinationURL.lastPathComponent, totalBufferCount, (long)reader.status);
                if (reader.status == AVAssetReaderStatusFailed) {
                    if (!operationError) operationError = reader.error ?: [NSError errorWithDomain:@"SpeechServerError" code:1006 userInfo:@{NSLocalizedDescriptionKey: @"AssetReader failed"}];
                    NSLog(@"[Conversion:%@] Reader status is Failed.", destinationURL.lastPathComponent);
                    success = NO;
                } else if (reader.status == AVAssetReaderStatusCancelled) {
                    if (!operationError) operationError = [NSError errorWithDomain:@"SpeechServerError" code:1011 userInfo:@{NSLocalizedDescriptionKey: @"AssetReader was cancelled"}];
                    NSLog(@"[Conversion:%@] Reader status is Cancelled.", destinationURL.lastPathComponent);
                    success = NO;
                }
                break;
            }

            if (!success) {
                NSLog(@"[Conversion:%@] Exiting block's inner loop due to success=NO after total %d buffers.", destinationURL.lastPathComponent, totalBufferCount);
                break;
            }
        }

        NSLog(@"[Conversion:%@] Finished block processing %d buffers. isReaderFinished=%d, success=%d, writerInput.ready=%d",
              destinationURL.lastPathComponent, buffersInThisBlock, isReaderFinished, success, writerInput.readyForMoreMediaData);

        if (isReaderFinished || !success) {
            if (!finalizing) {
                finalizing = YES;

                if (success) {
                    NSLog(@"[Conversion:%@] Reader finished successfully, marking writer input as finished.", destinationURL.lastPathComponent);
                    [writerInput markAsFinished];
                } else {
                    NSLog(@"[Conversion:%@] Error detected (success=NO), cancelling writer if possible.", destinationURL.lastPathComponent);
                    if (writer.status == AVAssetWriterStatusWriting || writer.status == AVAssetWriterStatusUnknown) {
                        NSLog(@"[Conversion:%@] Cancelling writer (status %ld).", destinationURL.lastPathComponent, (long)writer.status);
                        [writer cancelWriting];
                    } else {
                        NSLog(@"[Conversion:%@] Not cancelling writer (status %ld).", destinationURL.lastPathComponent, (long)writer.status);
                    }
                }

                NSLog(@"[Conversion:%@] Proceeding to finalize writing (finishWriting/completion check). Current writer status: %ld", destinationURL.lastPathComponent, (long)writer.status);
                [writer finishWritingWithCompletionHandler:^{
                    if (writer.status == AVAssetWriterStatusFailed) {
                        if(!operationError) operationError = writer.error;
                        success = NO;
                        NSLog(@"[Conversion:%@] FINAL: finishWriting failed: %@", destinationURL.lastPathComponent, operationError);
                    } else if (writer.status == AVAssetWriterStatusCancelled) {
                        if (!operationError) operationError = [NSError errorWithDomain:@"SpeechServerError" code:1007 userInfo:@{NSLocalizedDescriptionKey: @"Writer was cancelled"}];
                        success = NO;
                        NSLog(@"[Conversion:%@] FINAL: finishWriting completed with Cancelled status.", destinationURL.lastPathComponent);
                    } else if (writer.status != AVAssetWriterStatusCompleted) {
                        if(!operationError) operationError = [NSError errorWithDomain:@"SpeechServerError" code:1008 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Writer finished with unexpected status: %ld", (long)writer.status]}];
                        success = NO;
                        NSLog(@"[Conversion:%@] FINAL: finishWriting completed with unexpected status: %ld.", destinationURL.lastPathComponent, (long)writer.status);
                    } else {
                        NSLog(@"[Conversion:%@] FINAL: finishWriting completed successfully.", destinationURL.lastPathComponent);
                    }
                    NSLog(@"[Conversion:%@] Leaving dispatch group.", destinationURL.lastPathComponent);
                    dispatch_group_leave(conversionGroup);
                }];
            } else {
                NSLog(@"[Conversion:%@] Finalization already in progress, skipping finish/cancel/mark.", destinationURL.lastPathComponent);
            }

        } else if (!writerInput.readyForMoreMediaData) {
            NSLog(@"[Conversion:%@] Block finished because writer is not ready. Waiting for re-invocation.", destinationURL.lastPathComponent);
        }
    }];

    dispatch_group_wait(conversionGroup, DISPATCH_TIME_FOREVER);
    NSLog(@"[Conversion:%@] Dispatch group wait finished. Final success=%d", destinationURL.lastPathComponent, success);

    if (!success && error && !*error) {
        *error = operationError;
    } else if (success && writer.status != AVAssetWriterStatusCompleted) {
        NSLog(@"Warning: Conversion group finished, success=YES, but writer status is %ld", (long)writer.status);
        if (writer.error) {
            success = NO;
            if (error && !*error) *error = writer.error;
        } else if (writer.status != AVAssetWriterStatusCompleted) {
            NSLog(@"Warning: Writer status is %ld without error after successful conversion indication.", (long)writer.status);
        }
    }

    return success;
}
