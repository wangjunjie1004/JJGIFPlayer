//
//  JJQueue.m
//  Test
//
//  Created by wjj on 2019/10/18.
//  Copyright © 2019 wjj. All rights reserved.
//

#import "JJQueue.h"

static const void *JJQueueSpecificKey = &JJQueueSpecificKey;

@interface JJQueue ()
{
    dispatch_queue_t _queue;
    void *_queueSpecific;
    bool _specialIsMainQueue;
}

@end

@implementation JJQueue

+ (JJQueue *)mainQueue
{
    static JJQueue *queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = [[JJQueue alloc] initWithNativeQueue:dispatch_get_main_queue() queueSpecific:NULL];
        queue->_specialIsMainQueue = true;
    });
    return queue;
}

+ (JJQueue *)concurrentDefaultQueue
{
    static JJQueue *queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = [[JJQueue alloc] initWithNativeQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0) queueSpecific:NULL];
    });
    return queue;
}

+ (JJQueue *)concurrentBackgroundQueue
{
    static JJQueue *queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = [[JJQueue alloc] initWithNativeQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0) queueSpecific:NULL];
    });
    return queue;
}

+ (JJQueue *)wrapConcurrentNativeQueue:(dispatch_queue_t)nativeQueue
{
    return [[JJQueue alloc] initWithNativeQueue:nativeQueue queueSpecific:NULL];
}

- (instancetype)init
{
    dispatch_queue_t queue = dispatch_queue_create(NULL, NULL);
    dispatch_queue_set_specific(queue, JJQueueSpecificKey, (__bridge void *)self, NULL);
    return [self initWithNativeQueue:queue queueSpecific:(__bridge void *)self];
}

- (instancetype)initWithNativeQueue:(dispatch_queue_t)queue queueSpecific:(void *)queueSpecific
{
    self = [super init];
    if (self)
    {
        _queue = queue;
        _queueSpecific = queueSpecific;
    }
    return self;
}

- (dispatch_queue_t)dispatch_queue
{
    return _queue;
}

- (void)dispatch:(dispatch_block_t)block
{
    if (_queueSpecific != NULL && dispatch_get_specific(JJQueueSpecificKey) == _queueSpecific) {
        block();
    } else if (_specialIsMainQueue && [NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(_queue, block);
    }
}

- (void)dispatchSync:(dispatch_block_t)block
{
    if (_queueSpecific != NULL && dispatch_get_specific(JJQueueSpecificKey) == _queueSpecific) {
        @autoreleasepool {
            block();
        }
    } else if (_specialIsMainQueue && [NSThread isMainThread]) {
        @autoreleasepool {
            block();
        }
    } else {
        dispatch_sync(_queue, block);
    }
}

- (void)dispatch:(dispatch_block_t)block synchronous:(bool)synchronous
{
    if (_queueSpecific != NULL && dispatch_get_specific(JJQueueSpecificKey) == _queueSpecific) {
        @autoreleasepool {
            block();
        }
    } else if (_specialIsMainQueue && [NSThread isMainThread]) {
        @autoreleasepool {
            block();
        }
    } else {
        if (synchronous) {
            dispatch_sync(_queue, block);
        } else {
            dispatch_async(_queue, block);
        }
    }
}

- (bool)isCurrentQueue
{
    if (_queueSpecific != NULL && dispatch_get_specific(JJQueueSpecificKey) == _queueSpecific)
        return true;
    else if (_specialIsMainQueue && [NSThread isMainThread])
        return true;
    return false;
}

void DispatchAsyncOnMainThread(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

void DispatchSyncOnMainThread(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

@end
