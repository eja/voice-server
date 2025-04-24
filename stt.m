/* Copyright (C) 2025 by Ubaldo Porcheddu <ubaldo@eja.it> */

#import <Foundation/Foundation.h>
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>
#import <unistd.h>
#import <stdio.h>

#import "main.h"
#import "stt.h"

#define DEFAULT_LANGUAGE @"en-US"
#define STT_TIMEOUT_SECONDS 60.0

void handleSttRequest(int clientSock, ParsedHttpRequest request) {
     @autoreleasepool {
        if (!request.multipartBoundary) { sendErrorResponse(clientSock, 415, @"Unsupported Media Type", @"Requires multipart/form-data"); close(clientSock); return; }
        NSString *language = DEFAULT_LANGUAGE; NSData *audioData = nil; NSString *audioFilename = @"unknown";
        for (MultipartPart *part in request.multipartParts) { if ([part.name isEqualToString:@"language"] && part.body.length > 0) { language = [[NSString alloc] initWithData:part.body encoding:NSUTF8StringEncoding] ?: language; } else if ([part.name isEqualToString:@"audio"] && part.body.length > 0) { audioData = part.body; audioFilename = part.filename ?: audioFilename; } }
        if (!audioData || audioData.length == 0) { sendErrorResponse(clientSock, 400, @"Bad Request", @"Missing or empty 'audio' part"); close(clientSock); return; }
        NSLocale* locale = [NSLocale localeWithLocaleIdentifier:language];
        if (!locale) { sendErrorResponse(clientSock, 400, @"Bad Request", [NSString stringWithFormat:@"Invalid language code: %@", language]); close(clientSock); return; }
        NSLog(@"[%d] STT: Language='%@', Audio Size=%lu bytes.", clientSock, language, (unsigned long)audioData.length);

        SFSpeechRecognizerAuthorizationStatus authStatus = [SFSpeechRecognizer authorizationStatus];
        if (authStatus != SFSpeechRecognizerAuthorizationStatusAuthorized) {
             NSLog(@"[%d] SFSpeechRecognizer not pre-authorized (Status: %ld). Failing request.", clientSock, (long)authStatus);
             sendErrorResponse(clientSock, 503, @"Service Unavailable", @"Speech recognition requires pre-authorization");
             close(clientSock);
             return;
        }

        NSString* tempDir = NSTemporaryDirectory();
        NSString* uniqueID = [[NSUUID UUID] UUIDString];
        NSString* tempFilename = [NSString stringWithFormat:@"stt_input_%@_%@", uniqueID, audioFilename];
        tempFilename = [tempFilename stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        NSURL* tempAudioFileURL = [NSURL fileURLWithPath:[tempDir stringByAppendingPathComponent:tempFilename]];
        NSError* writeError = nil;
        if (![audioData writeToURL:tempAudioFileURL options:NSDataWritingAtomic error:&writeError]) {
            NSLog(@"[%d] Failed to write temporary audio file: %@", clientSock, writeError);
            sendErrorResponse(clientSock, 500, @"Internal Server Error", @"Failed to process temporary audio file");
            [[NSFileManager defaultManager] removeItemAtURL:tempAudioFileURL error:nil];
            close(clientSock);
            return;
        }

        NSError* fileError = nil;
        AVAudioFile* inputFile = [[AVAudioFile alloc] initForReading:tempAudioFileURL error:&fileError];
        if (!inputFile) {
            NSLog(@"[%d] Failed to open temporary audio file with AVAudioFile: %@", clientSock, fileError);
            sendErrorResponse(clientSock, 500, @"Internal Server Error", [NSString stringWithFormat:@"Cannot read provided audio file format: %@", fileError.localizedDescription]);
            [[NSFileManager defaultManager] removeItemAtURL:tempAudioFileURL error:nil];
            close(clientSock);
            return;
        }

        AVAudioFormat* fileProcessingFormat = inputFile.processingFormat;
        AVAudioFrameCount fileFrameLength = inputFile.length;
         if (fileFrameLength <= 0) {
              NSLog(@"[%d] STT: Error - Audio file has zero length.", clientSock);
              sendErrorResponse(clientSock, 400, @"Bad Request", @"Audio file appears to be empty or invalid.");
              [[NSFileManager defaultManager] removeItemAtURL:tempAudioFileURL error:nil];
              close(clientSock);
              return;
         }

        AVAudioPCMBuffer* pcmBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fileProcessingFormat
                                                                    frameCapacity:fileFrameLength];
        if (!pcmBuffer) {
             NSLog(@"[%d] Error: Failed to create AVAudioPCMBuffer from file format.", clientSock);
             sendErrorResponse(clientSock, 500, @"Internal Server Error", @"Failed to create audio buffer from file.");
             [[NSFileManager defaultManager] removeItemAtURL:tempAudioFileURL error:nil];
             close(clientSock);
             return;
        }

        NSError* readError = nil;
        if (![inputFile readIntoBuffer:pcmBuffer error:&readError]) {
            NSLog(@"[%d] Failed to read audio file into buffer: %@", clientSock, readError);
            sendErrorResponse(clientSock, 500, @"Internal Server Error", @"Failed to read audio data into buffer.");
            [[NSFileManager defaultManager] removeItemAtURL:tempAudioFileURL error:nil];
            close(clientSock);
            return;
        }
        [[NSFileManager defaultManager] removeItemAtURL:tempAudioFileURL error:nil];

        int capturedClientSock = clientSock; NSString *capturedLanguage = [language copy]; NSObject *sttLock = [NSObject new]; __block BOOL sttCompletedOrTimedOut = NO;
        __block SFSpeechRecognizer* recognizer = nil; __block SFSpeechRecognitionTask *recTask = nil;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(STT_TIMEOUT_SECONDS * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            BOOL shouldCleanupAndClose = NO; SFSpeechRecognitionTask *taskToCancel = nil;
             @synchronized (sttLock) { if (!sttCompletedOrTimedOut) { sttCompletedOrTimedOut = YES; shouldCleanupAndClose = YES; taskToCancel = recTask; NSLog(@"[%d] STT Request timed out after %.f seconds.", capturedClientSock, STT_TIMEOUT_SECONDS); sendErrorResponse(capturedClientSock, 504, @"Gateway Timeout", @"Speech recognition timed out"); } }
            if (shouldCleanupAndClose) { if (taskToCancel) { [taskToCancel cancel]; } close(capturedClientSock); NSLog(@"[%d] Closed socket on STT timeout.", capturedClientSock); recognizer = nil; recTask = nil; }
        });

        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"[%d] Setting up SFSpeechRecognizer on main thread for locale %@...", capturedClientSock, capturedLanguage);
            recognizer = [[SFSpeechRecognizer alloc] initWithLocale:locale];
            if (!recognizer) { NSLog(@"[%d] Recognizer init failed (main thread).", capturedClientSock); BOOL sc = NO; @synchronized(sttLock){if(!sttCompletedOrTimedOut){sttCompletedOrTimedOut=YES; sc=YES; sendErrorResponse(capturedClientSock,500,@"Internal Server Error",@"Recognizer init failed");}} if(sc) close(capturedClientSock); return; }
            if (!recognizer.isAvailable) { NSLog(@"[%d] Recognizer not available (main thread).", capturedClientSock); BOOL sc = NO; @synchronized(sttLock){if(!sttCompletedOrTimedOut){sttCompletedOrTimedOut=YES; sc=YES; sendErrorResponse(capturedClientSock,503,@"Service Unavailable",@"Recognizer not available");}} if(sc) close(capturedClientSock); recognizer = nil; return; }
            NSLog(@"[%d] SFSpeechRecognizer allocated on main thread.", capturedClientSock);

            SFSpeechAudioBufferRecognitionRequest *recReq = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
            if (!recReq) { NSLog(@"[%d] Failed to create SFSpeechRequest (main thread).", capturedClientSock); BOOL sc = NO; @synchronized(sttLock){if(!sttCompletedOrTimedOut){sttCompletedOrTimedOut=YES; sc=YES; sendErrorResponse(capturedClientSock,500,@"Internal Server Error",@"Failed to create recognition request");}} if(sc) close(capturedClientSock); recognizer = nil; return; }
            recReq.shouldReportPartialResults = NO;

            NSLog(@"[%d] Starting buffer recognition task for %@ (on main thread)...", capturedClientSock, capturedLanguage);
            recTask = [recognizer recognitionTaskWithRequest:recReq resultHandler:^(SFSpeechRecognitionResult *res, NSError *err) {
                 BOOL isFinal = NO; NSString* finalTranscript = nil; NSError* recognitionError = nil;
                 if (err) { recognitionError = err; isFinal = YES; } else if (res && res.isFinal) { finalTranscript = res.bestTranscription.formattedString; isFinal = YES; } else if (!res && !err && recTask.state == SFSpeechRecognitionTaskStateCompleted) { isFinal = YES; finalTranscript = @""; NSLog(@"[%d] STT Task completed without result/error.", capturedClientSock); }

                 if (isFinal) {
                     BOOL shouldCleanupAndClose = NO;
                     SFSpeechRecognitionTask *taskToCancelOnResult = nil;
                     @synchronized(sttLock) {
                         if (!sttCompletedOrTimedOut) {
                             sttCompletedOrTimedOut = YES; shouldCleanupAndClose = YES;
                             taskToCancelOnResult = recTask;
                             if (recognitionError) {
                                 NSLog(@"[%d] STT Error (main thread): %@ (Domain: %@ Code: %ld)", capturedClientSock, recognitionError.localizedDescription, recognitionError.domain, (long)recognitionError.code);
                                 NSString* errorMsg = [NSString stringWithFormat:@"Recognition failed: %@", recognitionError.localizedDescription]; int errCode = 500; NSString* errDesc = @"Internal Server Error";
                                 if ([recognitionError.domain isEqualToString:SFSpeechErrorDomain]) {
                                    if(recognitionError.code == 301) {errCode=400; errDesc=@"Bad Request"; errorMsg=@"Recog failed: Audio format/read issue.";}
                                 }
                                 else if ([recognitionError.domain isEqualToString:@"kAFAssistantErrorDomain"]) { if (recognitionError.code == 203){errCode=400; errDesc=@"Bad Request"; errorMsg=@"Recog failed: No speech detected.";} else if (recognitionError.code == 209){errCode=400; errDesc=@"Bad Request"; errorMsg=@"Recog failed: Audio format incompatible?";} else if (recognitionError.code == 1700){errCode=503; errDesc=@"Service Unavailable"; errorMsg=@"Recog failed: Apple Speech service issue.";}}
                                 else if (recognitionError.code == NSUserCancelledError && [recognitionError.domain isEqualToString:NSCocoaErrorDomain]) { shouldCleanupAndClose = NO; NSLog(@"[%d] STT Task cancelled (likely by timeout).", capturedClientSock); }
                                 if (shouldCleanupAndClose) sendErrorResponse(capturedClientSock, errCode, errDesc, errorMsg);
                             } else {
                                 NSLog(@"[%d] STT Success (main thread). Transcript: %@", capturedClientSock, finalTranscript ?: @"<empty>");
                                 NSDictionary* resultDict = @{ @"transcript": finalTranscript ?: @"", @"language": capturedLanguage };
                                 sendJsonResponse(capturedClientSock, 200, @"OK", resultDict);
                             }
                         } else { shouldCleanupAndClose = NO; }
                     }
                     if (shouldCleanupAndClose) {
                        if (taskToCancelOnResult) {
                            NSLog(@"[%d] Cancelling STT task in result handler.", capturedClientSock);
                            [taskToCancelOnResult cancel];
                        }
                        close(capturedClientSock); NSLog(@"[%d] Cleaned up and closed socket in STT result handler (main thread).", capturedClientSock);
                        recognizer = nil; recTask = nil;
                     }
                 }
            }];

            [recReq appendAudioPCMBuffer:pcmBuffer];
            [recReq endAudio];
            NSLog(@"[%d] STT task initiated, audio appended, end marked (main thread).", capturedClientSock);
       });
       NSLog(@"[%d] STT setup dispatched to main thread, worker returning. Socket managed by STT handlers/timeout.", capturedClientSock);
    }
}
