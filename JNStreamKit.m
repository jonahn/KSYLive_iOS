//
//  JNStreamKit.m
//  Dandanjia
//
//  Created by Jonathan on 2017/5/10.
//  Copyright © 2017年 xiandanjia.com. All rights reserved.
//

#import "JNStreamKit.h"

#import <libksygpulive/libksygpulive.h>

static void *kJNStreamKitRootViewFrameChange = &kJNStreamKitRootViewFrameChange;

@interface JNStreamKit ()

@property (strong, nonatomic) dispatch_queue_t capDevQueue;

@property (strong, nonatomic) KSYAVFCapture     *videoCapture;
@property (strong, nonatomic) KSYAUAudioCapture *audioCapture;

@property (strong, nonatomic) GPUImageOutput<GPUImageInput>* beautyFilter;
@property (strong, nonatomic) GPUImageOutput<GPUImageInput>* dnoiseFilter;

@property (strong, nonatomic) KSYGPUPicInput  *gpuInput;
@property (strong, nonatomic) KSYGPUPicOutput *gpuOutput;
@property (strong, nonatomic) KSYGPUPicInput  *externalDisplayInput; //外部预览输入 接管预览

@property (strong, nonatomic) KSYAudioMixer  *audioMixer;
@property (strong, nonatomic) KSYGPUPicMixer *videoMixer;

@property (strong, nonatomic) KSYStreamerBase *streamer;
@property (assign, nonatomic) BOOL streamReconnecting;

@property (assign, nonatomic) BOOL audioUnused;

@property (assign, nonatomic) int videoMixLayer;

@property (weak, nonatomic)   UIView *displayInView;

@property (assign, nonatomic) CGFloat initialOrientRotate; //刚创建时方向
@end


@implementation JNStreamKit
- (instancetype)init
{
    self = [super init];
    if (self) {
        [self setupVariables];
        [self setupNotifications];
        [self setupVideoSource];
        [self setupAudioSource];
        [self setupStreamer];
    }
    return self;
}

- (void)setupVariables
{
    _capPreset = AVCaptureSessionPreset1280x720;
    _cameraPosition = AVCaptureDevicePositionFront;
    _videoFPS = 15;
    _streamDimension = CGSizeMake(360, 640);
    _frontMirrored = YES;
    
    _streamReconnecting = NO;
    
    _audioUnused = NO;
    
    _videoMixLayer = 1;
}
- (void)setupNotifications
{
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onNetEvent) name:KSYNetStateEventNotification object:nil];
}

- (void)setupAudioSource
{
    _audioCapture = [[KSYAUAudioCapture alloc] init];
    _audioMixer = [[KSYAudioMixer alloc] init];
    
    __weak typeof(self) weakSelf = self;
    _audioCapture.audioProcessingCallback = ^(CMSampleBufferRef sampleBuffer) {
        [weakSelf handleOriginalAudioBuffer:sampleBuffer];
    };
    
    _audioMixer.audioProcessingCallback = ^(CMSampleBufferRef sampleBuffer) {
        [weakSelf handleAudioOutputBuffer:sampleBuffer];
    };
    _audioMixer.mainTrack = 0;
    [_audioMixer setTrack:0 enable:YES];
    
    [[AVAudioSession sharedInstance] setDefaultCfg];
    [AVAudioSession sharedInstance].bInterruptOtherAudio = NO;
}

- (void)setupVideoSource
{
    _displayImageView = [[GPUImageView alloc] init];
    _displayImageView.fillMode = kGPUImageFillModePreserveAspectRatioAndFill;
    _displayImageView.backgroundColor = [UIColor blackColor];
    
    _videoCapture = [[KSYAVFCapture alloc] initWithSessionPreset:self.capPreset cameraPosition:_cameraPosition];
    _videoCapture.outputPixelFmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    _videoCapture.frameRate = _videoFPS;
    
    _gpuInput  = [[KSYGPUPicInput alloc] initWithFmt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange];
    _gpuOutput = [[KSYGPUPicOutput alloc] initWithOutFmt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange];
    _gpuOutput.bCustomOutputSize = YES;
    _gpuOutput.outputSize = _streamDimension;
    
    __weak typeof(self) weakSelf = self;
    _videoCapture.videoProcessingCallback = ^(CMSampleBufferRef sampleBuffer){
        [weakSelf handleOriginalVideoBuffer:sampleBuffer];
    };
    
    _gpuOutput.videoProcessingCallback = ^(CVPixelBufferRef pixelBuffer, CMTime timeInfo) {
        [weakSelf handleVideoOutputBuffer:pixelBuffer timeInfo:timeInfo];
    };
    
    //filter
    _dnoiseFilter = [[KSYGPUDnoiseFilter alloc] init];
    
    _videoMixer = [[KSYGPUPicMixer alloc] init];
    _videoMixer.masterLayer = self.videoMixLayer;
    
    [_videoMixer addTarget:_displayImageView];
    [_videoMixer addTarget:_gpuOutput];
    
    [_dnoiseFilter addTarget:_videoMixer atTextureLocation:self.videoMixLayer];
    
    [_gpuInput addTarget:_dnoiseFilter];
}

- (void)setupStreamer
{
    _streamer = [[KSYStreamerBase alloc] initWithDefaultCfg];
    
    __weak typeof(self) weakSelf = self;
    _streamer.streamStateChange = ^(KSYStreamState state) {
        if (state == KSYStreamStateError) {
            KSYStreamErrorCode errCode = weakSelf.streamer.streamErrorCode;
            if (errCode == KSYStreamErrorCode_CONNECT_BREAK ||
                errCode == KSYStreamErrorCode_AV_SYNC_ERROR ||
                errCode == KSYStreamErrorCode_Connect_Server_failed ||
                errCode == KSYStreamErrorCode_DNS_Parse_failed ||
                errCode == KSYStreamErrorCode_CODEC_OPEN_FAILED) {
                if (!weakSelf.streamReconnecting){
                    [weakSelf tryReconnect];
                }
            }
        }
        else if(state == KSYStreamStateConnected) {
            weakSelf.streamReconnecting = NO;
        }
        if (weakSelf.onStreamStateChange) {
            weakSelf.onStreamStateChange(state);
        }
    };

    _streamer.videoFPSChange = ^(int newVideoFPS){
        weakSelf.videoFPS = newVideoFPS;
    };


}
- (void)setBeautyFilter:(GPUImageOutput<GPUImageInput> *) filter
{
    _beautyFilter = filter;

    if (filter) {
        [self.gpuInput removeAllTargets];
        [self.gpuInput addTarget:filter];
        [filter addTarget:self.videoMixer atTextureLocation:self.videoMixLayer];
    }
    else{
        [self.gpuInput removeAllTargets];
        [self.dnoiseFilter addTarget:self.videoMixer atTextureLocation:self.videoMixLayer];
        [self.gpuInput addTarget:self.dnoiseFilter];
    }
}

- (void)startDisplayInView:(UIView *)rootView
{
    if (self.videoCapture.isRunning || !rootView) {
        return;
    }
    _displayInView = rootView;
    [self addOrientationObserver]; //监听rootView的Frame变化 和 屏幕方向变化 用于屏幕旋转
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.capDevQueue, ^{
        __strong typeof(weakSelf) sSelf = weakSelf;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![rootView.subviews containsObject:sSelf.displayImageView]) {
                [rootView addSubview:sSelf.displayImageView];
                [rootView sendSubviewToBack:sSelf.displayImageView];
                sSelf.displayImageView.frame = rootView.bounds;
            }
        });
       
        [sSelf.videoCapture startCameraCapture];
        [sSelf.audioCapture startCapture];
    });

}

- (void)stopDisplay
{
    if (!self.videoCapture.isRunning) {
        return;
    }
    [self removeOrientationObserver]; //移除rootView的Frame变化 和 屏幕方向变化 监听
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.capDevQueue, ^{
        __strong typeof(weakSelf) sSelf = weakSelf;
        [sSelf.audioCapture stopCapture];
        [sSelf.videoCapture stopCameraCapture];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (sSelf.displayImageView.superview) {
                [sSelf.displayImageView removeFromSuperview];
            }
        });
    });
}

- (void)startAudioCapture
{
    self.audioUnused = NO;
    [self.audioCapture startCapture];
}

- (void)stopAudioCapture
{
    self.audioUnused = YES;
    [self.audioCapture stopCapture];
}

#pragma mark - dealloc -

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}


#pragma mark - notification -
- (void)appBecomeActive
{
    [self setBeautyFilter:self.beautyFilter];
    if (!self.audioUnused) {
        [self.audioCapture startCapture];
    }
    
    self.gpuOutput.bAutoRepeat = NO;
}

- (void)appEnterBackground
{
    [self.gpuInput removeAllTargets];
    [self.audioCapture stopCapture];
    self.gpuOutput.bAutoRepeat = YES;
    if (self.streamer.bypassRecordState == KSYRecordStateRecording) {
        [self.streamer stopBypassRecord];
    }
}

- (void)onNetEvent
{
    KSYNetStateCode code = [self.streamer netStateCode];
    if (self.networkStateChange) {
        self.networkStateChange(code);
    }
    if (code == KSYNetStateCode_REACHABLE) {
        if ( self.streamer.streamState == KSYStreamStateError) {
            [self tryReconnect];
        }
    }
}
#pragma mark - getter 
- (CGFloat)zoomFactor
{
    return self.videoCapture.inputCamera.videoZoomFactor;
}

- (KSYStreamState)streamState
{
    return self.streamer.streamState;
}

- (dispatch_queue_t)capDevQueue
{
    if (!_capDevQueue) {
        _capDevQueue = dispatch_queue_create( "JNStreamKit.capDevQueue", DISPATCH_QUEUE_SERIAL);
    }
    return _capDevQueue;
}
#pragma mark - setter -
- (void)setCameraPosition:(AVCaptureDevicePosition)cameraPosition
{
    _cameraPosition = cameraPosition;
    if (cameraPosition != [self.videoCapture cameraPosition]) {
        [self.videoCapture rotateCamera];
    }
}

- (void)setStreamDimension:(CGSize)streamDimension
{
    _streamDimension = streamDimension;
    [self.videoMixer removeTarget:self.gpuOutput];
    self.gpuOutput.outputSize = streamDimension;
    [self.videoMixer addTarget:self.gpuOutput];
}

- (void)setFrontMirrored:(BOOL)frontMirrored
{
    _frontMirrored = frontMirrored;
    if (self.videoCapture.cameraPosition == AVCaptureDevicePositionFront) {
        [self.videoMixer setPicRotation:frontMirrored?kGPUImageFlipHorizonal:kGPUImageNoRotation ofLayer:self.videoMixLayer];
    }
}
- (void)setCapPreset:(NSString *)capPreset
{
    _capPreset = capPreset;
    self.videoCapture.captureSessionPreset = capPreset;
}

- (void)setFocusPoint:(CGPoint)focusPoint
{
    _focusPoint = focusPoint;
    [self cameraFocusAtPoint:focusPoint];
}

- (void)setZoomFactor:(CGFloat)zoomFactor
{
    [self cameraZoomFactor:zoomFactor];
}

- (void)setVideoFPS:(int)videoFPS
{
    _videoFPS = MAX(1, MIN(videoFPS, 30));
    self.videoCapture.frameRate = _videoFPS;
    self.streamer.videoFPS = _videoFPS;
}

- (void)setAudiokBPS:(int)audiokBPS
{
    _audiokBPS = audiokBPS;
    self.streamer.audiokBPS = audiokBPS;
}

- (void)setVideoCodec:(KSYVideoCodec)videoCodec
{
    _videoCodec = videoCodec;
    self.streamer.videoCodec = videoCodec;
}

- (void)setVideoInitBitrate:(int)videoInitBitrate
{
    _videoInitBitrate = videoInitBitrate;
    self.streamer.videoInitBitrate = videoInitBitrate;
}

- (void)setVideoMinBitrate:(int)videoMinBitrate
{
    _videoMinBitrate = videoMinBitrate;
    self.streamer.videoMinBitrate = videoMinBitrate;
}

- (void)setVideoMaxBitrate:(int)videoMaxBitrate
{
    _videoMaxBitrate = videoMaxBitrate;
    self.streamer.videoMaxBitrate = videoMaxBitrate;
}
- (void)setStreamLog:(void (^)(NSString *))streamLog
{
    _streamLog = streamLog;
    self.streamer.logBlock = streamLog;
}

#pragma mark - buffer process -

- (void)handleOriginalVideoBuffer:(CMSampleBufferRef)sampleBuffer
{
//    sampleBuffer = [self processOriginalVideoBuffer:sampleBuffer];
//    CVPixelBufferRef cvpBuffer = [self processOriginalVideoBufferToCVP:sampleBuffer];
//    CMTime timeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);//
//    [self.gpuInput processPixelBuffer:cvpBuffer time:timeStamp];
//    CVPixelBufferRelease(cvpBuffer);
    [self.gpuInput processSampleBuffer:sampleBuffer];
}

- (void)handleOriginalAudioBuffer:(CMSampleBufferRef)sampleBuffer
{
    if (self.streamer.isStreaming) {
        [self.audioMixer processAudioSampleBuffer:sampleBuffer of:0];
    }
}

- (void)handleVideoOutputBuffer:(CVPixelBufferRef)pixelBuffer timeInfo:(CMTime)timeInfo
{
    pixelBuffer = [self processOutPutBeforeStreamVideoBuffer:pixelBuffer timeInfo:timeInfo];
    if (self.streamer.isStreaming) {
        [self.streamer processVideoPixelBuffer:pixelBuffer timeInfo:timeInfo];
    }
}

- (void)handleAudioOutputBuffer:(CMSampleBufferRef)sampleBuffer
{
    if (self.streamer.isStreaming) {
        [self.streamer processAudioSampleBuffer:sampleBuffer];
    }
}

- (CVPixelBufferRef)processOutPutBeforeStreamVideoBuffer:(CVPixelBufferRef)pixelBuffer timeInfo:(CMTime)timeInfo
{
    return pixelBuffer;
}

- (CMSampleBufferRef)processOriginalVideoBuffer:(CMSampleBufferRef)sampleBuffer
{
    return sampleBuffer;
}

- (CVPixelBufferRef)processOriginalVideoBufferToCVP:(CMSampleBufferRef)sampleBuffer
{
    CVImageBufferRef ref = CMSampleBufferGetImageBuffer(sampleBuffer);
    return ref;
}
#pragma mark - stream -
- (void)startStreamWithUrl:(NSURL *)url
{
    [self.streamer startStream:url];
}

- (void)stopStream
{
    [self.streamer stopStream];
}

- (void)tryReconnect
{
    if (!self.streamAutoRetry) {
        return;
    }
    self.streamReconnecting = YES;
    [self performSelector:@selector(reconnect) withObject:nil afterDelay:2.0];
}

- (void)reconnect
{
    if (self.streamer.netReachState != KSYNetReachState_Bad) {
        self.streamReconnecting = NO;
        return;
    }
    if (!self.streamer.isStreaming) {
        [self.streamer startStream:self.streamer.hostURL];
    }
    
    self.streamReconnecting = NO;
}

#pragma mark - camera - 
- (void)cameraFocusAtPoint:(CGPoint)point
{
    AVCaptureDevice *dev = self.videoCapture.inputCamera;
    if ([dev isFocusPointOfInterestSupported] && [dev isFocusModeSupported:AVCaptureFocusModeAutoFocus]) {
        NSError *error = nil;
        if ([dev lockForConfiguration:&error]) {
            [dev setFocusMode:AVCaptureFocusModeAutoFocus];
            [dev setFocusPointOfInterest:point];
            [dev unlockForConfiguration];
        }
    }
}

- (void)cameraZoomFactor:(CGFloat)zoomFactor
{
    AVCaptureDevice *captureDevice= self.videoCapture.inputCamera;
    NSError *error = nil;
    [captureDevice lockForConfiguration:&error];
    
    if (!error) {
        captureDevice.videoZoomFactor = zoomFactor;
        [captureDevice unlockForConfiguration];
    }
}

- (AVCaptureDevicePosition)switchCamera
{
    [self.videoCapture rotateCamera];
    return self.videoCapture.cameraPosition;
}

#pragma mark - orientation -

- (void)addOrientationObserver
{
    UIInterfaceOrientation orientation = [UIApplication sharedApplication].statusBarOrientation;
    self.initialOrientRotate = [self orientRadian:orientation];

    //方向变化旋转预览view
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(orientationChange:) name:UIApplicationDidChangeStatusBarOrientationNotification object:nil];
    //重新适应预览位置
    [self.displayInView addObserver:self forKeyPath:NSStringFromSelector(@selector(frame)) options:NSKeyValueObservingOptionNew context:kJNStreamKitRootViewFrameChange];
}

- (void)removeOrientationObserver
{
    @try {
        [self.displayInView removeObserver:self forKeyPath:NSStringFromSelector(@selector(bounds)) context:kJNStreamKitRootViewFrameChange];
    }
    @catch (NSException *exception){
        //        NSLog(@"%@", exception);
    }
    @finally {
        
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidChangeStatusBarOrientationNotification object:nil];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == kJNStreamKitRootViewFrameChange) {
        if (object == self.displayInView) {
            CGRect newFrame = [[change objectForKey:NSKeyValueChangeNewKey] CGRectValue];
            newFrame.origin.x = 0;
            newFrame.origin.y = 0;
            self.displayImageView.frame = newFrame;
        }
    }
}
- (void)orientationChange:(NSNotification *)noti
{
    UIInterfaceOrientation orientation = [UIApplication sharedApplication].statusBarOrientation;
    double previousRadian = [self displayImageViewCurrentTransformRotate];
    double newRadian = [self orientRadian:orientation];// - self.initialOrientRotate;
    double radian = newRadian - previousRadian;
    if (radian) {
        self.displayImageView.transform = CGAffineTransformRotate(self.displayImageView.transform, radian);
    }
}
- (double)orientRadian:(UIInterfaceOrientation)orientation
{
    double radian = 0.0;
    switch (orientation) {
        case UIInterfaceOrientationLandscapeRight:
            radian = -M_PI_2;
            break;
        case UIInterfaceOrientationLandscapeLeft:
            radian = M_PI_2;
            break;
        case UIInterfaceOrientationPortrait:
            radian = 0.0;
            break;
        case UIInterfaceOrientationPortraitUpsideDown:
            radian = M_PI;
            break;
        default:
            break;
    }
    return radian;
}

- (CGFloat)displayImageViewCurrentTransformRotate
{
    CGAffineTransform _trans = self.displayImageView.transform;
    CGFloat rotate = acosf(_trans.a);
    if (_trans.b < 0) {
        rotate = -rotate;
    }
    return rotate;
}


@end
