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

    AVAssetWriter* writer = [AVAssetWriter assetWriterWithURL:destinationURL fileType:AVFileTypeWAVE error:error];
    if (!writer) return NO;
    NSDictionary* writerOutputSettings = @{
        AVFormatIDKey : @(kAudioFormatLinearPCM), AVSampleRateKey : @44100.0, AVNumberOfChannelsKey : @1,
        AVChannelLayoutKey : [NSData dataWithBytes:&channelLayout length:sizeof(AudioChannelLayout)],
        AVLinearPCMBitDepthKey : @16, AVLinearPCMIsNonInterleaved : @NO, AVLinearPCMIsFloatKey : @NO, AVLinearPCMIsBigEndianKey : @NO
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

    dispatch_group_enter(conversionGroup);
    [writerInput requestMediaDataWhenReadyOnQueue:conversionQueue usingBlock:^{
        while (writerInput.readyForMoreMediaData && reader.status == AVAssetReaderStatusReading) {
            CMSampleBufferRef sampleBuffer = [readerOutput copyNextSampleBuffer];
            if (sampleBuffer) {
                if (![writerInput appendSampleBuffer:sampleBuffer]) {
                    operationError = writer.error;
                     [reader cancelReading];
                    success = NO;
                }
                CFRelease(sampleBuffer);
            } else {
                 if(reader.status == AVAssetReaderStatusFailed) {
                     if(!operationError) operationError = reader.error;
                     success = NO;
                 }
                break;
            }
            if (!success) break;
        }

        if (reader.status == AVAssetReaderStatusCompleted && success) {
            [writerInput markAsFinished];
        } else {
             if (writer.status != AVAssetWriterStatusCancelled && writer.status != AVAssetWriterStatusFailed) {
                 [writer cancelWriting];
             }
             success = NO;
        }

         [writer finishWritingWithCompletionHandler:^{
             if (writer.status == AVAssetWriterStatusFailed) {
                 if(!operationError) operationError = writer.error;
                 success = NO;
             } else if (writer.status == AVAssetWriterStatusCancelled) {
             } else if (writer.status != AVAssetWriterStatusCompleted) {
                 success = NO;
             }
             dispatch_group_leave(conversionGroup);
         }];
    }];

    dispatch_group_wait(conversionGroup, DISPATCH_TIME_FOREVER);
    if (error && operationError && !*error) { *error = operationError; }
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
        NSLog(@"[%d] TTS Delegate: didFinishSpeaking: %d. Marked as completed.", self.clientSock, finishedSuccessfully);
    }

    if (shouldCleanupAndClose) {
        int capturedSock = self.clientSock;
        NSURL* capturedAiffURL = self.tempAiffURL;
        NSURL* capturedWavURL = self.tempWavURL;

        void (^cleanupAndClose)(void) = ^{
             [[NSFileManager defaultManager] removeItemAtURL:capturedAiffURL error:nil];
             [[NSFileManager defaultManager] removeItemAtURL:capturedWavURL error:nil];
             close(capturedSock);
             NSLog(@"[%d] Closed socket in TTS delegate cleanup block.", capturedSock);
             objc_setAssociatedObject(sender, @selector(delegate), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        };

        if (!finishedSuccessfully || ![[NSFileManager defaultManager] fileExistsAtPath:capturedAiffURL.path] || [[[NSFileManager defaultManager] attributesOfItemAtPath:capturedAiffURL.path error:nil] fileSize] == 0) {
            sendErrorResponse(capturedSock, 500, @"Internal Server Error", @"Speech synthesis failed or produced empty file");
            cleanupAndClose();
            return;
        }

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSError* conversionError = nil;
            BOOL conversionSuccess = convertAiffToWav(capturedAiffURL, capturedWavURL, &conversionError);

            if (!conversionSuccess) {
                sendErrorResponse(capturedSock, 500, @"Internal Server Error", [NSString stringWithFormat:@"WAV conversion failed: %@", conversionError.localizedDescription ?: @"Unknown"]);
                cleanupAndClose();
                return;
            }

            NSError* readError = nil;
            NSData* wavData = [NSData dataWithContentsOfURL:capturedWavURL options:NSDataReadingMappedIfSafe error:&readError];
            if (!wavData || readError) {
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
        if (![request.headers[@"content-type"] hasPrefix:@"application/json"]) { sendErrorResponse(clientSock, 415, @"Unsupported Media Type", @"Content-Type must be application/json"); close(clientSock); return; }
        NSError* jsonError = nil; NSDictionary* jsonBody = [NSJSONSerialization JSONObjectWithData:request.body options:0 error:&jsonError];
        if (jsonError || !jsonBody) { sendErrorResponse(clientSock, 400, @"Bad Request", [NSString stringWithFormat:@"Invalid JSON: %@", jsonError.localizedDescription ?: @"Unknown"]); close(clientSock); return; }
        NSString* text = jsonBody[@"text"]; NSString* language = jsonBody[@"language"] ?: DEFAULT_LANGUAGE;
        if (!text || text.length == 0) { sendErrorResponse(clientSock, 400, @"Bad Request", @"Missing 'text' field"); close(clientSock); return; }

        NSString* voice = findVoiceForLanguage(language); NSSpeechSynthesizer* synthesizer = [[NSSpeechSynthesizer alloc] initWithVoice:voice];
        if (!synthesizer) { sendErrorResponse(clientSock, 500, @"Internal Server Error", @"Failed to init NSSpeechSynthesizer"); close(clientSock); return; }

        SpeechDelegate* delegate = [SpeechDelegate new]; delegate.clientSock = clientSock; NSString* tempDir = NSTemporaryDirectory(); NSString* uniqueID = [[NSUUID UUID] UUIDString];
        delegate.tempAiffURL = [NSURL fileURLWithPath:[tempDir stringByAppendingPathComponent:[NSString stringWithFormat:@"tts_%@.aiff", uniqueID]]]; delegate.tempWavURL = [NSURL fileURLWithPath:[tempDir stringByAppendingPathComponent:[NSString stringWithFormat:@"tts_%@.wav", uniqueID]]];
        delegate.synthesizer = synthesizer; delegate.completionLock = [NSObject new]; delegate.completedOrTimedOut = NO;
        synthesizer.delegate = delegate;
        objc_setAssociatedObject(synthesizer, @selector(delegate), delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(TTS_TIMEOUT_SECONDS * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            BOOL shouldCleanupAndClose = NO; NSSpeechSynthesizer* synthToStop = nil;
            @synchronized (delegate.completionLock) {
                if (!delegate.completedOrTimedOut) { delegate.completedOrTimedOut = YES; shouldCleanupAndClose = YES; synthToStop = delegate.synthesizer; NSLog(@"[%d] TTS Request timed out after %.f seconds.", clientSock, TTS_TIMEOUT_SECONDS); sendErrorResponse(clientSock, 504, @"Gateway Timeout", @"Speech synthesis timed out"); }
            }
            if (shouldCleanupAndClose) {
                 if (synthToStop) { dispatch_async(dispatch_get_main_queue(), ^{ [synthToStop stopSpeaking]; }); }
                 [[NSFileManager defaultManager] removeItemAtURL:delegate.tempAiffURL error:nil]; [[NSFileManager defaultManager] removeItemAtURL:delegate.tempWavURL error:nil];
                 close(clientSock); NSLog(@"[%d] Closed socket on TTS timeout.", clientSock);
            }
        });

        dispatch_async(dispatch_get_main_queue(), ^{
             NSLog(@"[%d] Starting TTS synthesis for language '%@' (on main thread)", clientSock, language);
            if (![synthesizer startSpeakingString:text toURL:delegate.tempAiffURL]) {
                BOOL shouldCleanupAndClose = NO;
                 @synchronized(delegate.completionLock) { if (!delegate.completedOrTimedOut) { delegate.completedOrTimedOut = YES; shouldCleanupAndClose = YES; sendErrorResponse(clientSock, 500, @"Internal Server Error", @"Failed to start synthesis"); } }
                 if (shouldCleanupAndClose) { [[NSFileManager defaultManager] removeItemAtURL:delegate.tempAiffURL error:nil]; [[NSFileManager defaultManager] removeItemAtURL:delegate.tempWavURL error:nil]; close(clientSock); NSLog(@"[%d] Closed socket on TTS start failure.", clientSock); objc_setAssociatedObject(synthesizer, @selector(delegate), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
            } else { NSLog(@"[%d] TTS initiated successfully (main thread).", clientSock); }
        });
        NSLog(@"[%d] TTS setup complete, worker thread returning.", clientSock);
    }
}
