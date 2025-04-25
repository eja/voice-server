/* Copyright (C) 2025 by Ubaldo Porcheddu <ubaldo@eja.it> */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Speech/Speech.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <getopt.h>
#import <stdio.h>
#import <string.h>
#import <pthread.h>
#import <fcntl.h>
#import <signal.h>

#import "main.h"
#import "tts.h"
#import "stt.h"

#define DEFAULT_PORT 35248
#define DEFAULT_HOST @"127.0.0.1"
#define READ_BUFFER_SIZE 4096
#define MAX_REQUEST_SIZE (50 * 1024 * 1024 + 10240)

@implementation MultipartPart
@end


void sendHttpResponse(int clientSock, int code, NSString *desc, NSDictionary *headers, NSData *body) {
     NSMutableString *resStr = [NSMutableString stringWithFormat:@"HTTP/1.1 %d %@\r\n", code, desc];
     NSMutableDictionary *resHdrs = [NSMutableDictionary dictionaryWithDictionary:headers];
     if (body.length > 0 && !resHdrs[@"Content-Length"] && !resHdrs[@"content-length"]) {
         resHdrs[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)body.length];
     }
     resHdrs[@"Connection"] = @"close";
     for (NSString *key in resHdrs) { [resStr appendFormat:@"%@: %@\r\n", key, resHdrs[key]]; }
     [resStr appendString:@"\r\n"];
     NSMutableData *resData = [NSMutableData dataWithData:[resStr dataUsingEncoding:NSUTF8StringEncoding]];
     if (body) [resData appendData:body];
     ssize_t totalSent = 0; ssize_t sent; NSUInteger totalLen = resData.length; const char *ptr = resData.bytes;
     NSLog(@"[%d] Sending HTTP Response: Code=%d, Desc=%@, BodyLen=%lu", clientSock, code, desc, (unsigned long)(body ? body.length : 0));
     while(totalSent < totalLen) {
         sent = send(clientSock, ptr + totalSent, totalLen - totalSent, MSG_NOSIGNAL);
         if (sent < 0) {
             if (errno != EPIPE && errno != ECONNRESET) {
                 NSLog(@"[%d] send failed: %s", clientSock, strerror(errno));
             } else {
                 NSLog(@"[%d] send failed: Client disconnected during send (errno %d)", clientSock, errno);
             }
             break;
         }
         totalSent += sent;
     }
}


void sendJsonResponse(int clientSock, int code, NSString* desc, NSDictionary *jsonObj) {
    NSError *jsonError;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonObj options:0 error:&jsonError];
    if (jsonError) {
        NSLog(@"[%d] Error serializing JSON response: %@", clientSock, jsonError);
        NSData* errJson = [@"{\"error\":\"Internal JSON Error\"}" dataUsingEncoding:NSUTF8StringEncoding];
         sendHttpResponse(clientSock, 500, @"Internal Server Error", @{@"Content-Type":@"application/json"}, errJson);
        return;
    }
    sendHttpResponse(clientSock, code, desc, @{@"Content-Type":@"application/json"}, jsonData);
}


void sendErrorResponse(int clientSock, int code, NSString *desc, NSString *msg) {
    NSLog(@"[%d] Sending error %d: %@ - '%@'", clientSock, code, desc, msg);
    sendJsonResponse(clientSock, code, desc, @{@"error": msg});
}

NSArray* parseMultipartBody(NSData *body, NSString *boundary) {
    NSMutableArray *parts = [NSMutableArray array];
    if (!boundary || body.length == 0) return parts;
    NSString *bndStr = [NSString stringWithFormat:@"--%@", boundary];
    NSString *endBndStr = [NSString stringWithFormat:@"%@--", bndStr];
    NSData *bndData = [bndStr dataUsingEncoding:NSUTF8StringEncoding];
    NSData *endBndData = [endBndStr dataUsingEncoding:NSUTF8StringEncoding];
    NSData *crlf = [@"\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *dblCrlf = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSUInteger pos = 0;
    NSRange bndRange = [body rangeOfData:bndData options:0 range:NSMakeRange(0, body.length)];
    if (bndRange.location == NSNotFound) return parts;
    pos = bndRange.location + bndRange.length;

    while (pos < body.length) {
        if (pos + crlf.length <= body.length && [[body subdataWithRange:NSMakeRange(pos, crlf.length)] isEqualToData:crlf]) {
            pos += crlf.length;
        }
        NSRange headersEndRange = [body rangeOfData:dblCrlf options:0 range:NSMakeRange(pos, body.length - pos)];
        if (headersEndRange.location == NSNotFound) break;

        NSData *headersData = [body subdataWithRange:NSMakeRange(pos, headersEndRange.location - pos)];
        NSString *headersString = [[NSString alloc] initWithData:headersData encoding:NSUTF8StringEncoding];
        NSMutableDictionary *partHeaders = [NSMutableDictionary dictionary];
        NSString *partName = nil, *partFilename = nil;
        for (NSString *line in [headersString componentsSeparatedByString:@"\r\n"]) {
            NSRange colonRange = [line rangeOfString:@":"];
            if (colonRange.location != NSNotFound) {
                NSString *key = [[line substringToIndex:colonRange.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                NSString *value = [[line substringFromIndex:colonRange.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                partHeaders[key] = value;
                if ([key caseInsensitiveCompare:@"Content-Disposition"] == NSOrderedSame) {
                    for (NSString *partStr in [value componentsSeparatedByString:@";"]) {
                        NSString *trimmedPart = [partStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        if ([trimmedPart hasPrefix:@"name="]) {
                            partName = [[trimmedPart substringFromIndex:5] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
                        } else if ([trimmedPart hasPrefix:@"filename="]) {
                            partFilename = [[trimmedPart substringFromIndex:9] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
                        }
                    }
                }
            }
        }
        NSUInteger bodyStart = headersEndRange.location + headersEndRange.length;
        NSRange nextBndRange = [body rangeOfData:bndData options:0 range:NSMakeRange(bodyStart, body.length - bodyStart)];
        NSRange finalBndRange = [body rangeOfData:endBndData options:0 range:NSMakeRange(bodyStart, body.length - bodyStart)];
        NSUInteger bodyEnd = NSNotFound;
        if (finalBndRange.location != NSNotFound && (nextBndRange.location == NSNotFound || finalBndRange.location < nextBndRange.location)) {
             bodyEnd = finalBndRange.location;
        } else if (nextBndRange.location != NSNotFound) {
             bodyEnd = nextBndRange.location;
        } else break;
        if (bodyEnd > bodyStart && bodyEnd >= crlf.length) {
            NSRange potentialCRLF = NSMakeRange(bodyEnd - crlf.length, crlf.length);
            if ([[body subdataWithRange:potentialCRLF] isEqualToData:crlf]){ bodyEnd -= crlf.length; }
        }
        NSData *partBodyData = (bodyEnd > bodyStart) ? [body subdataWithRange:NSMakeRange(bodyStart, bodyEnd - bodyStart)] : [NSData data];
        MultipartPart *part = [MultipartPart new];
        part.headers = partHeaders; part.body = partBodyData; part.name = partName; part.filename = partFilename;
        [parts addObject:part];

        if (finalBndRange.location != NSNotFound && bodyEnd + crlf.length >= finalBndRange.location) break;
        else {
            pos = bodyEnd + crlf.length;
            NSRange nextPartBoundary = [body rangeOfData:bndData options:0 range:NSMakeRange(pos, body.length - pos)];
            if (nextPartBoundary.location != NSNotFound) pos = nextPartBoundary.location + nextPartBoundary.length;
            else break;
        }
    }
    return parts;
}

ParsedHttpRequest parseHttpRequest(NSData *requestData) {
    ParsedHttpRequest parsed = {0}; parsed.headers = @{}; parsed.body = [NSData data];
    NSRange dblCrlfRange = [requestData rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, requestData.length)];
    if (dblCrlfRange.location == NSNotFound) return parsed;

    NSData *headerData = [requestData subdataWithRange:NSMakeRange(0, dblCrlfRange.location)];
    NSString *headerString = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding];
    NSArray *headerLines = [headerString componentsSeparatedByString:@"\r\n"];
    if (headerLines.count == 0) return parsed;

    NSArray *reqLineComps = [headerLines[0] componentsSeparatedByString:@" "];
    if (reqLineComps.count >= 2) { parsed.method = reqLineComps[0]; parsed.path = reqLineComps[1]; }
    else return parsed;

    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < headerLines.count; ++i) {
        NSRange colonRange = [headerLines[i] rangeOfString:@":"];
        if (colonRange.location != NSNotFound) {
            NSString *key = [[headerLines[i] substringToIndex:colonRange.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *value = [[headerLines[i] substringFromIndex:colonRange.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            headers[[key lowercaseString]] = value;
        }
    }
    parsed.headers = headers;
    NSUInteger bodyStart = dblCrlfRange.location + dblCrlfRange.length;
    if (bodyStart < requestData.length) {
        parsed.body = [requestData subdataWithRange:NSMakeRange(bodyStart, requestData.length - bodyStart)];
    }
    NSString *contentType = parsed.headers[@"content-type"];
    if (contentType && [contentType hasPrefix:@"multipart/form-data"]) {
        NSRange boundaryRange = [contentType rangeOfString:@"boundary="];
        if (boundaryRange.location != NSNotFound) {
            parsed.multipartBoundary = [[contentType substringFromIndex:boundaryRange.location + boundaryRange.length] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\" "]];
            parsed.multipartParts = parseMultipartBody(parsed.body, parsed.multipartBoundary);
        }
    }
    return parsed;
}


void printUsage() {
    printf("Copyright: 2025 by Ubaldo Porcheddu <ubaldo@eja.it>\n");
    printf("Version: %s\n", [VERSION UTF8String]);
    printf("Usage: %s [options]\n\n", [NAME UTF8String]);
    printf(" --port <number>      port (default: %d)\n", DEFAULT_PORT);
    printf(" --host <address>     host (default: %s)\n", [DEFAULT_HOST UTF8String]);
    printf(" --log  <path>        redirect logs to a file\n");
    printf(" --help               this help\n");
    printf("\n");
}


void handleConnection(int clientSock, struct sockaddr_in clientAddr) {
     @autoreleasepool {
        char clientIpStr[INET_ADDRSTRLEN]; inet_ntop(AF_INET, &clientAddr.sin_addr, clientIpStr, INET_ADDRSTRLEN); int clientPortNum = ntohs(clientAddr.sin_port);
        NSLog(@"[%d] Handling connection from %s:%d on thread %@", clientSock, clientIpStr, clientPortNum, [NSThread currentThread]);

        int flags = fcntl(clientSock, F_GETFL, 0);
        if (flags == -1) {
            perror("fcntl F_GETFL failed");
             NSLog(@"[%d] Failed to get socket flags. Closing.", clientSock);
             close(clientSock);
             return;
        } else {
             if (flags & O_NONBLOCK) {
                  NSLog(@"[%d] Accepted socket was non-blocking (flags=%d). Setting to blocking.", clientSock, flags);
                 flags &= ~O_NONBLOCK;
                 if (fcntl(clientSock, F_SETFL, flags) == -1) {
                     perror("fcntl F_SETFL failed");
                      NSLog(@"[%d] Failed to set socket blocking. Closing.", clientSock);
                      close(clientSock);
                      return;
                 }
             } else {
                  NSLog(@"[%d] Accepted socket is already blocking (flags=%d).", clientSock, flags);
             }
        }

        NSMutableData *requestData = [NSMutableData data]; char buffer[READ_BUFFER_SIZE]; ssize_t bytesRead; NSUInteger totalBytesRead = 0;
        BOOL headersComplete = NO; NSUInteger headerLength = 0; long long expectedBodyLength = -1;

        struct timeval tv = {.tv_sec = 30, .tv_usec = 0};
        if (setsockopt(clientSock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv) < 0) {
             perror("setsockopt SO_RCVTIMEO failed");
        } else {
             NSLog(@"[%d] Set SO_RCVTIMEO to %ld seconds.", clientSock, tv.tv_sec);
        }

        BOOL readErrorOccurred = NO;
        while (YES) {
             bytesRead = recv(clientSock, buffer, sizeof(buffer), 0);
             if (bytesRead > 0) {
                 [requestData appendBytes:buffer length:bytesRead]; totalBytesRead += bytesRead;
                 if (!headersComplete) {
                     NSRange doubleCrlfRange = [requestData rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, requestData.length)];
                     if (doubleCrlfRange.location != NSNotFound) {
                         headersComplete = YES; headerLength = doubleCrlfRange.location + doubleCrlfRange.length;
                         NSString *headerString = [[NSString alloc] initWithData:[requestData subdataWithRange:NSMakeRange(0, headerLength)] encoding:NSUTF8StringEncoding];
                         if (headerString) {
                             NSRange clRange = [headerString rangeOfString:@"\r\nContent-Length: " options:NSCaseInsensitiveSearch range:NSMakeRange(0, headerString.length)];
                             if (clRange.location != NSNotFound) {
                                 NSUInteger clValueStart = clRange.location + clRange.length;
                                 NSRange clValueEndRange = [headerString rangeOfString:@"\r\n" options:0 range:NSMakeRange(clValueStart, headerString.length - clValueStart)];
                                 if (clValueEndRange.location != NSNotFound) {
                                     expectedBodyLength = [[headerString substringWithRange:NSMakeRange(clValueStart, clValueEndRange.location - clValueStart)] longLongValue];
                                     NSLog(@"[%d] Parsed Content-Length: %lld", clientSock, expectedBodyLength);
                                 }
                             } else { expectedBodyLength = 0; }
                         } else {
                             NSLog(@"[%d] Warning: Could not decode headers as UTF8.", clientSock);
                             expectedBodyLength = -1;
                         }
                     }
                 }

                 if (headersComplete && expectedBodyLength >= 0) {
                     NSUInteger currentBodyLength = (totalBytesRead > headerLength) ? (totalBytesRead - headerLength) : 0;
                     if (currentBodyLength >= expectedBodyLength) {
                         NSLog(@"[%d] Received expected body length (%lld bytes).", clientSock, expectedBodyLength);
                         break;
                     }
                 }

                 if (requestData.length > MAX_REQUEST_SIZE) {
                     NSLog(@"[%d] Request size limit exceeded (%lu bytes).", clientSock, (unsigned long)requestData.length);
                     sendErrorResponse(clientSock, 413, @"Payload Too Large", @"Request size limit exceeded");
                     readErrorOccurred = YES; break;
                 }
             } else if (bytesRead == 0) {
                 if (!headersComplete || (expectedBodyLength > 0 && (totalBytesRead - headerLength) < expectedBodyLength)) {
                     NSLog(@"[%d] Client closed connection prematurely.", clientSock);
                     readErrorOccurred = YES;
                 } else {
                     NSLog(@"[%d] Client closed connection cleanly.", clientSock);
                 }
                 break;
             } else {
                  if (errno == EAGAIN || errno == EWOULDBLOCK) {
                      NSLog(@"[%d] Read timeout occurred (SO_RCVTIMEO expired).", clientSock);
                  } else if (errno == EINTR) {
                      NSLog(@"[%d] Read interrupted, continuing.", clientSock);
                      continue;
                  } else {
                      NSLog(@"[%d] recv failed: %s", clientSock, strerror(errno));
                  }
                  readErrorOccurred = YES;
                  break;
            }
        }

        if (readErrorOccurred) {
             NSLog(@"[%d] Closing socket due to read error/timeout/premature close.", clientSock);
             close(clientSock);
        }
        else if (!headersComplete && requestData.length == 0) {
            NSLog(@"[%d] Received empty request, closing.", clientSock);
            close(clientSock);
        }
        else if (!headersComplete) {
             NSLog(@"[%d] Read loop finished but headers incomplete (total read %lu).", clientSock, (unsigned long)requestData.length);
             sendErrorResponse(clientSock, 400, @"Bad Request", @"Incomplete HTTP headers");
             close(clientSock);
        }
        else {
             NSUInteger finalBodyLength = (requestData.length > headerLength) ? (requestData.length - headerLength) : 0;
             if (expectedBodyLength >= 0 && finalBodyLength < expectedBodyLength) {
                  NSLog(@"[%d] Warning: Final body length (%lu) is less than expected (%lld).", clientSock, (unsigned long)finalBodyLength, expectedBodyLength);
                  sendErrorResponse(clientSock, 400, @"Bad Request", @"Incomplete request body received");
                  close(clientSock);
                  return;
             }
             if (expectedBodyLength >= 0 && finalBodyLength > expectedBodyLength) {
                 NSLog(@"[%d] Warning: Trimming %lu excess bytes.", clientSock, (unsigned long)(finalBodyLength - expectedBodyLength));
                 requestData = [NSMutableData dataWithData:[requestData subdataWithRange:NSMakeRange(0, headerLength + expectedBodyLength)]];
             }

             ParsedHttpRequest parsedReq = parseHttpRequest(requestData);
             if (parsedReq.method && parsedReq.path) {
                 NSLog(@"[%d] Dispatching handler for %@ %@", clientSock, parsedReq.method, parsedReq.path);
                 BOOL requestDispatched = NO;
                 if ([parsedReq.method isEqualToString:@"POST"]) {
                     if ([parsedReq.path isEqualToString:@"/tts"]) {
                         handleTtsRequest(clientSock, parsedReq); requestDispatched = YES;
                     } else if ([parsedReq.path isEqualToString:@"/stt"]) {
                         handleSttRequest(clientSock, parsedReq); requestDispatched = YES;
                     }
                 }
                 if (!requestDispatched) {
                     int code = 404; NSString *desc = @"Not Found";
                     if ([parsedReq.method isEqualToString:@"GET"] || [parsedReq.method isEqualToString:@"HEAD"] || [parsedReq.method isEqualToString:@"PUT"] || [parsedReq.method isEqualToString:@"DELETE"] || [parsedReq.method isEqualToString:@"OPTIONS"] || [parsedReq.method isEqualToString:@"PATCH"]) { code = 405; desc = @"Method Not Allowed"; }
                     sendErrorResponse(clientSock, code, desc, @"Method or path not supported.");
                      NSLog(@"[%d] Closed socket for unhandled request.", clientSock);
                     close(clientSock);
                 }
                 else {
                     NSLog(@"[%d] handleConnection finished dispatching async handler. Socket management transferred.", clientSock);
                 }
             } else {
                 sendErrorResponse(clientSock, 400, @"Bad Request", @"Malformed HTTP request line.");
                  NSLog(@"[%d] Closed socket for malformed request line.", clientSock);
                 close(clientSock);
             }
        }
    }
}


int main(int argc, char * const argv[]) {
     [NSApplication sharedApplication]; 
     @autoreleasepool {
        int serverPort = DEFAULT_PORT;
        NSString *serverHost = DEFAULT_HOST;
        NSString *logFilePath = nil;

        enum {
            OPT_PORT = 0x100,
            OPT_HOST,
            OPT_LOG,
            OPT_HELP
        };
        
        struct option long_opts[] = {
            {"port", required_argument, NULL, OPT_PORT},
            {"host", required_argument, NULL, OPT_HOST},
            {"log", required_argument, NULL, OPT_LOG},
            {"help", no_argument, NULL, OPT_HELP},
            {NULL, 0, NULL, 0}
        };

        int c;
        int option_index = 0;
        while ((c = getopt_long(argc, argv, "", long_opts, &option_index)) != -1) {
            switch (c) {
                case OPT_PORT:
                    serverPort = atoi(optarg);
                    if (serverPort <= 0 || serverPort > 65535) {
                        fprintf(stderr,"Invalid port\n");
                        return 1;
                    }
                    break;
                case OPT_HOST:
                    serverHost = [NSString stringWithUTF8String:optarg];
                    break;
                case OPT_LOG:
                    logFilePath = [NSString stringWithUTF8String:optarg];
                    break;
                case OPT_HELP:
                default:
                    printUsage();
                    return 1;
            }
        }

        if (logFilePath) {
            const char *filePathCStr = [logFilePath UTF8String];
            if (freopen(filePathCStr, "w", stderr) == NULL) {
                perror("Failed to redirect stderr");
            } else {
                setvbuf(stderr, NULL, _IOLBF, 0);
            }
        } else {
            setvbuf(stderr, NULL, _IOLBF, 0);
            setvbuf(stdout, NULL, _IOLBF, 0);
        }

        [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
             dispatch_async(dispatch_get_main_queue(), ^{
                 switch (status) {
                     case SFSpeechRecognizerAuthorizationStatusAuthorized:
                         NSLog(@"Speech recognition authorized.");
                         break;
                     case SFSpeechRecognizerAuthorizationStatusDenied:
                         NSLog(@"Speech recognition authorization denied.");
                         break;
                     case SFSpeechRecognizerAuthorizationStatusRestricted:
                         NSLog(@"Speech recognition restricted on this device.");
                         break;
                     case SFSpeechRecognizerAuthorizationStatusNotDetermined:
                         NSLog(@"Speech recognition not determined.");
                         break;
                 }
                 if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
                      NSLog(@"Error: Speech Recognition must be authorized first. Enable it in System Settings > Privacy & Security > Speech Recognition for this application. Exiting.");
                     exit(1);
                 }
            });
        }];


        int serverSock; struct sockaddr_in serverAddr;
        serverSock = socket(AF_INET, SOCK_STREAM, 0);
        if (serverSock < 0) { perror("socket creation failed"); return 1; }
        int reuse = 1; setsockopt(serverSock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
        int flags = fcntl(serverSock, F_GETFL, 0);
        if (flags == -1 || fcntl(serverSock, F_SETFL, flags | O_NONBLOCK) == -1) {
            perror("fcntl failed to set non-blocking on listener"); close(serverSock); return 1;
        }
        signal(SIGPIPE, SIG_IGN);
        NSLog(@"Server socket created (%d), set SO_REUSEADDR and O_NONBLOCK.", serverSock);

        memset(&serverAddr, 0, sizeof(serverAddr)); serverAddr.sin_family = AF_INET;
        serverAddr.sin_addr.s_addr = [serverHost isEqualToString:@"0.0.0.0"] ? htonl(INADDR_ANY) : inet_addr([serverHost UTF8String]);
        if (serverAddr.sin_addr.s_addr == INADDR_NONE && ![serverHost isEqualToString:@"0.0.0.0"]) {
            fprintf(stderr,"Invalid host address: %s\n", [serverHost UTF8String]); close(serverSock); return 1;
        }
        serverAddr.sin_port = htons(serverPort);
        if (bind(serverSock, (struct sockaddr *)&serverAddr, sizeof(serverAddr)) < 0) {
            perror("bind failed"); close(serverSock); return 1;
        }
        if (listen(serverSock, 128) < 0) {
            perror("listen failed"); close(serverSock); return 1;
        }
        NSLog(@"Socket bound to %@:%d and listening.", serverHost, serverPort);

        dispatch_queue_t clientHandlerQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        dispatch_source_t acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, serverSock, 0, dispatch_get_main_queue());
        if (!acceptSource) {
            perror("dispatch_source_create failed"); close(serverSock); return 1;
        }

        dispatch_source_set_event_handler(acceptSource, ^{
            unsigned long pendingConnections = dispatch_source_get_data(acceptSource);
            for (unsigned long i = 0; i < pendingConnections; ++i) {
                struct sockaddr_in clientAddr; socklen_t clientAddrLen = sizeof(clientAddr);
                int clientSock = accept(serverSock, (struct sockaddr *)&clientAddr, &clientAddrLen);
                if (clientSock < 0) {
                    if (errno != EAGAIN && errno != EWOULDBLOCK) {
                        perror("accept failed in dispatch source");
                    }
                    break;
                } else {
                    char clientIpStr[INET_ADDRSTRLEN]; inet_ntop(AF_INET, &clientAddr.sin_addr, clientIpStr, INET_ADDRSTRLEN); int clientPortNum = ntohs(clientAddr.sin_port);
                     NSLog(@"(MainQ) Accepted connection %d from %s:%d. Dispatching to handler queue.", clientSock, clientIpStr, clientPortNum);
                    dispatch_async(clientHandlerQueue, ^{ handleConnection(clientSock, clientAddr); });
                }
            }
        });
        dispatch_source_set_cancel_handler(acceptSource, ^{
            NSLog(@"(MainQ) Accept source cancelled.");
            close(serverSock);
        });
        dispatch_resume(acceptSource);

        NSLog(@"Starting main run loop...");
        [[NSRunLoop currentRunLoop] run];

        dispatch_source_cancel(acceptSource);
        NSLog(@"Server shutting down (RunLoop exited).");
    }
    return 0;
}
