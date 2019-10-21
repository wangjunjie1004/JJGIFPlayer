//
//  JJTimer.m
//  Test
//
//  Created by wjj on 2019/10/18.
//  Copyright © 2019 wjj. All rights reserved.
//

#import "JJTimer.h"
#import "JJQueue.h"

@interface JJTimer ()
{
    dispatch_source_t _timer;
    NSTimeInterval _timeout;
    NSTimeInterval _timeoutDate;
    bool _repeat;
    dispatch_block_t _completion;
    dispatch_queue_t _nativeQueue;
}

@end

@implementation JJTimer

- (instancetype)initWithTimeout:(NSTimeInterval)timeout repeat:(bool)repeat completion:(dispatch_block_t)completion queue:(JJQueue *)queue
{
    return [self initWithTimeout:timeout repeat:repeat completion:completion nativeQueue:queue.dispatch_queue];
}

- (instancetype)initWithTimeout:(NSTimeInterval)timeout repeat:(bool)repeat completion:(dispatch_block_t)completion nativeQueue:(dispatch_queue_t)nativeQueue
{
    self = [super init];
    if (self) {
        _timeoutDate = INT_MAX;
        
        _timeout = timeout;
        _repeat = repeat;
        _completion = completion;
        _nativeQueue = nativeQueue;
    }
    return self;
}

- (void)dealloc
{
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}

- (void)start
{
    _timeoutDate = CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970 + _timeout;
    
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _nativeQueue);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_timeout * NSEC_PER_SEC)), _repeat ? (int64_t)(_timeout * NSEC_PER_SEC) : DISPATCH_TIME_FOREVER, 0);
    
    dispatch_source_set_event_handler(_timer, ^{
        if (self->_completion) {
            self->_completion();
        }
        if (!self->_repeat) {
            [self invalidate];
        }
    });
    dispatch_resume(_timer);
}

- (void)invalidate
{
    _timeoutDate = 0;
    
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}

- (void)fireAndInvalidate
{
    if (_completion) {
        _completion();
    }
    
    [self invalidate];
}

@end
