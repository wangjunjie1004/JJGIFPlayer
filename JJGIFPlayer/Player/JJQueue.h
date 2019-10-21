//
//  JJQueue.h
//  Test
//
//  Created by wjj on 2019/10/18.
//  Copyright © 2019 wjj. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface JJQueue : NSObject

+ (JJQueue *)mainQueue;
+ (JJQueue *)concurrentDefaultQueue;
+ (JJQueue *)concurrentBackgroundQueue;

+ (JJQueue *)wrapConcurrentNativeQueue:(dispatch_queue_t)nativeQueue;

- (void)dispatch:(dispatch_block_t)block;
- (void)dispatchSync:(dispatch_block_t)block;
- (void)dispatch:(dispatch_block_t)block synchronous:(bool)synchronous;

- (dispatch_queue_t)dispatch_queue;

- (bool)isCurrentQueue;

void DispatchAsyncOnMainThread(dispatch_block_t block);

void DispatchSyncOnMainThread(dispatch_block_t block);

@end
