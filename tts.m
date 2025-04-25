/* Copyright (C) 2025 by Ubaldo Porcheddu <ubaldo@eja.it> */

#import <Foundation/Foundation.h>
#import <AppKit/NSSpeechSynthesizer.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <stdio.h>

#import "main.h"
#import "tts.h"

#define DEFAULT_LANGUAGE @"en-US"
#define TTS_TIMEOUT_SECONDS 60.0

NSString* findVoiceForLanguage(NSString* langCode) {
    NSString* targetLangCode = langCode.lowercaseString;
    NSString* targetBaseLang = [[langCode componentsSeparatedByString:@"-"] firstObject].lowercaseString;
    NSArray* voices = [NSSpeechSynthesizer availableVoices];
    NSString* exactMatchVoice = nil;
    NSString* baseMatchVoice = nil;
    NSString* fallbackVoice = [NSSpeechSynthesizer defaultVoice];

    for (NSString* voiceIdentifier in voices) {
        NSDictionary* attrs = [NSSpeechSynthesizer attributesForVoice:voiceIdentifier];
        NSString* voiceLanguageAttribute = attrs[NSVoiceLanguage];
        if (!voiceLanguageAttribute || ![voiceIdentifier hasPrefix:@"com.apple."]) continue;

        NSString* currentVoiceLangCode = voiceLanguageAttribute.lowercaseString;
        NSString* currentVoiceBaseLang = [[voiceLanguageAttribute componentsSeparatedByString:@"-"] firstObject].lowercaseString;

        if ([currentVoiceLangCode isEqualToString:targetLangCode]) {
            exactMatchVoice = voiceIdentifier;
            break;
        }
        if (!exactMatchVoice && !baseMatchVoice && [currentVoiceBaseLang isEqualToString:targetBaseLang]) {
            baseMatchVoice = voiceIdentifier;
        }
    }
    NSString* selectedVoice = exactMatchVoice ?: baseMatchVoice ?: fallbackVoice;
    if (selectedVoice == fallbackVoice && !(exactMatchVoice || baseMatchVoice)) {
        NSLog(@"Warning: No suitable voice for '%@'. Using default: %@", langCode, fallbackVoice);
    }
    return selectedVoice;
}

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

@interface SpeechDelegate : NSObject <NSSpeechSynthesizerDelegate>
@property (nonatomic, assign) int clientSock;
@property (nonatomic, strong) NSURL *tempAiffURL;
@property (nonatomic, strong) NSURL *tempWavURL;
@property (nonatomic, weak) NSSpeechSynthesizer *synthesizer;
@property (nonatomic, strong) NSObject *completionLock;
@property (nonatomic, assign) BOOL completedOrTimedOut;
@end

@implementation SpeechDelegate

- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender didFinishSpeaking:(BOOL)finishedSuccessfully {
    BOOL shouldCleanupAndClose = NO;
    @synchronized(self.completionLock) {
        if (self.completedOrTimedOut) {
            NSLog(@"[%d] TTS Delegate: Fired after timeout/completion. Ignoring.", self.clientSock);
            return;
        }
        self.completedOrTimedOut = YES;
        shouldCleanupAndClose = YES;
        NSLog(@"[%d] TTS Delegate: didFinishSpeaking reported success: %d. Marked as completed.", self.clientSock, finishedSuccessfully);
    }

    if (shouldCleanupAndClose) {
        int capturedSock = self.clientSock;
        NSURL* capturedAiffURL = self.tempAiffURL;
        NSURL* capturedWavURL = self.tempWavURL;

        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *attrsError = nil;
        NSDictionary *fileAttrs = [fm attributesOfItemAtPath:capturedAiffURL.path error:&attrsError];
        unsigned long long fileSize = [fileAttrs fileSize];
        BOOL fileExists = [fm fileExistsAtPath:capturedAiffURL.path];

        NSLog(@"[%d] TTS Delegate: Checking AIFF file BEFORE conversion. Path: %@, Exists: %d, Size: %llu, AttrsError: %@",
              capturedSock, capturedAiffURL.path, fileExists, fileSize, attrsError);

        if (!finishedSuccessfully || !fileExists || fileSize == 0) {
            NSString *reason = !finishedSuccessfully ? @"Synthesis delegate reported failure" :
                              !fileExists ? @"AIFF file does not exist after synthesis" :
                              @"AIFF file is empty (0 bytes)";
            NSLog(@"[%d] TTS Delegate: Failing early before conversion attempt. Reason: %@", capturedSock, reason);
            sendErrorResponse(capturedSock, 500, @"Internal Server Error", [NSString stringWithFormat:@"Speech synthesis failed: %@", reason]);

            [[NSFileManager defaultManager] removeItemAtURL:capturedAiffURL error:nil];
            [[NSFileManager defaultManager] removeItemAtURL:capturedWavURL error:nil];
            close(capturedSock);
            NSLog(@"[%d] Closed socket in TTS delegate early exit cleanup.", capturedSock);
            objc_setAssociatedObject(sender, @selector(delegate), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }

        void (^cleanupAndClose)(void) = ^{
            [[NSFileManager defaultManager] removeItemAtURL:capturedAiffURL error:nil];
            [[NSFileManager defaultManager] removeItemAtURL:capturedWavURL error:nil];
            close(capturedSock);
            NSLog(@"[%d] Closed socket in TTS delegate cleanup block.", capturedSock);
            objc_setAssociatedObject(sender, @selector(delegate), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        };

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSError* conversionError = nil;
            BOOL conversionSuccess = convertAiffToWav(capturedAiffURL, capturedWavURL, &conversionError);

            if (!conversionSuccess) {
                NSString *errorDesc = conversionError.localizedDescription ?: @"Unknown error during conversion";
                NSLog(@"[%d] TTS Conversion failed: %@", capturedSock, errorDesc);
                sendErrorResponse(capturedSock, 500, @"Internal Server Error", [NSString stringWithFormat:@"WAV conversion failed: %@", errorDesc]);
                cleanupAndClose();
                return;
            }

            NSError* readError = nil;
            NSData* wavData = [NSData dataWithContentsOfURL:capturedWavURL options:NSDataReadingMappedIfSafe error:&readError];
            if (!wavData || readError) {
                NSLog(@"[%d] Failed to read final WAV file: %@", capturedSock, readError);
                sendErrorResponse(capturedSock, 500, @"Internal Server Error", @"Failed to read WAV file");
                cleanupAndClose();
                return;
            }

            sendHttpResponse(capturedSock, 200, @"OK", @{@"Content-Type": @"audio/wav"}, wavData);
            cleanupAndClose();
        });
    }
}
@end

void handleTtsRequest(int clientSock, ParsedHttpRequest request) {
    @autoreleasepool {
        if (![request.headers[@"content-type"] hasPrefix:@"application/json"]) {
            sendErrorResponse(clientSock, 415, @"Unsupported Media Type", @"Content-Type must be application/json");
            close(clientSock);
            return;
        }
        NSError* jsonError = nil;
        NSDictionary* jsonBody = [NSJSONSerialization JSONObjectWithData:request.body options:0 error:&jsonError];
        if (jsonError || !jsonBody) {
            sendErrorResponse(clientSock, 400, @"Bad Request", [NSString stringWithFormat:@"Invalid JSON: %@", jsonError.localizedDescription ?: @"Unknown"]);
            close(clientSock);
            return;
        }
        NSString* text = jsonBody[@"text"];
        NSString* language = jsonBody[@"language"] ?: DEFAULT_LANGUAGE;
        if (!text || text.length == 0) {
            sendErrorResponse(clientSock, 400, @"Bad Request", @"Missing 'text' field");
            close(clientSock);
            return;
        }

        NSString* voice = findVoiceForLanguage(language);
        NSSpeechSynthesizer* synthesizer = [[NSSpeechSynthesizer alloc] initWithVoice:voice];
        if (!synthesizer) {
            sendErrorResponse(clientSock, 500, @"Internal Server Error", @"Failed to init NSSpeechSynthesizer");
            close(clientSock);
            return;
        }

        SpeechDelegate* delegate = [SpeechDelegate new];
        delegate.clientSock = clientSock;
        NSString* tempDir = NSTemporaryDirectory();
        NSString* uniqueID = [[NSUUID UUID] UUIDString];
        delegate.tempAiffURL = [NSURL fileURLWithPath:[tempDir stringByAppendingPathComponent:[NSString stringWithFormat:@"tts_%@.aiff", uniqueID]]];
        delegate.tempWavURL = [NSURL fileURLWithPath:[tempDir stringByAppendingPathComponent:[NSString stringWithFormat:@"tts_%@.wav", uniqueID]]];
        delegate.synthesizer = synthesizer;
        delegate.completionLock = [NSObject new];
        delegate.completedOrTimedOut = NO;
        synthesizer.delegate = delegate;
        objc_setAssociatedObject(synthesizer, @selector(delegate), delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(TTS_TIMEOUT_SECONDS * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            BOOL shouldCleanupAndClose = NO;
            NSSpeechSynthesizer* synthToStop = nil;
            @synchronized (delegate.completionLock) {
                if (!delegate.completedOrTimedOut) {
                    delegate.completedOrTimedOut = YES;
                    shouldCleanupAndClose = YES;
                    synthToStop = delegate.synthesizer;
                    NSLog(@"[%d] TTS Request timed out after %.f seconds.", clientSock, TTS_TIMEOUT_SECONDS);
                    sendErrorResponse(clientSock, 504, @"Gateway Timeout", @"Speech synthesis timed out");
                }
            }
            if (shouldCleanupAndClose) {
                if (synthToStop) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [synthToStop stopSpeaking];
                    });
                }
                [[NSFileManager defaultManager] removeItemAtURL:delegate.tempAiffURL error:nil];
                [[NSFileManager defaultManager] removeItemAtURL:delegate.tempWavURL error:nil];
                close(clientSock);
                NSLog(@"[%d] Closed socket on TTS timeout.", clientSock);
            }
        });

        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"[%d] Starting TTS synthesis for language '%@' (on main thread)", clientSock, language);
            if (![synthesizer startSpeakingString:text toURL:delegate.tempAiffURL]) {
                BOOL shouldCleanupAndClose = NO;
                @synchronized(delegate.completionLock) {
                    if (!delegate.completedOrTimedOut) {
                        delegate.completedOrTimedOut = YES;
                        shouldCleanupAndClose = YES;
                        sendErrorResponse(clientSock, 500, @"Internal Server Error", @"Failed to start synthesis");
                    }
                }
                if (shouldCleanupAndClose) {
                    [[NSFileManager defaultManager] removeItemAtURL:delegate.tempAiffURL error:nil];
                    [[NSFileManager defaultManager] removeItemAtURL:delegate.tempWavURL error:nil];
                    close(clientSock);
                    NSLog(@"[%d] Closed socket on TTS start failure.", clientSock);
                    objc_setAssociatedObject(synthesizer, @selector(delegate), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            } else {
                NSLog(@"[%d] TTS initiated successfully (main thread).", clientSock);
            }
        });
        NSLog(@"[%d] TTS setup complete, worker thread returning.", clientSock);
    }
}
