/* Copyright (C) 2025 by Ubaldo Porcheddu <ubaldo@eja.it> */

#import <Foundation/Foundation.h>

#define VERSION @"1.4.24"
#define NAME @"voice-server"

@interface MultipartPart : NSObject
@property (nonatomic, strong) NSDictionary *headers;
@property (nonatomic, strong) NSData *body;
@property (nonatomic, strong) NSString *name;
@property (nonatomic, strong) NSString *filename;
@end

typedef struct {
    NSString *method;
    NSString *path;
    NSDictionary *headers;
    NSData *body;
    NSString *multipartBoundary;
    NSArray<MultipartPart *> *multipartParts;
} ParsedHttpRequest;

void sendHttpResponse(int clientSock, int code, NSString *desc, NSDictionary *headers, NSData *body);
void sendJsonResponse(int clientSock, int code, NSString* desc, NSDictionary *jsonObj);
void sendErrorResponse(int clientSock, int code, NSString *desc, NSString *msg);
ParsedHttpRequest parseHttpRequest(NSData *requestData);
NSArray* parseMultipartBody(NSData *body, NSString *boundary);
