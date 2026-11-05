#import "sound.h"

#import <AudioToolbox/AudioToolbox.h>
#import <Carbon/Carbon.h>  // kVK_* key numbers only, nothing is linked
#import <IOKit/hidsystem/IOLLEvent.h>
#import <stdatomic.h>
#import <time.h>

enum {
    kChannels = 2,
    kVoices = 16,
    kRingSize = 32,
    kFallbackCode = 30,  // the A key: unknown keys sound like a letter key
    kSilence = 66,       // -54 dBFS in 16-bit samples
    kButtons = 32,       // macOS numbers mouse buttons 0...31
};

// How long the output stays open after the last key. A stopped output costs
// nothing at idle but makes the next first key slower.
static const uint64_t kHoldNs = 3000000000ull;
static const uint64_t kStallNs = 500000000ull;

// A trackpad tap sends press and release within milliseconds, and the two sounds blur into
// one odd click. The gap was picked by ear from a comparison of gaps.
static const uint64_t kReleaseGapNs = 90000000ull;

// The usual 512 frames miss 20 ms from key to speaker. 320 meets it; going lower costs the
// system audio daemon noticeably more CPU (measured 9% at 320, over 10% at 256).
static const UInt32 kBufferFrames = 320;

// Mechvibes packs number keys by PC scancode (iohook). 0 means no such key in the
// scheme, and those keys use the fallback clip.
static const uint16_t kMechvibesCode[128] = {
    [kVK_Escape] = 1,
    [kVK_ANSI_1] = 2,
    [kVK_ANSI_2] = 3,
    [kVK_ANSI_3] = 4,
    [kVK_ANSI_4] = 5,
    [kVK_ANSI_5] = 6,
    [kVK_ANSI_6] = 7,
    [kVK_ANSI_7] = 8,
    [kVK_ANSI_8] = 9,
    [kVK_ANSI_9] = 10,
    [kVK_ANSI_0] = 11,
    [kVK_ANSI_Minus] = 12,
    [kVK_ANSI_Equal] = 13,
    [kVK_Delete] = 14,
    [kVK_Tab] = 15,
    [kVK_ANSI_Q] = 16,
    [kVK_ANSI_W] = 17,
    [kVK_ANSI_E] = 18,
    [kVK_ANSI_R] = 19,
    [kVK_ANSI_T] = 20,
    [kVK_ANSI_Y] = 21,
    [kVK_ANSI_U] = 22,
    [kVK_ANSI_I] = 23,
    [kVK_ANSI_O] = 24,
    [kVK_ANSI_P] = 25,
    [kVK_ANSI_LeftBracket] = 26,
    [kVK_ANSI_RightBracket] = 27,
    [kVK_Return] = 28,
    [kVK_Control] = 29,
    [kVK_ANSI_A] = 30,
    [kVK_ANSI_S] = 31,
    [kVK_ANSI_D] = 32,
    [kVK_ANSI_F] = 33,
    [kVK_ANSI_G] = 34,
    [kVK_ANSI_H] = 35,
    [kVK_ANSI_J] = 36,
    [kVK_ANSI_K] = 37,
    [kVK_ANSI_L] = 38,
    [kVK_ANSI_Semicolon] = 39,
    [kVK_ANSI_Quote] = 40,
    [kVK_ANSI_Grave] = 41,
    [kVK_Shift] = 42,
    [kVK_ANSI_Backslash] = 43,
    [kVK_ANSI_Z] = 44,
    [kVK_ANSI_X] = 45,
    [kVK_ANSI_C] = 46,
    [kVK_ANSI_V] = 47,
    [kVK_ANSI_B] = 48,
    [kVK_ANSI_N] = 49,
    [kVK_ANSI_M] = 50,
    [kVK_ANSI_Comma] = 51,
    [kVK_ANSI_Period] = 52,
    [kVK_ANSI_Slash] = 53,
    [kVK_RightShift] = 54,
    [kVK_ANSI_KeypadMultiply] = 55,
    [kVK_Option] = 56,
    [kVK_Space] = 57,
    [kVK_CapsLock] = 58,
    [kVK_F1] = 59,
    [kVK_F2] = 60,
    [kVK_F3] = 61,
    [kVK_F4] = 62,
    [kVK_F5] = 63,
    [kVK_F6] = 64,
    [kVK_F7] = 65,
    [kVK_F8] = 66,
    [kVK_F9] = 67,
    [kVK_F10] = 68,
    [kVK_ANSI_KeypadClear] = 69,
    [kVK_ANSI_Keypad7] = 71,
    [kVK_ANSI_Keypad8] = 72,
    [kVK_ANSI_Keypad9] = 73,
    [kVK_ANSI_KeypadMinus] = 74,
    [kVK_ANSI_Keypad4] = 75,
    [kVK_ANSI_Keypad5] = 76,
    [kVK_ANSI_Keypad6] = 77,
    [kVK_ANSI_KeypadPlus] = 78,
    [kVK_ANSI_Keypad1] = 79,
    [kVK_ANSI_Keypad2] = 80,
    [kVK_ANSI_Keypad3] = 81,
    [kVK_ANSI_Keypad0] = 82,
    [kVK_ANSI_KeypadDecimal] = 83,
    [kVK_F11] = 87,
    [kVK_F12] = 88,
    [kVK_ANSI_KeypadEnter] = 3612,
    [kVK_RightControl] = 3613,
    [kVK_ANSI_KeypadDivide] = 3637,
    [kVK_RightOption] = 3640,
    [kVK_Home] = 3655,
    [kVK_PageUp] = 3657,
    [kVK_End] = 3663,
    [kVK_PageDown] = 3665,
    [kVK_Help] = 3666,  // sits where Insert is on PC keyboards
    [kVK_ForwardDelete] = 3667,
    [kVK_Command] = 3675,
    [kVK_RightCommand] = 3676,
    [kVK_UpArrow] = 57416,
    [kVK_LeftArrow] = 57419,
    [kVK_RightArrow] = 57421,
    [kVK_DownArrow] = 57424,
};

typedef struct {
    uint32_t pos, end;
    bool mouse;
} Voice;

static NSData *gAudio;
static const int16_t *gPCM;
static double gSampleRate;
static KSClip gClips[128], gFallback, gMouse;
static KSClip gMouseUp;  // zero frames when the pack has no release sound

// A fixed clip per key would let anyone hearing a recording tell the keys apart, so
// letters and digits take the next clip here, whichever key was pressed.
static KSClip gPool[128];
static uint32_t gPoolCount, gPoolNext;  // main thread only

static Voice gVoices[kVoices];  // render thread only while the output runs
static KSClip gRing[kRingSize];
static _Atomic uint32_t gHead, gTail;
static _Atomic float gKeyGain = 0.25f, gMouseGain = 0.25f;
static _Atomic uint64_t gLastRender;

static AudioUnit gUnit;
static bool gRunning;
static uint64_t gLastKey;

// Main thread only.
static uint64_t gPressedAt[kButtons];
static uint64_t gReleaseDue[kButtons];  // a release held back until this time, 0 for none

static _Atomic uint64_t gPressStarted[kButtons];  // set by the render thread

#ifdef KS_BENCH
void KSBenchVoiceStarted(UInt64 hostTime, const float *out, uint32_t frames);
#endif

static uint64_t nowNs(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

#pragma mark - Pack loading

static uint16_t le16(const uint8_t *p) {
    return (uint16_t)(p[0] | p[1] << 8);
}

static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

// Walks the RIFF chunks. Returns nil and the samples, or a message saying what is wrong.
static NSString *parseWav(NSData *data, NSData **samples, uint32_t *rate) {
    const uint8_t *p = data.bytes;
    size_t n = data.length;
    if (n < 12 || memcmp(p, "RIFF", 4) || memcmp(p + 8, "WAVE", 4)) return @"not a WAV file";

    const uint8_t *fmt = NULL, *pcm = NULL;
    size_t pcmBytes = 0;
    for (size_t off = 12; off + 8 <= n;) {
        uint32_t size = le32(p + off + 4);
        const uint8_t *body = p + off + 8;
        size_t avail = n - off - 8;
        if (!memcmp(p + off, "fmt ", 4) && size >= 16 && avail >= 16) fmt = body;
        if (!memcmp(p + off, "data", 4)) {
            pcm = body;
            pcmBytes = MIN((size_t)size, avail);
        }
        off += 8 + (size_t)size + (size & 1);  // chunks are word aligned
    }
    if (!fmt || !pcm) return @"WAV has no fmt or data chunk";

    bool supported = le16(fmt) == 1 && le16(fmt + 2) == kChannels && le16(fmt + 14) == 16;
    if (!supported) return @"WAV must be 16-bit PCM stereo (convert with afconvert)";
    if (le32(fmt + 4) == 0) return @"WAV has no sample rate";

    size_t frames = MIN(pcmBytes / (kChannels * sizeof(int16_t)), (size_t)UINT32_MAX);
    *samples = [data subdataWithRange:NSMakeRange((size_t)(pcm - p), frames * kChannels * sizeof(int16_t))];
    *rate = le32(fmt + 4);
    return nil;
}

// In memory, not mapped: a page fault on the render thread would glitch the audio.
static NSString *loadWav(NSString *dir, NSString *name, NSData **samples, uint32_t *rate) {
    NSData *file = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:name.lastPathComponent]];
    if (!file) return [NSString stringWithFormat:@"%@ not found", name];
    return parseWav(file, samples, rate);
}

// Letters and digits in the Mechvibes numbering: number row, letter rows, keypad digits.
static bool rotates(uint16_t code) {
    return (code >= 2 && code <= 11) || (code >= 16 && code <= 25) || (code >= 30 && code <= 38) ||
           (code >= 44 && code <= 50) || (code >= 71 && code <= 73) || (code >= 75 && code <= 77) ||
           (code >= 79 && code <= 82);
}

static void addToPool(KSClip clip) {
    for (uint32_t i = 0; i < gPoolCount; i++) {
        if (gPool[i].start == clip.start && gPool[i].frames == clip.frames) return;
    }
    gPool[gPoolCount++] = clip;
}

// Packs often leave silence before each click. Playing it only delays the sound.
static void trimLeadingSilence(KSClip *clip) {
    const int16_t *pcm = gPCM + (size_t)clip->start * kChannels;
    uint32_t skip = 0;
    while (skip + 1 < clip->frames && abs(pcm[skip * kChannels]) < kSilence && abs(pcm[skip * kChannels + 1]) < kSilence) {
        skip++;
    }
    clip->start += skip;
    clip->frames -= skip;
}

// [startMs, lengthMs] to frames. Returns NO for anything malformed or past the end.
static BOOL clipFromEntry(id entry, uint32_t total, KSClip *clip) {
    if (![entry isKindOfClass:NSArray.class] || [entry count] != 2) return NO;
    if (![entry[0] isKindOfClass:NSNumber.class] || ![entry[1] isKindOfClass:NSNumber.class]) return NO;
    double start = [entry[0] doubleValue] * gSampleRate / 1000;
    double frames = [entry[1] doubleValue] * gSampleRate / 1000;
    if (!(start >= 0) || !(frames >= 1) || start + frames > total) return NO;
    *clip = (KSClip){(uint32_t)start, (uint32_t)frames, false, NULL};
    trimLeadingSilence(clip);
    return YES;
}

static uint32_t frameCount(NSData *samples) {
    return (uint32_t)(samples.length / (kChannels * sizeof(int16_t)));
}

// An optional WAV named by `field`, our addition to the format. Leaves *samples nil if absent.
static NSString *loadExtra(NSString *dir, NSDictionary *config, NSString *field, uint32_t rate, NSData **samples) {
    NSString *name = config[field];
    if (!name) return nil;
    if (![name isKindOfClass:NSString.class]) return [field stringByAppendingString:@" is not a file name"];
    uint32_t extraRate = 0;
    NSString *error = loadWav(dir, name, samples, &extraRate);
    if (error) return error;
    return extraRate == rate ? nil : [field stringByAppendingString:@" must have the same sample rate as sound"];
}

NSString *KSLoadPack(NSString *dir) {
    NSData *json = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"config.json"]];
    if (!json) return @"config.json not found";
    NSDictionary *config = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    if (![config isKindOfClass:NSDictionary.class]) return @"config.json is not a JSON object";
    if (![config[@"key_define_type"] isEqual:@"single"]) return @"only key_define_type \"single\" is supported";
    NSDictionary *defines = config[@"defines"];
    NSString *sound = config[@"sound"];
    if (![defines isKindOfClass:NSDictionary.class] || !defines.count) return @"config.json has no defines";
    if (![sound isKindOfClass:NSString.class]) return @"config.json has no sound file name";

    NSData *keys, *mouse, *mouseUp;
    uint32_t rate = 0;
    NSString *error = loadWav(dir, sound, &keys, &rate);
    if (error) return error;
    error = loadExtra(dir, config, @"mouse_sound", rate, &mouse) ?:
            loadExtra(dir, config, @"mouse_up_sound", rate, &mouseUp);
    if (error) return error;

    // One buffer, so a voice stays two offsets and the render thread needs no pointers.
    NSMutableData *audio = [keys mutableCopy];
    uint32_t total = frameCount(keys);
    if (mouse) [audio appendData:mouse];
    if (mouseUp) [audio appendData:mouseUp];
    gAudio = audio;
    gPCM = audio.bytes;
    gSampleRate = rate;

    id fallback = defines[@(kFallbackCode).stringValue];
    if ([fallback isEqual:NSNull.null] || !fallback) {
        NSString *first = [defines.allKeys sortedArrayUsingSelector:@selector(compare:)].firstObject;
        fallback = defines[first];
    }
    if (!clipFromEntry(fallback, total, &gFallback)) return @"fallback key has a bad clip";

    gMouse = gFallback;
    gMouse.mouse = true;  // the borrowed letter clip still follows the mouse volume
    if (mouse.length) {
        gMouse = (KSClip){total, frameCount(mouse), true, NULL};
        trimLeadingSilence(&gMouse);
    }
    gMouseUp = (KSClip){total + frameCount(mouse), frameCount(mouseUp), true, NULL};
    trimLeadingSilence(&gMouseUp);

    gPoolCount = 0;
    for (int key = 0; key < 128; key++) {
        id entry = kMechvibesCode[key] ? defines[@(kMechvibesCode[key]).stringValue] : nil;
        gClips[key] = gFallback;
        if (!entry || entry == NSNull.null) continue;
        if (!clipFromEntry(entry, total, &gClips[key])) {
            return [NSString stringWithFormat:@"key %d has a clip outside the audio", kMechvibesCode[key]];
        }
        if (rotates(kMechvibesCode[key])) addToPool(gClips[key]);
    }
    return nil;
}

KSClip KSClipForKey(uint16_t macKey) {
    if (macKey >= 128) return gFallback;
    if (gPoolCount && rotates(kMechvibesCode[macKey])) return gPool[gPoolNext++ % gPoolCount];
    return gClips[macKey];
}

#pragma mark - Key logic

bool KSIsPress(CGEventType type, bool autorepeat, uint16_t macKey, CGEventFlags flags) {
    if (type == kCGEventKeyDown) return !autorepeat;
    if (type != kCGEventFlagsChanged) return false;

    // Caps Lock reports each toggle once, not press and release.
    if (macKey == kVK_CapsLock) return true;

    // The device bits tell left and right apart, so a release while the other
    // side is still held is not mistaken for a press.
    uint64_t mask;
    switch (macKey) {
        case kVK_Shift: mask = NX_DEVICELSHIFTKEYMASK; break;
        case kVK_RightShift: mask = NX_DEVICERSHIFTKEYMASK; break;
        case kVK_Control: mask = NX_DEVICELCTLKEYMASK; break;
        case kVK_RightControl: mask = NX_DEVICERCTLKEYMASK; break;
        case kVK_Option: mask = NX_DEVICELALTKEYMASK; break;
        case kVK_RightOption: mask = NX_DEVICERALTKEYMASK; break;
        case kVK_Command: mask = NX_DEVICELCMDKEYMASK; break;
        case kVK_RightCommand: mask = NX_DEVICERCMDKEYMASK; break;
        case kVK_Function: mask = kCGEventFlagMaskSecondaryFn; break;
        default: return false;
    }
    return (flags & mask) != 0;
}

bool KSIsMouseDown(CGEventType type) {
    return type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown || type == kCGEventOtherMouseDown;
}

bool KSIsMouseUp(CGEventType type) {
    return type == kCGEventLeftMouseUp || type == kCGEventRightMouseUp || type == kCGEventOtherMouseUp;
}

#pragma mark - Mixer

// Single producer (main thread), single consumer (render thread).
static void pushClip(KSClip clip) {
    uint32_t head = atomic_load_explicit(&gHead, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&gTail, memory_order_acquire);
    if (head - tail == kRingSize) return;
    gRing[head % kRingSize] = clip;
    atomic_store_explicit(&gHead, head + 1, memory_order_release);
}

static void drainRing(void) {
    uint32_t tail = atomic_load_explicit(&gTail, memory_order_relaxed);
    uint32_t head = atomic_load_explicit(&gHead, memory_order_acquire);
    for (; tail != head; tail++) {
        KSClip clip = gRing[tail % kRingSize];
        if (clip.started) atomic_store_explicit(clip.started, nowNs(), memory_order_relaxed);
        for (int v = 0; v < kVoices; v++) {
            if (gVoices[v].pos < gVoices[v].end) continue;
            gVoices[v] = (Voice){clip.start, clip.start + clip.frames, clip.mouse};
            break;
        }
    }
    atomic_store_explicit(&gTail, tail, memory_order_release);
}

void KSRender(float *out, uint32_t frames) {
    drainRing();
    uint32_t samples = frames * kChannels;
    memset(out, 0, samples * sizeof(float));
    float keyGain = atomic_load_explicit(&gKeyGain, memory_order_relaxed) / 32768.f;
    float mouseGain = atomic_load_explicit(&gMouseGain, memory_order_relaxed) / 32768.f;
    for (int v = 0; v < kVoices; v++) {
        Voice *voice = &gVoices[v];
        if (voice->pos >= voice->end) continue;
        uint32_t n = MIN(voice->end - voice->pos, frames);
        const int16_t *src = gPCM + (size_t)voice->pos * kChannels;
        float gain = voice->mouse ? mouseGain : keyGain;
        for (uint32_t i = 0; i < n * kChannels; i++) out[i] += src[i] * gain;
        voice->pos += n;
    }
    for (uint32_t i = 0; i < samples; i++) out[i] = MAX(-1.f, MIN(1.f, out[i]));
}

// Squared so the steps sound even: loudness is not linear in amplitude.
static float gainFor(int percent) {
    float level = percent / 100.f;
    return level * level;
}

void KSSetVolume(int percent) {
    atomic_store_explicit(&gKeyGain, gainFor(percent), memory_order_relaxed);
}

void KSSetMouseVolume(int percent) {
    atomic_store_explicit(&gMouseGain, gainFor(percent), memory_order_relaxed);
}

#pragma mark - Output

static OSStatus renderProc(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time, UInt32 bus,
                           UInt32 frames, AudioBufferList *io) {
    atomic_store_explicit(&gLastRender, nowNs(), memory_order_relaxed);
#ifdef KS_BENCH
    uint32_t before = atomic_load(&gTail);
#endif
    KSRender(io->mBuffers[0].mData, frames);
#ifdef KS_BENCH
    if (atomic_load(&gTail) != before) KSBenchVoiceStarted(time->mHostTime, io->mBuffers[0].mData, frames);
#endif
    return noErr;
}

static void disposeUnit(void) {
    if (!gUnit) return;
    AudioComponentInstanceDispose(gUnit);
    gUnit = NULL;
}

// The default output unit follows the system's current output device by itself
// and converts to whatever rate that device runs at.
static bool createUnit(void) {
    AudioComponentDescription description = {
        .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_DefaultOutput,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
    };
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    if (!component || AudioComponentInstanceNew(component, &gUnit) != noErr) return false;

    AudioStreamBasicDescription format = {
        .mSampleRate = gSampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
        .mBytesPerPacket = kChannels * sizeof(float),
        .mFramesPerPacket = 1,
        .mBytesPerFrame = kChannels * sizeof(float),
        .mChannelsPerFrame = kChannels,
        .mBitsPerChannel = 8 * sizeof(float),
    };
    AURenderCallbackStruct callback = {renderProc, NULL};
    OSStatus status = AudioUnitSetProperty(gUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format,
                                           sizeof format);
    if (status == noErr) {
        status = AudioUnitSetProperty(gUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                                      sizeof callback);
    }
    if (status == noErr) status = AudioUnitInitialize(gUnit);
    if (status != noErr) disposeUnit();
    return status == noErr;
}

// Only with the render thread stopped. Otherwise clips queued for a stalled device
// would all play at once later.
static void clearMixer(void) {
    atomic_store(&gTail, atomic_load(&gHead));
    memset(gVoices, 0, sizeof gVoices);
}

static void stopOutput(void) {
    AudioOutputUnitStop(gUnit);  // returns once the render thread has finished
    gRunning = false;
    clearMixer();
}

static void stopWhenIdle(void *unused) {
    if (!gRunning) return;
    uint64_t idle = nowNs() - gLastKey;
    if (idle >= kHoldNs) {
        stopOutput();
        return;
    }
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHoldNs - idle)), dispatch_get_main_queue(), NULL,
                     stopWhenIdle);
}

static bool startOutput(void) {
    if (!gUnit && !createUnit()) return false;
    // Per start, because the system's output device may have changed since last time.
    // A device that refuses just keeps its own, longer buffer.
    AudioUnitSetProperty(gUnit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &kBufferFrames,
                         sizeof kBufferFrames);
    if (AudioOutputUnitStart(gUnit) != noErr) {
        disposeUnit();
        return false;
    }
    gRunning = true;
    atomic_store(&gLastRender, nowNs());
    stopWhenIdle(NULL);
    return true;
}

static void play(KSClip clip) {
    uint64_t now = nowNs();
    // Render calls stop when a device goes away or the Mac slept mid-burst.
    if (gRunning && now - atomic_load(&gLastRender) > kStallNs) stopOutput();
    gLastKey = now;
    pushClip(clip);  // before starting, so the very first render plays it
    if (!gRunning && !startOutput()) clearMixer();  // the next press tries again
}

void KSPlayKey(uint16_t macKey) {
    play(KSClipForKey(macKey));
}

#pragma mark - Mouse release timing

static void notePress(CGMouseButton button, uint64_t now) {
    gPressedAt[button % kButtons] = now;
    gReleaseDue[button % kButtons] = 0;
}

// Holds the release back if it came too soon and returns when it may sound, otherwise 0.
static uint64_t holdRelease(CGMouseButton button, uint64_t now) {
    uint32_t b = button % kButtons;
    uint64_t started = atomic_load_explicit(&gPressStarted[b], memory_order_relaxed);
    uint64_t due = MAX(gPressedAt[b], started) + kReleaseGapNs;
    if (now >= due) return 0;
    gReleaseDue[b] = due;
    return due;
}

// The time doubles as the timer's ticket: the timer of a dropped release finds nothing,
// even when the same button has a newer release waiting. Returns the button, or -1.
static int takeRelease(uint64_t due) {
    for (int b = 0; b < kButtons; b++) {
        if (gReleaseDue[b] != due) continue;
        gReleaseDue[b] = 0;
        return b;
    }
    return -1;
}

static void retryRelease(void *due);

static void releaseOrWait(CGMouseButton button) {
    uint64_t now = nowNs(), due = holdRelease(button, now);
    if (!due) {
        play(gMouseUp);
        return;
    }
    // One shot, so nothing wakes up unless a release is waiting. Strict because a plain
    // dispatch_after was measured up to 70 ms late on about one tap in twenty.
    dispatch_source_t timer =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(due - now)), DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(timer, ^{
        dispatch_source_cancel(timer);
        retryRelease((void *)due);
    });
    dispatch_resume(timer);
}

// Asks again instead of playing: on a stopped output the press sound starts after the timer was set.
static void retryRelease(void *due) {
    int button = takeRelease((uint64_t)due);
    if (button >= 0) releaseOrWait((CGMouseButton)button);
}

void KSPlayMouse(CGMouseButton button) {
    KSClip clip = gMouse;
    clip.started = &gPressStarted[button % kButtons];
    play(clip);
    notePress(button, nowNs());
}

void KSPlayMouseUp(CGMouseButton button) {
    if (gMouseUp.frames) releaseOrWait(button);
}

void KSDropHeldMouseUps(void) {
    memset(gReleaseDue, 0, sizeof gReleaseDue);
}

#pragma mark - Preferences

static int volumeFrom(NSUserDefaults *defaults, NSString *key) {
    return (int)MAX(0, MIN(100, [defaults integerForKey:key]));
}

KSPrefs KSLoadPrefs(NSUserDefaults *defaults) {
    KSPrefs prefs = {true, true, 50, 50};
    if ([defaults objectForKey:@"enabled"]) prefs.enabled = [defaults boolForKey:@"enabled"];
    if ([defaults objectForKey:@"mouseEnabled"]) prefs.mouseEnabled = [defaults boolForKey:@"mouseEnabled"];
    if ([defaults objectForKey:@"volume"]) prefs.volume = volumeFrom(defaults, @"volume");
    // Before the two volumes split there was one: the mouse keeps sounding as it did.
    prefs.mouseVolume = [defaults objectForKey:@"mouseVolume"] ? volumeFrom(defaults, @"mouseVolume") : prefs.volume;
    return prefs;
}

void KSSavePrefs(NSUserDefaults *defaults, KSPrefs prefs) {
    [defaults setBool:prefs.enabled forKey:@"enabled"];
    [defaults setBool:prefs.mouseEnabled forKey:@"mouseEnabled"];
    [defaults setInteger:prefs.volume forKey:@"volume"];
    [defaults setInteger:prefs.mouseVolume forKey:@"mouseVolume"];
}
