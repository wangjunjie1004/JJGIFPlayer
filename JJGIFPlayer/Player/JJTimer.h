//
//  JJTimer.h
//  Test
//
//  Created by wjj on 2019/10/18.
//  Copyright © 2019 wjj. All rights reserved.
//

#import <Foundation/Foundation.h>

@class JJQueue;

@interface JJTimer : NSObject

- (instancetype)initWithTimeout:(NSTimeInterval)timeout repeat:(bool)repeat completion:(dispatch_block_t)completion queue:(JJQueue *)queue;
- (instancetype)initWithTimeout:(NSTimeInterval)timeout repeat:(bool)repeat completion:(dispatch_block_t)completion nativeQueue:(dispatch_queue_t)nativeQueue;

- (void)start;
- (void)invalidate;
- (void)fireAndInvalidate;

@end
