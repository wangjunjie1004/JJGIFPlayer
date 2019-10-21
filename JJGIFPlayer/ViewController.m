//
//  ViewController.m
//  JJGIFPlayer
//
//  Created by wjj on 2019/10/21.
//  Copyright © 2019 wjj. All rights reserved.
//

#import "ViewController.h"
#import "JJGIFPlayer.h"

@interface ViewController ()

@property (nonatomic, strong)JJGIFPlayer *player;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    
    _player = [[JJGIFPlayer alloc] initWithFrame:CGRectMake(50, 100, 184, 320)];
    [self.view addSubview:_player];
    [_player setPath:[[NSBundle mainBundle] pathForResource:@"test" ofType:@"mp4"]];
}


@end
