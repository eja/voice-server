/* Copyright (C) 2025 by Ubaldo Porcheddu <ubaldo@eja.it> */

#import <Foundation/Foundation.h>
#import <AppKit/NSSpeechSynthesizer.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <stdio.h>

#import "main.h"
#import "tts.h"
#import "audio.h"

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
