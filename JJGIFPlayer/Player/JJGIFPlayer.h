//
//  JJGIFPlayer.h
//  Test
//
//  Created by wjj on 2019/10/18.
//  Copyright © 2019 wjj. All rights reserved.
//

#import <UIKit/UIKit.h>

@protocol JJGIFPlayerProtocol <NSObject>

@property (nonatomic) CGSize videoSize;

- (void)setPath:(NSString *)path;
- (void)prepareForRecycle;

@end

@interface JJGIFPlayer : UIView <JJGIFPlayerProtocol>

@end

