//
//  JJGIFPlayer.m
//  Test
//
//  Created by wjj on 2019/10/18.
//  Copyright © 2019 wjj. All rights reserved.
//

#import "JJGIFPlayer.h"
#import <CoreMedia/CoreMedia.h>
#import <AVFoundation/AVFoundation.h>
#import <pthread/pthread.h>
#import "JJQueue.h"
#import "JJTimer.h"

static NSMutableDictionary *sessions() {
    static NSMutableDictionary *dict = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dict = [[NSMutableDictionary alloc] init];
    });
    return dict;
}

static int32_t nextSessionId = 0;

@interface JJWeakReference : NSObject

@property (nonatomic, weak)id object;

- (instancetype)initWithObject:(id)object;

@end

@implementation JJWeakReference

- (instancetype)initWithObject:(id)object
{
    self = [super init];
    if (self) {
        self.object = object;
    }
    return self;
}

@end

@interface JJAcceleratedVideoFrame : NSObject {
    
}

@property (nonatomic, readonly) CVImageBufferRef buffer;
@property (nonatomic, readonly) CMTime timestamp;
@property (nonatomic, readonly) CGFloat angle;
@property (nonatomic, readonly) CMSampleBufferRef sampleBuffer;
@property (nonatomic, strong) __attribute__ ((NSObject)) CMFormatDescriptionRef formatDescription;

- (bool)prepareSampleBuffer;

@end

@implementation JJAcceleratedVideoFrame

- (instancetype)initWithBuffer:(CVImageBufferRef)buffer timestamp:(CMTime)timestamp angle:(CGFloat)angle formatDescription:(CMFormatDescriptionRef)formatDescription {
    self = [super init];
    if (self) {
        if (buffer) {
            CFRetain(buffer);
        }
        _timestamp = timestamp;
        _buffer = buffer;
        _angle = angle;
        self.formatDescription = formatDescription;
    }
    return self;
}

- (void)dealloc
{
    if (_buffer) {
        CFRelease(_buffer);
    }
    if (_sampleBuffer) {
        CFRelease(_sampleBuffer);
    }
}

- (bool)prepareSampleBuffer
{
    if (_sampleBuffer) {
        return true;
    }
    
    CMSampleTimingInfo timingInfo;
    timingInfo.presentationTimeStamp = self.timestamp;
    timingInfo.duration = kCMTimeInvalid;
    
    OSStatus error = CMSampleBufferCreateForImageBuffer(NULL, self.buffer, true, nil, nil, self.formatDescription, &timingInfo, &_sampleBuffer);
    return error == noErr;
}

@end

@class JJAcceleratedVideoFrameQueue;
@class JJAcceleratedVideoFrameQueueGuard;

@interface JJAcceleratedVideoFrameQueueItem : NSObject

@property (nonatomic, strong)JJAcceleratedVideoFrameQueue *queue;
@property (nonatomic, strong)NSMutableArray *guards;

@end

@implementation JJAcceleratedVideoFrameQueueItem

- (instancetype)init {
    self = [super init];
    if (self) {
        _guards = [[NSMutableArray alloc] init];
    }
    return self;
}

@end

@interface JJAcceleratedVideoFrameQueueGuardItem : NSObject

@property (nonatomic, weak) JJAcceleratedVideoFrameQueueGuard *guard;
@property (nonatomic, strong) NSObject *key;

@end

@implementation JJAcceleratedVideoFrameQueueGuardItem

- (instancetype)initWithGuard:(JJAcceleratedVideoFrameQueueGuard *)guard key:(NSObject *)key {
    self = [super init];
    if (self) {
        self.guard = guard;
        self.key = key;
    }
    return self;
}

@end

@interface JJAcceleratedVideoFrameQueueGuard : NSObject {
    void (^_draw)(JJAcceleratedVideoFrame *);
    NSString *_path;
}

@property (nonatomic, strong) NSObject *key;

- (instancetype)initWithDraw:(void (^)(JJAcceleratedVideoFrame *))draw path:(NSString *)path;
- (void)draw:(JJAcceleratedVideoFrame *)frame;

@end

@interface JJAcceleratedVideoFrameQueue : NSObject {
    int32_t _sessionId;
    JJQueue *_queue;
    void (^_frameReady)(JJAcceleratedVideoFrame *);
    int64_t _epoch;
    
    NSUInteger _maxFrames;
    NSUInteger _fillFrames;
    CMTime _previousFrameTimestamp;
    
    NSMutableArray *_frames;
    
    JJTimer *_timer;
    
    NSString *_path;
    AVAssetReader *_reader;
    AVAssetReaderTrackOutput *_output;
    CMTimeRange _timeRange;
    bool _failed;
    pthread_mutex_t sessionsLock;
}

@property (nonatomic, strong)NSMutableArray *pendingFrames;
@property (nonatomic, assign)CGFloat angle;
@property (nonatomic, strong) __attribute__((NSObject)) CMFormatDescriptionRef formatDescription;

@end

@implementation JJAcceleratedVideoFrameQueue

- (instancetype)initWithPath:(NSString *)path frameReady:(void (^)(JJAcceleratedVideoFrame *))frameReady
{
    self = [super init];
    if (self) {
        pthread_mutex_init(&sessionsLock, NULL);
        _sessionId = nextSessionId++;
        pthread_mutex_lock(&sessionsLock);
        sessions()[@(_sessionId)] = [[JJWeakReference alloc] initWithObject:self];
        pthread_mutex_unlock(&sessionsLock);
        
        static JJQueue *queue = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            queue = [[JJQueue alloc] init];
        });
        
        _queue = queue;
        
        if ([path hasSuffix:@".gif"]) {
            NSString *movPath = [path stringByReplacingCharactersInRange:NSMakeRange(path.length - 4, 4) withString:@".mp4"];
            [[NSFileManager defaultManager] removeItemAtPath:movPath error:nil];
            [[NSFileManager defaultManager] createSymbolicLinkAtPath:movPath withDestinationPath:path error:nil];
            path = movPath;
        }
        
        _path = path;
        _frameReady = [frameReady copy];
        
        _maxFrames = 2;
        _fillFrames = 1;
        
        _frames = [[NSMutableArray alloc] init];
        _pendingFrames = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc
{
    pthread_mutex_lock(&sessionsLock);
    [sessions() removeObjectForKey:@(_sessionId)];
    pthread_mutex_unlock(&sessionsLock);
    pthread_mutex_destroy(&sessionsLock);
}

- (void)dispatch:(void (^)(void))block
{
    [_queue dispatch:block];
}

- (void)beginRequests {
    [_queue dispatch:^{
        [self->_timer invalidate];
        self->_timer = nil;
        
        [self checkQueue];
    }];
}

- (void)pauseRequests {
    [_queue dispatch:^{
        [self->_timer invalidate];
        self->_timer = nil;
        self->_previousFrameTimestamp = kCMTimeZero;
        [self->_frames removeAllObjects];
        [self->_reader cancelReading];
        self->_output = nil;
        self->_reader = nil;
    }];
}

- (void)checkQueue {
    [_timer invalidate];
    _timer = nil;
    
    NSTimeInterval nextDelay = 0.0;
    
    if (_frames.count != 0) {
        JJAcceleratedVideoFrame *firstFrame = _frames[0];
        [_frames removeObjectAtIndex:0];
        
        int32_t comparsion = CMTimeCompare(firstFrame.timestamp, _previousFrameTimestamp);
        if (comparsion <= 0) {
            nextDelay = 0.05;
        } else {
            nextDelay = MIN(5.0, CMTimeGetSeconds(firstFrame.timestamp) - CMTimeGetSeconds(_previousFrameTimestamp));
        }
        
        _previousFrameTimestamp = firstFrame.timestamp;
        
        comparsion = CMTimeCompare(firstFrame.timestamp, CMTimeMakeWithSeconds(DBL_EPSILON, 1000));
        if (comparsion <= 0) {
            nextDelay = 0.0;
        }
        
        if (_frameReady) {
            _frameReady(firstFrame);
        }
    }
    
    if (_frames.count <= _fillFrames) {
        while (_frames.count < _maxFrames) {
            JJAcceleratedVideoFrame *frame = [self requestFrame];
            if (!frame) {
                if (_failed) {
                    nextDelay = 1.0;
                } else {
                    nextDelay = 0.0;
                }
                break;
            } else {
                [_frames addObject:frame];
            }
        }
    }
    
    __weak JJAcceleratedVideoFrameQueue *weakSelf = self;
    _timer = [[JJTimer alloc] initWithTimeout:nextDelay repeat:false completion:^{
        __strong JJAcceleratedVideoFrameQueue *strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf checkQueue];
        }
    } queue:_queue];
    [_timer start];
}

- (JJAcceleratedVideoFrame *)requestFrame {
    _failed = false;
    for (int i = 0; i < 3; i++) {
        if (_reader == nil) {
            AVURLAsset *asset = [[AVURLAsset alloc] initWithURL:[NSURL fileURLWithPath:_path] options:nil];
            AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
            if (track) {
                _timeRange = track.timeRange;
                CGAffineTransform transform = track.preferredTransform;
                _angle = atan2(transform.b, transform.a);
                
                _output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:@{(NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];
                
                if (_output) {
                    _output.alwaysCopiesSampleData = false;
                    
                    _reader = [[AVAssetReader alloc] initWithAsset:asset error:nil];
                    
                    if ([_reader canAddOutput:_output]) {
                        [_reader addOutput:_output];
                        
                        if (![_reader startReading]) {
                            _reader = nil;
                            _output = nil;
                            _failed = true;
                            return nil;
                        }
                    } else {
                        _reader = nil;
                        _output = nil;
                        _failed = true;
                        return nil;
                    }
                }
            }
        }
        
        if (_reader) {
            CMSampleBufferRef sampleVideo = NULL;
            if (([_reader status] == AVAssetReaderStatusReading) && (sampleVideo = [_output copyNextSampleBuffer])) {
                JJAcceleratedVideoFrame *videoFrame = nil;
                CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleVideo);
                presentationTime.epoch = _epoch;
                
                CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleVideo);
                
                if (self.formatDescription == NULL || CMVideoFormatDescriptionMatchesImageBuffer(self.formatDescription, imageBuffer)) {
                    OSStatus error = noErr;
                    
                    CMVideoFormatDescriptionRef formatDescription;
                    error = CMVideoFormatDescriptionCreateForImageBuffer(NULL, imageBuffer, &formatDescription);
                    if (error == noErr) {
                        self.formatDescription = formatDescription;
                    }
                }
                
                videoFrame = [[JJAcceleratedVideoFrame alloc] initWithBuffer:imageBuffer timestamp:presentationTime angle:_angle formatDescription:self.formatDescription];
                
                CFRelease(sampleVideo);
                return videoFrame;
            } else {
                JJAcceleratedVideoFrame *earliesFrame = nil;
                for (JJAcceleratedVideoFrame *frame in _pendingFrames) {
                    if (earliesFrame == nil || CMTimeCompare(earliesFrame.timestamp, frame.timestamp) == 1) {
                        earliesFrame = frame;
                    }
                }
                
                if (earliesFrame) {
                    [_pendingFrames removeObject:earliesFrame];
                }
                
                if (earliesFrame) {
                    return earliesFrame;
                } else {
                    _epoch++;
                    [_reader cancelReading];
                    _reader = nil;
                    _output = nil;
                }
            }
        }
    }
    return nil;
}

@end

@implementation JJAcceleratedVideoFrameQueueGuard

+ (JJQueue *)controlQueue
{
    static JJQueue *queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = [[JJQueue alloc] init];
    });
    return queue;
}

static NSMutableDictionary *queueItemsByPath() {
    static NSMutableDictionary *dict = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dict = [[NSMutableDictionary alloc] init];
    });
    return dict;
}

+ (void)addGuardForPath:(NSString *)path guard:(JJAcceleratedVideoFrameQueueGuard *)guard {
    NSAssert([[self controlQueue] isCurrentQueue], @"calling addGuardForPath from the wrong queue");
    
    if (path.length == 0) {
        return;
    }
    
    JJAcceleratedVideoFrameQueueItem *item = queueItemsByPath()[path];
    if (!item) {
        item = [[JJAcceleratedVideoFrameQueueItem alloc] init];
        __weak JJAcceleratedVideoFrameQueueItem *weakItem = item;
        item.queue = [[JJAcceleratedVideoFrameQueue alloc] initWithPath:path frameReady:^(JJAcceleratedVideoFrame *frame) {
            [[self controlQueue] dispatch:^{
                __strong JJAcceleratedVideoFrameQueueItem *strongItem = weakItem;
                if (strongItem) {
                    for (NSUInteger i = 0; i < item.guards.count; i++) {
                        JJAcceleratedVideoFrameQueueGuardItem *guardItem = item.guards[i];
                        [guardItem.guard draw:frame];
                    }
                }
            }];
        }];
        queueItemsByPath()[path] = item;
        [item.queue beginRequests];
    }
    
    [item.guards addObject:[[JJAcceleratedVideoFrameQueueGuardItem alloc] initWithGuard:guard key:guard.key]];
}

+ (void)removeGuardFromPath:(NSString *)path key:(NSObject *)key {
    [[self controlQueue] dispatch:^{
        JJAcceleratedVideoFrameQueueItem *item = queueItemsByPath()[path];
        if (item) {
            for (NSInteger i = 0; i < item.guards.count; i++) {
                JJAcceleratedVideoFrameQueueGuardItem *guardItem = item.guards[i];
                if ([guardItem.key isEqual:key] || guardItem.guard == nil) {
                    [item.guards removeObjectAtIndex:i];
                    i--;
                }
            }
            
            if (item.guards.count == 0) {
                [queueItemsByPath() removeObjectForKey:path];
                [item.queue pauseRequests];
            }
        }
    }];
}

- (instancetype)initWithDraw:(void (^)(JJAcceleratedVideoFrame *))draw path:(NSString *)path {
    self = [super init];
    if (self) {
        _draw = [draw copy];
        _key = [NSObject new];
        _path = path;
    }
    return self;
}

- (void)dealloc
{
    [JJAcceleratedVideoFrameQueueGuard removeGuardFromPath:_path key:_key];
}

- (void)draw:(JJAcceleratedVideoFrame *)frame
{
    if (_draw) {
        _draw(frame);
    }
}

@end

@interface JJGIFPlayer ()
{
    NSString *_path;
    JJAcceleratedVideoFrameQueueGuard *_frameQueueGuard;
    bool _inBackground;
    pthread_mutex_t _inBackgroundMutex;
    
    NSMutableArray *_pendingFrames;
    
    int64_t _previousEpoch;
    CGFloat _angle;
    
    AVSampleBufferDisplayLayer *_displayLayer;
}

@end

@implementation JJGIFPlayer

@synthesize videoSize = _videoSize;

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillResignActiveNotification:) name:UIApplicationWillResignActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillResignActiveNotification:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActiveNotification:) name:UIApplicationDidBecomeActiveNotification object:nil];
        
        pthread_mutex_init(&_inBackgroundMutex, NULL);
        
        self.opaque = true;
        _displayLayer = [[AVSampleBufferDisplayLayer alloc] init];
        _displayLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.layer addSublayer:_displayLayer];
        
        _pendingFrames = [[NSMutableArray alloc] init];
        
        if (@available(iOS 11.0, *)) {
            self.accessibilityIgnoresInvertColors = true;
        }
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    NSAssert([NSThread isMainThread], @"dealloc from background thread");
    
    pthread_mutex_destroy(&_inBackgroundMutex);
}

- (void)layoutSubviews
{
    _displayLayer.frame = self.bounds;
}

- (void)applicationWillResignActiveNotification:(id)__unused notification {
    pthread_mutex_lock(&_inBackgroundMutex);
    _inBackground = true;
    pthread_mutex_unlock(&_inBackgroundMutex);
}

- (void)applicationDidBecomeActiveNotification:(id)__unused notification {
    pthread_mutex_lock(&_inBackgroundMutex);
    _inBackground = false;
    pthread_mutex_unlock(&_inBackgroundMutex);
}

- (BOOL)compareString:(NSString *)string1 tag:(NSString *)string2 {
    if (string1.length == 0 && string2.length == 0) {
        return true;
    }
    
    if ((string1 == nil) != (string2 == nil)) {
        return false;
    }
    
    return string1 == nil || [string1 isEqualToString:string2];
}

- (void)prepareForRecycle {
    DispatchAsyncOnMainThread(^{
        [self->_displayLayer flushAndRemoveImage];
        self->_previousEpoch = 0;
    });
}

- (void)displayFrame:(JJAcceleratedVideoFrame *)frame {
    pthread_mutex_lock(&_inBackgroundMutex);
    if (!_inBackground) {
        if (_displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
            [_displayLayer flushAndRemoveImage];
        }
        
        if (_previousEpoch != frame.timestamp.epoch) {
            _previousEpoch = frame.timestamp.epoch;
            [_displayLayer flush];
        }
        
        if ([_displayLayer isReadyForMoreMediaData]) {
            [_displayLayer enqueueSampleBuffer:frame.sampleBuffer];
        }
        
        if (_angle != frame.angle) {
            _angle = frame.angle;
            self.transform = CGAffineTransformMakeRotation(frame.angle);
        }
    }
    
    pthread_mutex_unlock(&_inBackgroundMutex);
}

- (void)setPath:(NSString *)path {
    [[JJAcceleratedVideoFrameQueueGuard controlQueue] dispatch:^{
        NSString *realPath = path;
        if (path != nil && [path pathExtension].length == 0 && [[NSFileManager defaultManager] fileExistsAtPath:path] ) {
            realPath = [path stringByAppendingPathExtension:@"mov"];
            if (![[NSFileManager defaultManager] fileExistsAtPath:realPath]) {
                [[NSFileManager defaultManager] removeItemAtPath:realPath error:nil];
                [[NSFileManager defaultManager] createSymbolicLinkAtPath:realPath withDestinationPath:[path pathComponents].lastObject error:nil];
            }
        }
        
        if (![[NSFileManager defaultManager] fileExistsAtPath:realPath]) {
            realPath = nil;
        }
        
        DispatchAsyncOnMainThread(^{
            if (![self compareString:realPath tag:self->_path]) {
                self->_path = realPath;
                self->_frameQueueGuard = nil;
                if (self->_path.length != 0) {
                    __weak JJGIFPlayer *weakSelf = self;
                    JJAcceleratedVideoFrameQueueGuard *frameQueueGuard = [[JJAcceleratedVideoFrameQueueGuard alloc] initWithDraw:^(JJAcceleratedVideoFrame *frame) {
                        __strong JJGIFPlayer *strongSelf = weakSelf;
                        if (strongSelf) {
                            [frame prepareSampleBuffer];
                            DispatchAsyncOnMainThread(^{
                                [strongSelf displayFrame:frame];
                            });
                        }
                    } path:realPath];
                    
                    self->_frameQueueGuard = frameQueueGuard;
                    [[JJAcceleratedVideoFrameQueueGuard controlQueue] dispatch:^{
                        [JJAcceleratedVideoFrameQueueGuard addGuardForPath:realPath guard:frameQueueGuard];
                    }];
                }
            }
        });
    }];
}

@end
