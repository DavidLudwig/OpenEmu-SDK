/*
 Copyright (c) 2009, OpenEmu Team

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import <OpenGL/gl.h>

#import "OEGameCore.h"
#import "OEGameCoreController.h"
#import "OEAbstractAdditions.h"
#import "OERingBuffer.h"
#import "OETimingUtils.h"
#import "NSMutableArray+OEQueueAdditions.h"

#ifndef BOOL_STR
#define BOOL_STR(b) ((b) ? "YES" : "NO")
#endif

#define INTERNAL_RUNLOOP 1
#define DYNAMIC_TIMER 1

NSString *const OEGameCoreErrorDomain = @"org.openemu.GameCore.ErrorDomain";

@implementation OEGameCore
{
    NSThread *_internalThread;

    NSMutableArray<dispatch_block_t> *_blockQueue;
    dispatch_semaphore_t _blockQueueSignalSemaphore;
    NSLock *_blockQueueLock;

    void (^_stopEmulationHandler)(void);

    OERingBuffer __strong **ringBuffers;

    OEDiffQueue            *rewindQueue;
    NSUInteger              rewindCounter;

    BOOL                    shouldStop;
    BOOL                    singleFrameStep;
    BOOL                    isRewinding;
    BOOL                    isPausedExecution;

    NSTimeInterval          lastRate;
}

static Class GameCoreClass = Nil;
static NSTimeInterval defaultTimeInterval = 60.0;

+ (void)initialize
{
    if(self == [OEGameCore class])
    {
        GameCoreClass = [OEGameCore class];
    }
}

- (id)init
{
    self = [super init];
    if(self != nil)
    {
        NSUInteger count = [self audioBufferCount];
        ringBuffers = (__strong OERingBuffer **)calloc(count, sizeof(OERingBuffer *));

        _blockQueue = [NSMutableArray array];
        _blockQueueLock = [[NSLock alloc] init];

        _internalThread = [[NSThread alloc] initWithTarget:self selector:@selector(_gameCoreThread:) object:nil];
        [_internalThread start];
    }
    return self;
}

- (void)dealloc
{
    DLog(@"%s", __FUNCTION__);

    for(NSUInteger i = 0, count = [self audioBufferCount]; i < count; i++)
        ringBuffers[i] = nil;

    free(ringBuffers);
}

- (void)dispatchBlock:(void(^)(void))block
{
    [_blockQueueLock lock];
    [_blockQueue pushObject:[block copy]];
    [_blockQueueLock unlock];

    if (_blockQueueSignalSemaphore != nil)
        dispatch_semaphore_signal(_blockQueueSignalSemaphore);
}

- (OERingBuffer *)ringBufferAtIndex:(NSUInteger)index
{
    NSAssert1(index < [self audioBufferCount], @"The index %lu is too high", index);
    if(ringBuffers[index] == nil)
        ringBuffers[index] = [[OERingBuffer alloc] initWithLength:[self audioBufferSizeForBuffer:index] * 16];

    return ringBuffers[index];
}

- (NSString *)pluginName
{
    return [[self owner] pluginName];
}

- (NSString *)biosDirectoryPath
{
    return [[self owner] biosDirectoryPath];
}

- (NSString *)supportDirectoryPath
{
    return [[self owner] supportDirectoryPath];
}

- (NSString *)batterySavesDirectoryPath
{
    return [[self supportDirectoryPath] stringByAppendingPathComponent:@"Battery Saves"];
}

- (BOOL)supportsRewinding
{
    return [[self owner] supportsRewindingForSystemIdentifier:[self systemIdentifier]];
}

- (NSUInteger)rewindInterval
{
    return [[self owner] rewindIntervalForSystemIdentifier:[self systemIdentifier]];
}

- (NSUInteger)rewindBufferSeconds
{
    return [[self owner] rewindBufferSecondsForSystemIdentifier:[self systemIdentifier]];
}

- (OEDiffQueue *)rewindQueue
{
    if(rewindQueue == nil) {
        NSUInteger capacity = ceil(([self frameInterval]*[self rewindBufferSeconds]) / ([self rewindInterval]+1));
        rewindQueue = [[OEDiffQueue alloc] initWithCapacity:capacity];
    }

    return rewindQueue;
}

#pragma mark - Execution

- (void)setupEmulationWithCompletionHandler:(void(^)(void))completionHandler
{
    [self dispatchBlock:^{
        [self setupEmulation];

        if (completionHandler)
            dispatch_async(dispatch_get_main_queue(), completionHandler);
    }];
}

- (void)setupEmulation
{
}

- (void)startEmulationWithCompletionHandler:(void (^)(void))completionHandler
{
    [self dispatchBlock:^{
        [self startEmulation];
        shouldStop = YES;

        if (completionHandler)
            dispatch_async(dispatch_get_main_queue(), completionHandler);
    }];
}

- (void)resetEmulationWithCompletionHandler:(void(^)(void))completionHandler
{
    [self dispatchBlock:^{
        [self resetEmulation];
        if (completionHandler)
            completionHandler();
    }];
}

- (void)stopEmulationWithCompletionHandler:(void (^)(void))completionHandler
{
    [self dispatchBlock:^{
        if (self.hasAlternateRenderingThread)
            [_renderDelegate willRenderFrameOnAlternateThread];
        else
            [_renderDelegate willExecute];

        _stopEmulationHandler = completionHandler;

        shouldStop = YES;
    }];
}

- (void)runStartUpFrameWithCompletionHandler:(void(^)(void))handler
{
    [_renderDelegate willExecute];
    [self executeFrame];
    [_renderDelegate didExecute];

    handler();
}

- (void)_gameCoreThread:(id)backgroundThread
{
    @autoreleasepool {
        shouldStop = NO;
        while (!shouldStop)
            [self dequeueOrWaitForBlockQueue];

        shouldStop = NO;

        OESetThreadRealtime(1. / (_rate * [self frameInterval]), .007, .03); // guessed from bsnes

        uint64_t lastFrameTime = dispatch_time(DISPATCH_TIME_NOW, 0);
        BOOL wasEmulationPaused = YES;

        while (!shouldStop) {
            @autoreleasepool {
                if (_rate == 0) {
                    [self dequeueOrWaitForBlockQueue];
                    wasEmulationPaused = YES;
                    continue;
                }

                if (wasEmulationPaused) {
                    wasEmulationPaused = NO;
                    lastFrameTime = dispatch_time(DISPATCH_TIME_NOW, 0);
                }

                [self _runFrame];

                NSTimeInterval frameDuration = NSEC_PER_SEC / (_rate * [self frameInterval]);

                dispatch_time_t currentTime = dispatch_time(DISPATCH_TIME_NOW, 0);
                dispatch_time_t nextFrameTime = lastFrameTime + frameDuration;

                if (currentTime >= nextFrameTime) {
                    [self dequeueBlocksUntilTime:DISPATCH_TIME_NOW];
                    lastFrameTime = nextFrameTime;
                    continue;
                }

                dispatch_time_t handlingLimit = nextFrameTime - frameDuration * 3.0 / 4.0;

                if (![self dequeueBlocksUntilTime:handlingLimit]) {
                    _blockQueueSignalSemaphore = dispatch_semaphore_create(0);
                    dispatch_time_t semaphoreLimit = nextFrameTime - frameDuration * 2.0 / 3;

                    if (dispatch_semaphore_wait(_blockQueueSignalSemaphore, semaphoreLimit) == 0)
                        [self dequeueBlocksUntilTime:handlingLimit];
                }

                lastFrameTime = nextFrameTime;
                mach_wait_until(lastFrameTime);
            }
        }

        [self stopEmulation];
    }
}

- (BOOL)dequeueBlocksUntilTime:(dispatch_time_t)limit
{
    BOOL didHandleBlock = NO;

    [_blockQueueLock lock];
    dispatch_block_t currentBlock;
    while ((currentBlock = [_blockQueue popObject])) {
        [_blockQueueLock unlock];

        didHandleBlock = YES;

        currentBlock();

        [_blockQueueLock lock];

        if (dispatch_time(DISPATCH_TIME_NOW, 0) >= limit)
            break;
    }
    [_blockQueueLock unlock];

    return didHandleBlock;
}

- (void)dequeueOrWaitForBlockQueue
{
    if ([self dequeueBlocksUntilTime:DISPATCH_TIME_FOREVER])
        return;

    _blockQueueSignalSemaphore = dispatch_semaphore_create(0);
    dispatch_semaphore_wait(_blockQueueSignalSemaphore, DISPATCH_TIME_FOREVER);

    _blockQueueSignalSemaphore = nil;
}

- (void)_runFrame
{
    self.shouldSkipFrame = NO;

    if (!(_rate > 0 || singleFrameStep || isPausedExecution))
        return;

    if (isRewinding) {
        if (singleFrameStep)
            singleFrameStep = isRewinding = NO;

        NSData *state = [[self rewindQueue] pop];
        if (state == nil)
            return;

        [_renderDelegate willExecute];
        [self executeFrame];
        [_renderDelegate didExecute];

        [self deserializeState:state withError:nil];
        return;
    }

    singleFrameStep = NO;
    //OEPerfMonitorObserve(@"executeFrame", gameInterval, ^{

    if([self supportsRewinding] && rewindCounter == 0) {
        NSData *state = [self serializeStateWithError:nil];
        if(state)
            [[self rewindQueue] push:state];
        
        rewindCounter = [self rewindInterval];
    }
    else
        --rewindCounter;
    
    [_renderDelegate willExecute];
    [self executeFrame];
    [_renderDelegate didExecute];
    //});
}

- (void)stopEmulation
{
    [_renderDelegate suspendFPSLimiting];
    DLog(@"Ending thread");

    [self didStopEmulation];
}

- (void)didStopEmulation
{
    if(_stopEmulationHandler != nil) _stopEmulationHandler();
    _stopEmulationHandler = nil;
}

- (void)startEmulation
{
    if ([self class] == GameCoreClass) return;
    if (_rate != 0) return;

    [_renderDelegate resumeFPSLimiting];
    self.rate = 1;
}

#pragma mark - ABSTRACT METHODS

- (void)resetEmulation
{
    [self doesNotImplementSelector:_cmd];
}

- (void)executeFrame
{
    [self doesNotImplementSelector:_cmd];
}

- (BOOL)loadFileAtPath:(NSString *)path
{
    [self doesNotImplementSelector:_cmd];
    return NO;
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated"
    return [self loadFileAtPath:path];
#pragma clang diagnostic pop
}

#pragma mark - Video

// GameCores that render direct to OpenGL rather than a buffer should override this and return YES
// If the GameCore subclass returns YES, the renderDelegate will set the appropriate GL Context
// So the GameCore subclass can just draw to OpenGL
- (BOOL)rendersToOpenGL
{
    return NO;
}

- (OEIntRect)screenRect
{
    return (OEIntRect){ {}, [self bufferSize]};
}

- (OEIntSize)bufferSize
{
    [self doesNotImplementSelector:_cmd];
    return (OEIntSize){};
}

- (OEIntSize)aspectSize
{
    return (OEIntSize){ 4, 3 };
}

- (const void *)videoBuffer
{
    [self doesNotImplementSelector:_cmd];
    return NULL;
}

- (GLenum)pixelFormat
{
    [self doesNotImplementSelector:_cmd];
    return 0;
}

- (GLenum)pixelType
{
    [self doesNotImplementSelector:_cmd];
    return 0;
}

- (GLenum)internalPixelFormat
{
    return GL_RGB;
}

- (BOOL)hasAlternateRenderingThread
{
    return NO;
}

- (BOOL)needsDoubleBufferedFBO
{
    return NO;
}

- (OEGameCoreRendering)gameCoreRendering {
    if ([self respondsToSelector:@selector(rendersToOpenGL)]) {
        return [self rendersToOpenGL] ? OEGameCoreRenderingOpenGL2Video : OEGameCoreRendering2DVideo;
    }

    return OEGameCoreRendering2DVideo;
}

- (const void*)getVideoBufferWithHint:(void *)hint
{
    return [self videoBuffer];
}

- (BOOL)tryToResizeVideoTo:(OEIntSize)size
{
    if (self.gameCoreRendering == OEGameCoreRendering2DVideo)
        return NO;

    return YES;
}

- (CGFloat)numberOfFramesPerSeconds
{
    return self.frameInterval;
}

- (NSTimeInterval)frameInterval
{
    return defaultTimeInterval;
}

- (void)fastForward:(BOOL)flag
{
    if(flag)
    {
        self.rate = 5;
    }
    else
    {
        self.rate = 1;
    }

    [_renderDelegate setEnableVSync:_rate == 1];
//    OESetThreadRealtime(1./(_rate * [self frameInterval]), .007, .03);
}

- (void)rewind:(BOOL)flag
{
    if(flag && [self supportsRewinding] && ![[self rewindQueue] isEmpty])
    {
        isRewinding = YES;
    }
    else
    {
        isRewinding = NO;
    }
}

- (void)setPauseEmulation:(BOOL)paused
{
    if (_rate == 0 && paused)  return;
    if (_rate != 0 && !paused) return;

    // Set rate to 0 and store the previous rate.
    if (paused) {
        lastRate = _rate;
        _rate = 0;
    } else {
        _rate = lastRate;
    }
}

- (BOOL)isEmulationPaused
{
    return _rate == 0;
}

- (void)fastForwardAtSpeed:(CGFloat)fastForwardSpeed;
{
    // FIXME: Need implementation.
}

- (void)rewindAtSpeed:(CGFloat)rewindSpeed;
{
    // FIXME: Need implementation.
}

- (void)slowMotionAtSpeed:(CGFloat)slowMotionSpeed;
{
    // FIXME: Need implementation.
}

- (void)stepFrameForward
{
    singleFrameStep = YES;
}

- (void)stepFrameBackward
{
    singleFrameStep = isRewinding = YES;
}

- (void)setRate:(float)rate
{
    NSLog(@"Rate change %f -> %f", _rate, rate);

    _rate = rate;
}

- (void)beginPausedExecution
{
    if (isPausedExecution == YES) return;

    isPausedExecution = YES;
    [_renderDelegate suspendFPSLimiting];
    [_audioDelegate pauseAudio];
}

- (void)endPausedExecution
{
    if (isPausedExecution == NO) return;

    isPausedExecution = NO;
    [_renderDelegate resumeFPSLimiting];
    [_audioDelegate resumeAudio];
}

#pragma mark - Audio

- (NSUInteger)audioBufferCount
{
    return 1;
}

- (void)getAudioBuffer:(void *)buffer frameCount:(NSUInteger)frameCount bufferIndex:(NSUInteger)index
{
    [[self ringBufferAtIndex:index] read:buffer maxLength:frameCount * [self channelCountForBuffer:index] * sizeof(UInt16)];
}

- (NSUInteger)channelCount
{
    [self doesNotImplementSelector:_cmd];
    return 0;
}

- (double)audioSampleRate
{
    [self doesNotImplementSelector:_cmd];
    return 0;
}

- (NSUInteger)audioBitDepth
{
    return 16;
}

- (NSUInteger)channelCountForBuffer:(NSUInteger)buffer
{
    if(buffer == 0) return [self channelCount];

    NSLog(@"Buffer count is greater than 1, must implement %@", NSStringFromSelector(_cmd));
    [self doesNotImplementSelector:_cmd];
    return 0;
}

- (NSUInteger)audioBufferSizeForBuffer:(NSUInteger)buffer
{
    // 4 frames is a complete guess
    double frameSampleCount = [self audioSampleRateForBuffer:buffer] / [self frameInterval];
    NSUInteger channelCount = [self channelCountForBuffer:buffer];
    NSUInteger bytesPerSample = [self audioBitDepth] / 8;
    NSAssert(frameSampleCount, @"frameSampleCount is 0");
    return channelCount * bytesPerSample * frameSampleCount;
}

- (double)audioSampleRateForBuffer:(NSUInteger)buffer
{
    if(buffer == 0)
        return [self audioSampleRate];

    NSLog(@"Buffer count is greater than 1, must implement %@", NSStringFromSelector(_cmd));
    [self doesNotImplementSelector:_cmd];
    return 0;
}


#pragma mark - Input

- (NSTrackingAreaOptions)mouseTrackingOptions
{
    return 0;
}

#pragma mark - Save state

- (NSData *)serializeStateWithError:(NSError **)outError
{
    return nil;
}

- (BOOL)deserializeState:(NSData *)state withError:(NSError **)outError
{
    return NO;
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void(^)(BOOL success, NSError *error))block
{
    block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreDoesNotSupportSaveStatesError userInfo:nil]);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void(^)(BOOL success, NSError *error))block
{
    block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreDoesNotSupportSaveStatesError userInfo:nil]);
}

#pragma mark - Cheats

- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
}

#pragma mark - Misc

- (void)changeDisplayMode;
{
}

#pragma mark - Discs

- (NSUInteger)discCount
{
    return 1;
}

- (void)setDisc:(NSUInteger)discNumber
{
}

@end
