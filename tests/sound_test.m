// Self-check for the core logic. Runs on every build; needs no permission and no
// audio device. With a path argument it also checks that real pack.

#include "../src/sound.m"  // for the private ring, without a test hook in the shipped code

static int failures, checks;

#define CHECK(cond)                                                \
    do {                                                           \
        checks++;                                                  \
        if (!(cond)) {                                             \
            failures++;                                            \
            fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #cond); \
        }                                                          \
    } while (0)

enum { kRate = 48000, kMsFrames = kRate / 1000 };

static NSString *gDir;

// A WAV whose sample at frame f, in both channels, is 100 + f % 29000: never silent.
static NSData *makeWav(uint16_t format, uint16_t channels, uint16_t bits, uint32_t frames) {
    NSMutableData *wav = [NSMutableData data];
    void (^add)(const void *, size_t) = ^(const void *p, size_t n) {
        [wav appendBytes:p length:n];
    };
    uint32_t dataBytes = frames * 4, riffSize = 36 + dataBytes, fmtSize = 16, rate = kRate;
    uint32_t byteRate = kRate * 4;
    uint16_t align = 4;
    add("RIFF", 4), add(&riffSize, 4), add("WAVE", 4), add("fmt ", 4), add(&fmtSize, 4);
    add(&format, 2), add(&channels, 2), add(&rate, 4), add(&byteRate, 4), add(&align, 2), add(&bits, 2);
    add("data", 4), add(&dataBytes, 4);
    for (uint32_t f = 0; f < frames; f++) {
        int16_t sample = (int16_t)(100 + f % 29000);
        add(&sample, 2), add(&sample, 2);
    }
    return wav;
}

static NSString *loadPack(NSString *json, NSData *wav) {
    [json writeToFile:[gDir stringByAppendingPathComponent:@"config.json"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    if (wav) [wav writeToFile:[gDir stringByAppendingPathComponent:@"a.wav"] atomically:NO];
    return KSLoadPack(gDir);
}

static bool clipIs(KSClip clip, uint32_t startMs, uint32_t lengthMs) {
    return clip.start == startMs * kMsFrames && clip.frames == lengthMs * kMsFrames;
}

static void testPackErrors(void) {
    NSData *good = makeWav(1, 2, 16, kRate);
    NSString *okJson = @"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"defines\":{\"30\":[0,100]}}";

    CHECK(loadPack(okJson, good) == nil);
    CHECK(loadPack(@"not json", good) != nil);
    CHECK(loadPack(@"[1]", good) != nil);
    CHECK(loadPack(@"{\"key_define_type\":\"multi\",\"sound\":\"a.wav\",\"defines\":{\"30\":[0,100]}}", good) != nil);
    CHECK(loadPack(@"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"defines\":{}}", good) != nil);
    CHECK(loadPack(@"{\"key_define_type\":\"single\",\"sound\":\"none.wav\",\"defines\":{\"30\":[0,100]}}", good) != nil);
    CHECK(loadPack(@"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"defines\":{\"30\":[900,200]}}", good) != nil);
    CHECK(loadPack(@"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"defines\":{\"30\":[-5,100]}}", good) != nil);
    CHECK(loadPack(@"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"defines\":{\"30\":[0]}}", good) != nil);
    CHECK(loadPack(@"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"defines\":{\"30\":[\"0\",1]}}", good) != nil);

    CHECK(loadPack(okJson, makeWav(3, 2, 16, kRate)) != nil);  // float
    CHECK(loadPack(okJson, makeWav(1, 1, 16, kRate)) != nil);  // mono
    CHECK(loadPack(okJson, makeWav(1, 2, 24, kRate)) != nil);  // 24-bit
    CHECK(loadPack(okJson, [@"RIFFxxxxWAVE" dataUsingEncoding:NSASCIIStringEncoding]) != nil);
    CHECK(loadPack(okJson, [NSData data]) != nil);
    // Cut off inside the header: chunk sizes point past the end of the file.
    CHECK(loadPack(okJson, [good subdataWithRange:NSMakeRange(0, 30)]) != nil);
    // Cut off inside the samples: clips past the real end must be refused.
    CHECK(loadPack(okJson, [good subdataWithRange:NSMakeRange(0, 44 + 40 * kMsFrames)]) != nil);
}

static void testKeyMap(void) {
    NSString *json = @"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"defines\":{"
                     @"\"30\":[0,10],\"57\":[10,20],\"28\":[30,30],\"14\":[60,40],\"1\":[100,50],"
                     @"\"42\":[150,60],\"54\":[210,70],\"58\":[280,80],\"57416\":[360,90],\"3667\":[450,10],"
                     @"\"56\":null}}";
    CHECK(loadPack(json, makeWav(1, 2, 16, kRate)) == nil);

    CHECK(clipIs(KSClipForKey(kVK_ANSI_A), 0, 10));
    CHECK(clipIs(KSClipForKey(kVK_Space), 10, 20));
    CHECK(clipIs(KSClipForKey(kVK_Return), 30, 30));
    CHECK(clipIs(KSClipForKey(kVK_Delete), 60, 40));
    CHECK(clipIs(KSClipForKey(kVK_Escape), 100, 50));
    CHECK(clipIs(KSClipForKey(kVK_Shift), 150, 60));
    CHECK(clipIs(KSClipForKey(kVK_RightShift), 210, 70));
    CHECK(clipIs(KSClipForKey(kVK_CapsLock), 280, 80));
    CHECK(clipIs(KSClipForKey(kVK_UpArrow), 360, 90));
    CHECK(clipIs(KSClipForKey(kVK_ForwardDelete), 450, 10));

    // Keys the pack does not define all fall back to the letter clip.
    CHECK(clipIs(KSClipForKey(kVK_ANSI_B), 0, 10));
    CHECK(clipIs(KSClipForKey(kVK_Command), 0, 10));
    CHECK(clipIs(KSClipForKey(kVK_Option), 0, 10));  // null entry
    CHECK(clipIs(KSClipForKey(kVK_ISO_Section), 0, 10));  // not in the numbering at all
    CHECK(clipIs(KSClipForKey(127), 0, 10));
    CHECK(clipIs(KSClipForKey(60000), 0, 10));  // out of the table

    // No letter key in the pack: still one fixed clip.
    CHECK(loadPack(@"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"defines\":{\"57\":[5,6]}}", nil) == nil);
    CHECK(clipIs(KSClipForKey(kVK_ANSI_A), 5, 6));
}

static void testRotation(void) {
    // Three distinct letter and digit clips, one of them defined twice.
    NSString *json = @"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"defines\":{"
                     @"\"30\":[0,10],\"31\":[10,10],\"2\":[20,10],\"32\":[0,10],"
                     @"\"57\":[100,10],\"28\":[200,10],\"14\":[300,10],\"12\":[400,10]}}";
    CHECK(loadPack(json, makeWav(1, 2, 16, kRate)) == nil);
    CHECK(gPoolCount == 3);

    // The same key walks through the clips, and comes back after a full round.
    KSClip first = KSClipForKey(kVK_ANSI_A), second = KSClipForKey(kVK_ANSI_A), third = KSClipForKey(kVK_ANSI_A);
    CHECK(first.start != second.start && second.start != third.start && first.start != third.start);
    CHECK(KSClipForKey(kVK_ANSI_A).start == first.start);

    // Different keys share one walk: the clip says nothing about which key it was.
    CHECK(KSClipForKey(kVK_ANSI_Q).start == second.start);  // not in the pack, still rotates
    CHECK(KSClipForKey(kVK_ANSI_1).start == third.start);
    CHECK(KSClipForKey(kVK_ANSI_Keypad5).start == first.start);

    // Space, Return and Delete keep their own sound, and do not move the walk.
    for (int i = 0; i < 5; i++) {
        CHECK(clipIs(KSClipForKey(kVK_Space), 100, 10));
        CHECK(clipIs(KSClipForKey(kVK_Return), 200, 10));
        CHECK(clipIs(KSClipForKey(kVK_Delete), 300, 10));
    }
    CHECK(clipIs(KSClipForKey(kVK_ANSI_Minus), 400, 10));  // punctuation stays as the pack says
    CHECK(KSClipForKey(kVK_ANSI_A).start == second.start);

    // Reloading does not keep the old pool.
    CHECK(loadPack(@"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"defines\":{\"30\":[50,10]}}", nil) == nil);
    CHECK(gPoolCount == 1 && clipIs(KSClipForKey(kVK_ANSI_S), 50, 10));
}

static void testMousePack(void) {
    NSData *wav = makeWav(1, 2, 16, kRate);  // one second
    NSMutableData *click = [makeWav(1, 2, 16, kMsFrames * 20) mutableCopy];
    memset((uint8_t *)click.mutableBytes + 44, 0, 48 * 4);  // 1 ms of silence up front
    NSString *path = [gDir stringByAppendingPathComponent:@"m.wav"];
    [click writeToFile:path atomically:NO];

    NSString *json = @"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"mouse_sound\":\"m.wav\",\"defines\":{\"30\":[0,10]}}";
    CHECK(loadPack(json, wav) == nil);
    CHECK(gMouse.start == kRate + 48 && gMouse.frames == kMsFrames * 20 - 48);  // after the keys, trimmed
    CHECK(gPCM[(size_t)gMouse.start * 2] == 100 + 48);                           // really the mouse samples
    CHECK(gPCM[0] == 100);                                                        // and the keys are untouched
    CHECK(gMouse.mouse && !KSClipForKey(kVK_ANSI_A).mouse);                       // each follows its own volume

    // Clips cannot reach into the mouse sound by pointing past the key audio.
    CHECK(loadPack(@"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"mouse_sound\":\"m.wav\",\"defines\":{\"30\":[990,20]}}", wav) != nil);

    // A plain Mechvibes pack has no mouse sound: the letter clip stands in.
    CHECK(loadPack(@"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"defines\":{\"30\":[10,10]}}", wav) == nil);
    CHECK(gMouse.start == 10 * kMsFrames && gMouse.frames == 10 * kMsFrames);
    CHECK(gMouse.mouse && !gFallback.mouse && !KSClipForKey(kVK_ANSI_A).mouse);  // the borrowed clip stays the mouse's

    CHECK(loadPack(@"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"mouse_sound\":\"none.wav\",\"defines\":{\"30\":[0,10]}}", wav) != nil);
    CHECK(loadPack(@"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"mouse_sound\":3,\"defines\":{\"30\":[0,10]}}", wav) != nil);

    uint32_t otherRate = 44100;
    [click replaceBytesInRange:NSMakeRange(24, 4) withBytes:&otherRate];
    [click writeToFile:path atomically:NO];
    CHECK(loadPack(json, wav) != nil);
}

static void testMouseUpPack(void) {
    NSData *wav = makeWav(1, 2, 16, kRate);  // one second
    NSMutableData *release = [makeWav(1, 2, 16, kMsFrames * 20) mutableCopy];
    memset((uint8_t *)release.mutableBytes + 44, 0, 96 * 4);  // 2 ms of silence up front
    NSString *path = [gDir stringByAppendingPathComponent:@"u.wav"];
    [release writeToFile:path atomically:NO];
    [makeWav(1, 2, 16, kMsFrames * 10) writeToFile:[gDir stringByAppendingPathComponent:@"m.wav"] atomically:NO];
    NSString *both = @"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"mouse_sound\":\"m.wav\",\"mouse_up_sound\":\"u.wav\",\"defines\":{\"30\":[0,10]}}";
    NSString *upOnly = @"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"mouse_up_sound\":\"u.wav\",\"defines\":{\"30\":[10,10]}}";

    // Both: the press sound as before, the release sound after it and trimmed the same way.
    CHECK(loadPack(both, wav) == nil);
    CHECK(gMouse.start == kRate && gMouse.frames == kMsFrames * 10);
    CHECK(gMouseUp.start == kRate + kMsFrames * 10 + 96 && gMouseUp.frames == kMsFrames * 20 - 96);
    CHECK(gPCM[(size_t)gMouseUp.start * 2] == 100 + 96);                     // really the release samples
    CHECK(gAudio.length == (size_t)(gMouseUp.start + gMouseUp.frames) * 4);  // and it ends with the buffer
    CHECK(gMouseUp.mouse);                                                   // the mouse volume, like the press

    // Alone: the press still falls back to the letter clip, the release has its own sound.
    CHECK(loadPack(upOnly, wav) == nil);
    CHECK(gMouse.start == 10 * kMsFrames && gMouse.frames == 10 * kMsFrames);
    CHECK(gMouseUp.start == kRate + 96 && gMouseUp.frames == kMsFrames * 20 - 96);

    // Clips cannot reach into it by pointing past the key audio.
    CHECK(loadPack(@"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"mouse_up_sound\":\"u.wav\",\"defines\":{\"30\":[990,20]}}", wav) != nil);

    // None: nothing is queued and the output is not started. Loading also clears the last pack's sound.
    CHECK(loadPack(upOnly, wav) == nil && gMouseUp.frames > 0);
    CHECK(loadPack(@"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"defines\":{\"30\":[10,10]}}", wav) == nil);
    CHECK(gMouseUp.frames == 0);
    uint32_t head = atomic_load(&gHead);
    KSPlayMouseUp(kCGMouseButtonLeft);
    CHECK(atomic_load(&gHead) == head && !gRunning);

    // Bad names and bad files stop the load, the same as for the press sound.
    CHECK(loadPack(@"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"mouse_up_sound\":\"none.wav\",\"defines\":{\"30\":[0,10]}}", wav) != nil);
    CHECK([loadPack(@"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"mouse_up_sound\":3,\"defines\":{\"30\":[0,10]}}", wav) containsString:@"mouse_up_sound"]);
    [makeWav(3, 2, 16, kRate) writeToFile:path atomically:NO];  // float
    CHECK(loadPack(upOnly, wav) != nil);
    [makeWav(1, 1, 16, kRate) writeToFile:path atomically:NO];  // mono
    CHECK(loadPack(upOnly, wav) != nil);
    [[release subdataWithRange:NSMakeRange(0, 30)] writeToFile:path atomically:NO];  // cut off in the header
    CHECK(loadPack(upOnly, wav) != nil);
    uint32_t otherRate = 44100;
    [release replaceBytesInRange:NSMakeRange(24, 4) withBytes:&otherRate];
    [release writeToFile:path atomically:NO];
    CHECK([loadPack(upOnly, wav) containsString:@"mouse_up_sound"]);
}

static bool anyReleaseHeld(void) {
    for (int b = 0; b < kButtons; b++) {
        if (gReleaseDue[b]) return true;
    }
    return false;
}

// The clock is passed in here. Nothing plays: every release is taken or dropped by the test.
static void testReleaseGap(void) {
    static const uint64_t ms = 1000000;
    const CGMouseButton left = kCGMouseButtonLeft, right = kCGMouseButtonRight, center = kCGMouseButtonCenter;
    uint64_t t = 5000 * ms;

    // A tap: the release 3 ms after the press sounds 90 ms after it, once.
    notePress(left, t);
    uint64_t due = holdRelease(left, t + 3 * ms);
    CHECK(due == t + 90 * ms);
    CHECK(takeRelease(due) == left);
    CHECK(takeRelease(due) == -1);

    // A slow click sounds at once and leaves nothing waiting. Exactly on the gap counts as slow.
    notePress(left, t);
    CHECK(holdRelease(left, t + 150 * ms) == 0);
    CHECK(holdRelease(left, t + 90 * ms) == 0);
    CHECK(holdRelease(left, t + 90 * ms - 1) == t + 90 * ms);
    CHECK(takeRelease(t + 90 * ms) == left && !anyReleaseHeld());

    // A new press drops the waiting release. Its timer, left running, finds nothing even
    // with a newer release waiting, which keeps its own 90 ms from the new press.
    notePress(left, t);
    due = holdRelease(left, t + 3 * ms);
    notePress(left, t + 50 * ms);
    CHECK(!anyReleaseHeld());
    CHECK(takeRelease(due) == -1);
    uint64_t newer = holdRelease(left, t + 53 * ms);
    CHECK(newer == t + 140 * ms);
    CHECK(takeRelease(due) == -1);
    CHECK(takeRelease(newer) == left);

    // Switching the mouse sound off drops every waiting release.
    notePress(left, t);
    notePress(right, t + 1 * ms);
    uint64_t dueLeft = holdRelease(left, t + 3 * ms), dueRight = holdRelease(right, t + 4 * ms);
    CHECK(dueLeft && dueRight);
    KSDropHeldMouseUps();
    CHECK(!anyReleaseHeld() && takeRelease(dueLeft) == -1 && takeRelease(dueRight) == -1);

    // Buttons stay apart: each counts from its own press, and pressing one drops no other.
    notePress(left, t);
    dueLeft = holdRelease(left, t + 3 * ms);
    notePress(right, t + 10 * ms);
    dueRight = holdRelease(right, t + 13 * ms);
    notePress(center, t + 20 * ms);
    CHECK(dueLeft == t + 90 * ms && dueRight == t + 100 * ms);
    CHECK(takeRelease(dueRight) == right && takeRelease(dueLeft) == left);

    // A waking output starts the press sound late. The timer asks again and waits the rest,
    // counted from the real start, so the gap is real on a cold tap too.
    notePress(left, t);
    due = holdRelease(left, t + 3 * ms);
    CHECK(due == t + 90 * ms);
    atomic_store(&gPressStarted[left], t + 20 * ms);
    CHECK(takeRelease(due) == left);
    CHECK(holdRelease(left, due) == t + 110 * ms);
    CHECK(takeRelease(t + 110 * ms) == left);
    CHECK(holdRelease(left, t + 110 * ms) == 0);

    // The note of an earlier press says nothing about this one, and no note at all waits only
    // from the press: a press the output never played cannot hold its release forever.
    notePress(left, t + 500 * ms);
    CHECK(holdRelease(left, t + 503 * ms) == t + 590 * ms);
    CHECK(holdRelease(left, t + 590 * ms) == 0);
    CHECK(takeRelease(t + 590 * ms) == left);
    atomic_store(&gPressStarted[left], 0);

    // A release with no press on record, say the mouse sound came on while a button was down.
    memset(gPressedAt, 0, sizeof gPressedAt);
    CHECK(holdRelease(left, t) == 0);

    // Another app can post any button number: it must stay inside the tables.
    notePress(kButtons + 1, t);
    CHECK(gPressedAt[1] == t);
    notePress(UINT32_MAX, t + 1);
    CHECK(gPressedAt[kButtons - 1] == t + 1);

    // Through the real call, on the real clock: a release right after its press only waits.
    NSString *pack = @"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"mouse_up_sound\":\"u.wav\",\"defines\":{\"30\":[0,10]}}";
    [makeWav(1, 2, 16, kMsFrames * 20) writeToFile:[gDir stringByAppendingPathComponent:@"u.wav"] atomically:NO];
    CHECK(loadPack(pack, makeWav(1, 2, 16, kRate)) == nil);

    // The note comes from the render thread, when the clip really starts.
    _Atomic uint64_t noted = 0;
    float out[20];
    pushClip((KSClip){0, 10, true, &noted});
    CHECK(atomic_load(&noted) == 0);
    uint64_t before = nowNs();
    KSRender(out, 10);
    CHECK(atomic_load(&noted) >= before);

    uint32_t head = atomic_load(&gHead);
    notePress(left, nowNs());
    KSPlayMouseUp(left);
    CHECK(atomic_load(&gHead) == head && !gRunning && gReleaseDue[left] != 0);
    KSDropHeldMouseUps();  // its timer never fires here: nothing runs the main queue

    // A pack with no release sound: nothing waits and nothing queues, however soon it comes.
    CHECK(loadPack(@"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"defines\":{\"30\":[0,10]}}", nil) == nil);
    notePress(left, nowNs());
    KSPlayMouseUp(left);
    CHECK(atomic_load(&gHead) == head && !gRunning && !anyReleaseHeld());
}

static void testSilenceTrim(void) {
    NSString *json = @"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"defines\":{\"30\":[0,100],\"57\":[100,100]}}";
    NSMutableData *wav = [makeWav(1, 2, 16, kRate) mutableCopy];
    memset((uint8_t *)wav.mutableBytes + 44, 0, 240 * 4);                      // 5 ms before the first click
    memset((uint8_t *)wav.mutableBytes + 44 + 100 * kMsFrames * 4, 0, 100 * kMsFrames * 4);  // a clip with nothing in it
    CHECK(loadPack(json, wav) == nil);

    KSClip clip = KSClipForKey(kVK_ANSI_A);
    CHECK(clip.start == 240 && clip.frames == 100 * kMsFrames - 240);  // the end is untouched
    clip = KSClipForKey(kVK_Space);
    CHECK(clip.frames == 1);  // all silent: stays a valid, harmless clip
}

static void testPressRules(void) {
    CHECK(KSIsPress(kCGEventKeyDown, false, kVK_ANSI_A, 0));
    CHECK(!KSIsPress(kCGEventKeyDown, true, kVK_ANSI_A, 0));  // auto-repeat
    CHECK(!KSIsPress(kCGEventKeyUp, false, kVK_ANSI_A, 0));

    struct { uint16_t key; uint64_t bit; } modifiers[] = {
        {kVK_Shift, 0x2}, {kVK_RightShift, 0x4}, {kVK_Control, 0x1}, {kVK_RightControl, 0x2000},
        {kVK_Option, 0x20}, {kVK_RightOption, 0x40}, {kVK_Command, 0x8}, {kVK_RightCommand, 0x10},
        {kVK_Function, kCGEventFlagMaskSecondaryFn},
    };
    for (size_t i = 0; i < sizeof modifiers / sizeof *modifiers; i++) {
        CHECK(KSIsPress(kCGEventFlagsChanged, false, modifiers[i].key, modifiers[i].bit));
        CHECK(!KSIsPress(kCGEventFlagsChanged, false, modifiers[i].key, 0));
    }
    // Right shift released while left shift is held: not a press.
    CHECK(!KSIsPress(kCGEventFlagsChanged, false, kVK_RightShift, 0x2));
    CHECK(KSIsPress(kCGEventFlagsChanged, false, kVK_CapsLock, 0));
    CHECK(!KSIsPress(kCGEventFlagsChanged, false, kVK_ANSI_A, 0xFFFF));

    CHECK(KSIsMouseDown(kCGEventLeftMouseDown));
    CHECK(KSIsMouseDown(kCGEventRightMouseDown));
    CHECK(KSIsMouseDown(kCGEventOtherMouseDown));
    CHECK(!KSIsMouseDown(kCGEventLeftMouseUp));
    CHECK(!KSIsMouseDown(kCGEventRightMouseUp));
    CHECK(!KSIsMouseDown(kCGEventOtherMouseUp));
    CHECK(!KSIsMouseDown(kCGEventLeftMouseDragged));
    CHECK(!KSIsMouseDown(kCGEventRightMouseDragged));
    CHECK(!KSIsMouseDown(kCGEventOtherMouseDragged));
    CHECK(!KSIsMouseDown(kCGEventMouseMoved));
    CHECK(!KSIsMouseDown(kCGEventScrollWheel));
    CHECK(!KSIsMouseDown(kCGEventKeyDown));

    CHECK(KSIsMouseUp(kCGEventLeftMouseUp));
    CHECK(KSIsMouseUp(kCGEventRightMouseUp));
    CHECK(KSIsMouseUp(kCGEventOtherMouseUp));
    CHECK(!KSIsMouseUp(kCGEventLeftMouseDown));
    CHECK(!KSIsMouseUp(kCGEventRightMouseDown));
    CHECK(!KSIsMouseUp(kCGEventOtherMouseDown));
    CHECK(!KSIsMouseUp(kCGEventLeftMouseDragged));
    CHECK(!KSIsMouseUp(kCGEventMouseMoved));
    CHECK(!KSIsMouseUp(kCGEventKeyUp));
}

// Renders until all clips have ended so the next test starts silent.
static void drain(void) {
    float buffer[2 * 4800];
    for (int i = 0; i < 20; i++) KSRender(buffer, 4800);
}


static void testMixer(void) {
    CHECK(loadPack(@"{\"key_define_type\":\"single\",\"sound\":\"a.wav\",\"defines\":{\"30\":[0,10]}}",
                   makeWav(1, 2, 16, kRate)) == nil);
    drain();
    KSSetVolume(100);

    enum { kFrames = 480 };
    float out[2 * kFrames * 2];
    KSClip clip = {1000, 480, false, NULL};
    pushClip(clip);
    KSRender(out, kFrames / 2);
    KSRender(out + kFrames, kFrames / 2);  // a clip continues across render calls
    bool exact = true;
    for (int f = 0; f < kFrames; f++) {
        float want = (float)(1100 + f) / 32768.f;
        exact = exact && fabsf(out[f * 2] - want) < 1e-5f && fabsf(out[f * 2 + 1] - want) < 1e-5f;
    }
    CHECK(exact);
    KSRender(out, 100);
    CHECK(out[0] == 0 && out[199] == 0);  // ended cleanly

    // Overlapping clips add up instead of cutting each other off.
    pushClip((KSClip){1000, 100, false, NULL});
    pushClip((KSClip){2000, 100, false, NULL});
    KSRender(out, 100);
    CHECK(fabsf(out[0] - 3200.f / 32768.f) < 1e-5f);

    // Volume is applied (50% is a quarter of the amplitude).
    drain();
    KSSetVolume(50);
    pushClip((KSClip){8000, 10, false, NULL});
    KSRender(out, 10);
    CHECK(fabsf(out[0] - 2025.f / 32768.f) < 1e-5f);
    KSSetVolume(0);
    pushClip((KSClip){8000, 10, false, NULL});
    KSRender(out, 10);
    CHECK(out[0] == 0);

    // Keys and mouse each follow their own volume. The mouse borrows the letter clip in this
    // pack, so the samples are the same and only the volume can tell them apart.
    drain();
    KSSetVolume(100);
    KSSetMouseVolume(50);
    KSClip key = KSClipForKey(kVK_ANSI_A);
    pushClip(key);
    KSRender(out, 10);
    float loud = out[0];
    CHECK(loud > 0);
    drain();
    pushClip(gMouse);
    KSRender(out, 10);
    CHECK(fabsf(out[0] - loud / 4) < 1e-7f);

    // Muting one leaves the other, also when both sound in one buffer.
    drain();
    KSSetMouseVolume(0);
    pushClip(key);
    pushClip(gMouse);
    KSRender(out, 10);
    CHECK(fabsf(out[0] - loud) < 1e-7f);
    drain();
    KSSetVolume(0);
    KSSetMouseVolume(100);
    pushClip(key);
    pushClip(gMouse);
    KSRender(out, 10);
    CHECK(fabsf(out[0] - loud) < 1e-7f);

    // A slider moved while a clip plays reaches that clip at the next buffer.
    KSSetMouseVolume(0);
    KSRender(out, 10);
    CHECK(out[0] == 0);

    // The sum is clamped, never wraps. Sample 28100 ten times is far over full scale.
    drain();
    KSSetVolume(100);
    for (int i = 0; i < 10; i++) pushClip((KSClip){28000, 10, false, NULL});
    KSRender(out, 10);
    CHECK(out[0] == 1.f);

    // More presses than voices: nothing crashes and the extra ones are dropped.
    drain();
    for (int i = 0; i < 1000; i++) {
        pushClip((KSClip){0, 100, false, NULL});
        if (i % 20 == 0) KSRender(out, 10);
    }
    drain();
    KSRender(out, 10);
    CHECK(out[0] == 0);
}

static void testPrefs(void) {
    NSString *suite = @"plastikey.selftest";
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults removePersistentDomainForName:suite];

    KSPrefs first = KSLoadPrefs(defaults);
    CHECK(first.enabled && first.mouseEnabled && first.volume == 50 && first.mouseVolume == 50);

    KSSavePrefs(defaults, (KSPrefs){false, true, 75, 20});
    KSPrefs again = KSLoadPrefs([[NSUserDefaults alloc] initWithSuiteName:suite]);
    CHECK(!again.enabled && again.mouseEnabled && again.volume == 75 && again.mouseVolume == 20);

    KSSavePrefs(defaults, (KSPrefs){true, false, 37, 61});
    again = KSLoadPrefs([[NSUserDefaults alloc] initWithSuiteName:suite]);
    CHECK(again.enabled && !again.mouseEnabled && again.volume == 37 && again.mouseVolume == 61);  // every value, not only steps

    [defaults setInteger:900 forKey:@"volume"];
    CHECK(KSLoadPrefs(defaults).volume == 100 && KSLoadPrefs(defaults).mouseVolume == 61);
    [defaults setInteger:-3 forKey:@"volume"];
    CHECK(KSLoadPrefs(defaults).volume == 0 && KSLoadPrefs(defaults).mouseVolume == 61);
    [defaults setInteger:900 forKey:@"mouseVolume"];
    CHECK(KSLoadPrefs(defaults).mouseVolume == 100 && KSLoadPrefs(defaults).volume == 0);
    [defaults setInteger:-3 forKey:@"mouseVolume"];
    CHECK(KSLoadPrefs(defaults).mouseVolume == 0);

    // Prefs from before the split have only "volume": the mouse starts there, in range.
    [defaults removeObjectForKey:@"mouseVolume"];
    [defaults setInteger:30 forKey:@"volume"];
    again = KSLoadPrefs(defaults);
    CHECK(again.volume == 30 && again.mouseVolume == 30);
    [defaults setInteger:900 forKey:@"volume"];
    CHECK(KSLoadPrefs(defaults).mouseVolume == 100);

    // Once saved the two stand apart: moving the keyboard volume leaves the mouse where it was.
    KSSavePrefs(defaults, again);
    again.volume = 80;
    KSSavePrefs(defaults, again);
    again = KSLoadPrefs(defaults);
    CHECK(again.volume == 80 && again.mouseVolume == 30);
    [defaults removePersistentDomainForName:suite];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        gDir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:gDir withIntermediateDirectories:YES attributes:nil error:NULL];

        testPackErrors();
        testKeyMap();
        testRotation();
        testMousePack();
        testMouseUpPack();
        testReleaseGap();
        testSilenceTrim();
        testPressRules();
        testMixer();
        testPrefs();
        [NSFileManager.defaultManager removeItemAtPath:gDir error:NULL];

        if (argc > 1) {
            NSString *error = KSLoadPack(@(argv[1]));
            if (error) {
                fprintf(stderr, "sound pack: %s\n", error.UTF8String);
                failures++;
            }
            checks++;
            // Whatever pack this is: letters rotate, Space stays, and the mouse has a sound.
            if (gPoolCount > 1) {
                CHECK(KSClipForKey(kVK_ANSI_A).start != KSClipForKey(kVK_ANSI_A).start);
            }
            CHECK(KSClipForKey(kVK_Space).start == KSClipForKey(kVK_Space).start);
            CHECK(gMouse.frames > 0);
        }
        printf("%d checks, %d failed\n", checks, failures);
    }
    return failures != 0;
}
