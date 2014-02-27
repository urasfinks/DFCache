/*
 The MIT License (MIT)
 
 Copyright (c) 2013 Alexander Grebenyuk (github.com/kean).
 
 Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
 
 The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
 
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

#import "DFURLConnectionOperation.h"


NSString *const DFURLConnectionDidStartNotification = @"DFURLConnectionDidStartNotification";
NSString *const DFURLConnectionDidStopNotification = @"DFURLConnectionDidStopNotification";


#pragma mark - _DFURLWrappedRequest

@interface _DFURLWrappedRequest : NSObject <DFURLSessionRequest>

- (id)initWithRequest:(NSURLRequest *)request;

@end

@implementation _DFURLWrappedRequest {
    NSURLRequest *_request;
}

- (id)initWithRequest:(NSURLRequest *)request {
    if (self = [super init]) {
        _request = request;
    }
    return self;
}

- (NSURLRequest *)currentRequest {
    return _request;
}

@end


#pragma mark - DFURLConnectionOperation

@interface DFURLConnectionOperation ()

@property (nonatomic, getter = isExecuting) BOOL executing;
@property (nonatomic, getter = isFinished) BOOL finished;

@end

@implementation DFURLConnectionOperation {
    NSURLRequest *_nativeRequest;
    NSURLResponse *_nativeResponse;
    NSURLConnection *_connection;
    NSMutableData *_responseData;
    NSRecursiveLock *_lock;
}

- (id)initWithSessionRequest:(id<DFURLSessionRequest>)request {
    if (self = [super init]) {
        _lock = [NSRecursiveLock new];
        _request = request;
        _runLoopModes = [NSSet setWithObject:NSRunLoopCommonModes];
        _cachingEnabled = YES;
    }
    return self;
}

- (id)initWithRequest:(NSURLRequest *)request {
    return [self initWithSessionRequest:[[_DFURLWrappedRequest alloc] initWithRequest:request]];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %p> { URL: %@ }", [self class], self, _connection.originalRequest.URL];
}

#pragma mark - Operation

- (BOOL)isConcurrent {
    return YES;
}

- (void)start {
    [self lock];
    if (self.isCancelled) {
        self.finished = YES;
        return;
    }
    self.executing = YES;
    NSURLRequest *request = [_request currentRequest];
    _connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
    if (!_connection) {
        self.executing = NO;
        self.finished = YES;
        return;
    }
    for (NSString *mode in _runLoopModes) {
        [_connection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:mode];
    }
    [_connection start];
    [self __postNotificationWithName:DFURLConnectionDidStartNotification];
    [self unlock];
}

- (void)cancel {
    [self lock];
    if (self.isCancelled) {
        return;
    }
    [super cancel];
    [_connection cancel];
    [self __postNotificationWithName:DFURLConnectionDidStopNotification];
    if (self.isExecuting) {
        self.executing = NO;
        self.finished = YES;
    }
    [self unlock];
}

#pragma mark - <NSURLConnectionDelegate>

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    _nativeResponse = response;
    _responseData = [NSMutableData data];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    [_responseData appendData:data];
    DFURLProgress progress = {
        .bytes = data.length,
        .totalBytes = _responseData.length,
        .totalExpectedBytes = _nativeResponse.expectedContentLength
    };
    [_delegate connectionOperation:self didUpdateProgress:progress];
}

- (void)connection:(NSURLConnection *)connection didSendBodyData:(NSInteger)bytesWritten totalBytesWritten:(NSInteger)totalBytesWritten totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite {
    DFURLProgress progress = {
        .bytes = bytesWritten,
        .totalBytes = totalBytesWritten,
        .totalExpectedBytes = totalBytesExpectedToWrite
    };
    [_delegate connectionOperation:self didUpdateProgress:progress];
}

- (NSCachedURLResponse *)connection:(NSURLConnection *)connection willCacheResponse:(NSCachedURLResponse *)cachedResponse {
    return _cachingEnabled ? cachedResponse : nil;
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            [self _deserializerResponseData:_responseData];
        }
    });
    [self __postNotificationWithName:DFURLConnectionDidStopNotification];
}

- (void)_deserializerResponseData:(NSData *)data {
    NSError *error;
    if (![self __isValidResponse:_nativeResponse error:&error]) {
        _error = error;
        [self __finish];
        return;
    }
    id object = [_deserializer objectFromResponse:_nativeResponse data:_responseData error:&error];
    _error = error;
    _response = [[DFURLSessionResponse alloc] initWithObject:object response:_nativeResponse data:_responseData];
    [self __finish];
}

- (BOOL)__isValidResponse:(NSURLResponse *)response error:(NSError **)error {
    if ([_deserializer respondsToSelector:@selector(isValidResponse:error:)]) {
        return [_deserializer isValidResponse:response error:error];
    }
    return YES;
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    _error = error;
    [self __postNotificationWithName:DFURLConnectionDidStopNotification];
    [self __finish];
}

- (void)__finish {
    [self lock];
    self.executing = NO;
    self.finished = YES;
    if (!self.isCancelled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (_error || !_response.object) {
                [_delegate connectionOperation:self didFailWithError:_error];
            } else {
                [_delegate connectionOperationDidFinish:self];
            }
        });
    }
    [self unlock];
}

#pragma mark - KVO

- (void)setFinished:(BOOL)finished {
    [self willChangeValueForKey:@"isFinished"];
    _finished = finished;
    [self didChangeValueForKey:@"isFinished"];
}

- (void)setExecuting:(BOOL)executing {
    [self willChangeValueForKey:@"isExecuting"];
    _executing = executing;
    [self didChangeValueForKey:@"isExecuting"];
}

#pragma mark - Notifications

- (void)__postNotificationWithName:(NSString *)name {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:name object:self];
    });
}

#pragma mark - <NSLocking>

- (void)lock {
    [_lock lock];
}

- (void)unlock {
    [_lock unlock];
}

@end


@implementation DFURLConnectionOperation (HTTP)

- (NSHTTPURLResponse *)HTTPResponse {
    if ([self.response isKindOfClass:[NSHTTPURLResponse class]]) {
        return (id)self.response;
    }
    return nil;
}

@end