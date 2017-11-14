//
//  JNStreamKit.h
//  Dandanjia
//
//  Created by Jonathan on 2017/5/10.
//  Copyright © 2017年 xiandanjia.com. All rights reserved.
//

#import <Foundation/Foundation.h>

#import <libksygpulive/libksystreamerengine.h>
#import <libksygpulive/libksygpufilter.h>

@interface JNStreamKit : NSObject

@property (strong, nonatomic, readonly) GPUImageView    *displayImageView;

@property (assign, nonatomic) NSString *capPreset;//AVCaptureSessionPreset1280x720
@property (assign, nonatomic) AVCaptureDevicePosition cameraPosition;
@property (assign, nonatomic) BOOL frontMirrored;
@property (assign, nonatomic) CGSize streamDimension;

@property (strong, nonatomic) void(^networkStateChange)(KSYNetStateCode stateCode);
@property (strong, nonatomic) void(^onStreamStateChange)(KSYStreamState stateCode);
@property (assign, nonatomic) BOOL streamAutoRetry; //自动重连
@property (assign, nonatomic) CGPoint focusPoint; //对焦
@property (assign, nonatomic) CGFloat zoomFactor; //变焦

//for stream
@property (assign, nonatomic) int           videoFPS;
@property (assign, nonatomic) int           audiokBPS;
@property (assign, nonatomic) KSYVideoCodec videoCodec;
@property (assign, nonatomic) int           videoInitBitrate;   // kbit/s of video
@property (assign, nonatomic) int           videoMinBitrate;   // kbit/s of video
@property (assign, nonatomic) int           videoMaxBitrate;   // kbit/s of video

@property (assign ,nonatomic, readonly) KSYStreamState streamState;
@property (strong, nonatomic) void(^streamLog)(NSString *logJson);


- (instancetype)init;

- (void)startDisplayInView:(UIView *)rootView;

- (void)stopDisplay;

- (void)setBeautyFilter:(GPUImageOutput<GPUImageInput> *) filter;

- (void)startAudioCapture;

- (void)stopAudioCapture;


- (void)startStreamWithUrl:(NSURL *)url;

- (void)stopStream;

- (AVCaptureDevicePosition)switchCamera;


//还未经处理的原始数据
- (CMSampleBufferRef)processOriginalVideoBuffer:(CMSampleBufferRef)sampleBuffer;

//
- (CVPixelBufferRef)processOriginalVideoBufferToCVP:(CMSampleBufferRef)sampleBuffer;


//经过所有处理后输出的视频流 继承重写这个方法 在推流前可处理或者使用其他推流推出
- (CVPixelBufferRef)processOutPutBeforeStreamVideoBuffer:(CVPixelBufferRef)pixelBuffer timeInfo:(CMTime)timeInfo;

@end


