// Measurement and state-machine build. This is the real src/main.m with the permission
// check and the event tap replaced, and keys fed in by a timer. Never shipped: only
// tests/measure.sh compiles it. Usage: see tests/measure.sh.
//
// It runs on someone's working Mac, so nothing here may show on screen, take the keyboard
// focus or make a sound: no alert window, no menu bar icon, volume 0 (see keepOutOfTheWay).
#import <Cocoa/Cocoa.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/HostTime.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <sys/resource.h>

#import "../src/sound.h"

static bool gGranted = true, gTapWorks = true;
static int gRequests, gLastVolume = -1, gLastMouseVolume = -1;
static CGEventMask gTapMask;
static CGEventTapOptions gTapOptions;

static CFMachPortRef fakeTap(CGEventTapOptions options, CGEventMask mask) {
    gTapOptions = options;
    gTapMask = mask;
    return gTapWorks ? CFMachPortCreate(NULL, NULL, NULL, NULL) : NULL;
}

#define CGPreflightListenEventAccess() (gGranted)
#define CGRequestListenEventAccess() (gRequests++, false)
#define CGEventTapCreate(tap, place, options, mask, callback, info) fakeTap(options, mask)
// The app's own volume calls are recorded, not played: keys here must stay silent.
#define KSSetVolume(percent) (gLastVolume = (percent), KSSetVolume(0))
#define KSSetMouseVolume(percent) (gLastMouseVolume = (percent), KSSetMouseVolume(0))
#define main app_main
#include "../src/main.m"
#undef main
#undef KSSetVolume
#undef KSSetMouseVolume

#pragma mark - Measurement

enum { kMaxSamples = 20000 };
static _Atomic uint64_t gKeyHost;
static double gPresent[kMaxSamples], gCallback[kMaxSamples];
static _Atomic int gSamples;
static _Atomic int gAudible;
static _Atomic int gClipBuffers;

// Called on the render thread for the buffer in which a new clip starts.
void KSBenchVoiceStarted(UInt64 hostTime, const float *out, uint32_t frames) {
    atomic_fetch_add(&gClipBuffers, 1);
    uint64_t key = atomic_exchange(&gKeyHost, 0);
    if (!key) return;
    int i = atomic_load(&gSamples);
    if (i == kMaxSamples) return;
    gPresent[i] = (double)(AudioConvertHostTimeToNanos(hostTime) - AudioConvertHostTimeToNanos(key)) / 1e6;
    gCallback[i] = (double)(AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()) - AudioConvertHostTimeToNanos(key)) / 1e6;
    for (uint32_t s = 0; s < frames * 2; s++) {
        if (out[s] != 0) {
            atomic_fetch_add(&gAudible, 1);
            break;
        }
    }
    atomic_store(&gSamples, i + 1);
}

static double footprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    return (double)info.phys_footprint / 1048576;
}

static double cpuSeconds(void) {
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    return (double)usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 + (double)usage.ru_stime.tv_sec +
           usage.ru_stime.tv_usec / 1e6;
}

static int compareDoubles(const void *a, const void *b) {
    double d = *(const double *)a - *(const double *)b;
    return d < 0 ? -1 : d > 0;
}

static void printStats(const char *name, double *values, int n, double extraMs) {
    if (!n) {
        printf("%s: no samples\n", name);
        return;
    }
    qsort(values, (size_t)n, sizeof(double), compareDoubles);
    double sum = 0;
    for (int i = 0; i < n; i++) sum += values[i];
    printf("%s (ms, n=%d, device latency %.1f included): min %.1f avg %.1f p95 %.1f max %.1f\n", name, n, extraMs,
           values[0] + extraMs, sum / n + extraMs, values[n * 95 / 100] + extraMs, values[n - 1] + extraMs);
}

// What the device itself reports: frames from the buffer to the speaker.
static double deviceLatencyMs(void) {
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    AudioDeviceID device = 0;
    UInt32 size = sizeof device;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device);

    UInt32 latency = 0, safety = 0, buffer = 0, streamLatency = 0;
    Float64 rate = 0;
    address.mScope = kAudioObjectPropertyScopeOutput;
    address.mSelector = kAudioDevicePropertyLatency;
    size = sizeof latency;
    AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &latency);
    address.mSelector = kAudioDevicePropertySafetyOffset;
    AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &safety);
    address.mSelector = kAudioDevicePropertyBufferFrameSize;
    AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &buffer);
    AudioStreamID stream = 0;
    address.mSelector = kAudioDevicePropertyStreams;
    size = sizeof stream;
    AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &stream);
    address.mSelector = kAudioStreamPropertyLatency;
    size = sizeof streamLatency;
    AudioObjectGetPropertyData(stream, &address, 0, NULL, &size, &streamLatency);
    address.mSelector = kAudioDevicePropertyNominalSampleRate;
    size = sizeof rate;
    AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &rate);

    printf("device: %.0f Hz, buffer %u, device latency %u, stream latency %u, safety offset %u frames\n", rate, buffer,
           latency, streamLatency, safety);
    return (latency + streamLatency) * 1000.0 / rate;
}

// Presses keys at a fixed rate through the same call the event tap uses.
static void runKeys(double rate, int count, int volume, bool mouse) {
    KSSetVolume(volume);
    KSSetMouseVolume(volume);
    __block int sent = 0;
    __block double cpuStart = cpuSeconds();
    uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    printf("footprint before: %.1f MB\n", footprintMB());
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, (uint64_t)(1e9 / rate), 0);
    dispatch_source_set_event_handler(timer, ^{
        static const uint16_t keys[] = {kVK_ANSI_A, kVK_Space, kVK_Return, kVK_ANSI_K, kVK_Delete, kVK_ANSI_E};
        atomic_store(&gKeyHost, AudioGetCurrentHostTime());
        if (mouse) {
            KSPlayMouse(kCGMouseButtonLeft);
        } else {
            KSPlayKey(keys[sent % 6]);
        }
        if (++sent % 2500 == 0) printf("after %d keys: %.1f MB\n", sent, footprintMB());
        if (sent < count) return;
        dispatch_source_cancel(timer);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1e9 / rate) + 300000000), dispatch_get_main_queue(), ^{
            double seconds = (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e9;
            printf("cpu over %.0f s: %.3f%%\n", seconds, (cpuSeconds() - cpuStart) * 100 / seconds);
            double latency = deviceLatencyMs();
            int n = atomic_load(&gSamples);
            printStats("key to output buffer + device latency", gPresent, n, latency);
            printStats("key to render callback", gCallback, n, 0);
            printf("buffers with sound: %d of %d, footprint after: %.1f MB\n", atomic_load(&gAudible), n, footprintMB());
            fflush(stdout);
            exit(0);
        });
    });
    dispatch_resume(timer);
}

#pragma mark - State machine

static int gFailures, gAlertCount;
static NSURL *gOpenedURL;
static NSAlert *gLastAlert;
static NSModalResponse gAnswer = NSAlertSecondButtonReturn;
static void (^gOnAlert)(NSAlert *);

// Alerts answer themselves without a window, Settings stays closed, the app stays in the
// background and its status item never reaches the menu bar.
static void keepOutOfTheWay(void) {
    class_replaceMethod(NSWorkspace.class, @selector(openURL:configuration:completionHandler:),
                        imp_implementationWithBlock(^(id workspace, NSURL *url, id config, id handler) {
                            gOpenedURL = url;
                        }),
                        "v@:@@@");
    class_replaceMethod(NSApplication.class, @selector(activateIgnoringOtherApps:),
                        imp_implementationWithBlock(^(id app, BOOL flag){
                        }),
                        "v@:c");
    class_replaceMethod(NSAlert.class, @selector(runModal),
                        imp_implementationWithBlock(^NSModalResponse(NSAlert *alert) {
                            gLastAlert = alert;
                            gAlertCount++;
                            if (gOnAlert) gOnAlert(alert);
                            return gAnswer;
                        }),
                        "q@:");
    Method statusItem = class_getInstanceMethod(NSStatusBar.class, @selector(statusItemWithLength:));
    NSStatusItem *(*original)(id, SEL, CGFloat) = (void *)method_getImplementation(statusItem);
    method_setImplementation(statusItem, imp_implementationWithBlock(^NSStatusItem *(NSStatusBar *bar, CGFloat length) {
        NSStatusItem *item = original(bar, @selector(statusItemWithLength:), length);
        item.visible = NO;
        return item;
    }));
}

#define CHECK(cond)                                                  \
    do {                                                             \
        if (!(cond)) {                                               \
            gFailures++;                                             \
            printf("FAIL line %d: %s\n", __LINE__, #cond);           \
        }                                                            \
    } while (0)

static void onMain(dispatch_block_t block) {
    dispatch_sync(dispatch_get_main_queue(), block);
}

static void waitFor(BOOL (^condition)(void), double seconds) {
    for (int i = 0; i < seconds * 20; i++) {
        __block BOOL done = NO;
        onMain(^{
            done = condition();
        });
        if (done) return;
        usleep(50000);
    }
}

// Draws into a bitmap of its own. No screen pixels are read: these are not screenshots.
static void savePNG(NSSize size, int scale, NSString *path, void (^draw)(NSRect)) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                    pixelsWide:(NSInteger)size.width * scale
                                                                    pixelsHigh:(NSInteger)size.height * scale
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSCalibratedRGBColorSpace
                                                                   bytesPerRow:0
                                                                  bitsPerPixel:0];
    rep.size = size;
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    draw((NSRect){NSZeroPoint, size});
    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:NO];
}

// A view drawn into a bitmap. Nothing is put on screen and no screen pixels are read.
static void exportView(NSView *view, NSString *path) {
    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    bool dark = [NSApp.appearance.name isEqual:NSAppearanceNameDarkAqua];
    NSColor *background = dark ? [NSColor colorWithWhite:0.17 alpha:1] : NSColor.whiteColor;
    savePNG(view.bounds.size, 2, path, ^(NSRect r) {
        [background setFill];
        NSRectFill(r);
        [rep drawInRect:r];
    });
}

static void exportIcons(NSString *dir) {
    IconBadge badges[] = {IconBadgeNone, IconBadgeSlash, IconBadgePermission};
    NSString *names[] = {@"on", @"off", @"permission"};
    NSString *themes[] = {@"light", @"dark"};
    for (int t = 0; t < 2; t++) {
        NSColor *background = [NSColor colorWithWhite:t ? 0.14 : 0.96 alpha:1];
        NSColor *ink = t ? NSColor.whiteColor : [NSColor colorWithWhite:0 alpha:0.85];
        for (int b = 0; b < 3; b++) {
            NSImage *icon = makeIcon(badges[b]);
            NSImage *tinted = [NSImage imageWithSize:icon.size
                                             flipped:NO
                                      drawingHandler:^BOOL(NSRect r) {
                                          [icon drawInRect:r];
                                          [ink setFill];
                                          NSRectFillUsingOperation(r, NSCompositingOperationSourceIn);
                                          return YES;
                                      }];
            NSSize size = NSMakeSize(icon.size.width + 12, icon.size.height + 6);
            savePNG(size, 6, [dir stringByAppendingFormat:@"/icon-%@-%@.png", names[b], themes[t]], ^(NSRect r) {
                [background setFill];
                NSRectFill(r);
                [tinted drawInRect:NSMakeRect(6, 3, icon.size.width, icon.size.height)];
            });
        }
    }
}

@interface App (Flow)
- (void)checkFlow:(NSString *)exportDir;
@end

@implementation App (Flow)

// Walks every permission state with a fake permission and a fake tap.
- (void)checkFlow:(NSString *)exportDir {
    App *app = self;
    NSString *theme = NSApp.appearance.name ?: @"plain";
    if (exportDir) {
        gOnAlert = ^(NSAlert *alert) {
            alert.window.appearance = NSApp.appearance;
            [alert layout];
            NSString *kind = [alert.messageText isEqual:kTextGuideTitle]       ? @"guide"
                             : [alert.messageText isEqual:kTextReconnectTitle] ? @"reconnect"
                                                                               : @"relaunch";
            exportView(alert.window.contentView, [exportDir stringByAppendingFormat:@"/alert-%@-%@.png", kind, theme]);
        };
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        __block NSString *label, *keyboardTitle, *mouseTitle, *permissionTitle;
        __block BOOL hidden, keyboardEnabled, mouseEnabled;
        dispatch_block_t read = ^{
            label = app->_item.button.accessibilityLabel;
            hidden = app->_permissionItem.hidden;
            permissionTitle = app->_permissionItem.title;
            keyboardTitle = app->_keyboardItem.title;
            mouseTitle = app->_mouseItem.title;
            keyboardEnabled = app->_keyboardItem.enabled;
            mouseEnabled = app->_mouseItem.enabled;
        };
        // The next clip that reaches the output is counted once.
        int (^sounds)(dispatch_block_t) = ^int(dispatch_block_t action) {
            int before = atomic_load(&gSamples);
            atomic_store(&gKeyHost, AudioGetCurrentHostTime());
            onMain(action);
            waitFor(^BOOL { return atomic_load(&gSamples) > before; }, 0.5);
            atomic_store(&gKeyHost, 0);
            return atomic_load(&gSamples) - before;
        };

        // 0. The menu is the agreed one, in order, and has no check marks.
        onMain(^{
            NSArray<NSMenuItem *> *items = app->_item.menu.itemArray;
            CHECK(items.count == 10);
            CHECK([items[0].title isEqual:kTextAppName] && !items[0].enabled);
            CHECK(items[1] == app->_permissionItem && items[2].isSeparatorItem);
            CHECK(items[3] == app->_keyboardItem && app->_keyboardSlider.superview == items[4].view);
            CHECK(items[5].isSeparatorItem);
            CHECK(items[6] == app->_mouseItem && app->_mouseSlider.superview == items[7].view);
            CHECK(items[8].isSeparatorItem);
            CHECK([items[9].title isEqual:kTextQuit] && [items[9].keyEquivalent isEqual:@"q"]);
            for (NSMenuItem *item in items) CHECK(item.state == NSControlStateValueOff);
            CHECK([app->_keyboardSlider.accessibilityLabel isEqual:kTextKeyboardVolume]);
            CHECK([app->_mouseSlider.accessibilityLabel isEqual:kTextMouseVolume]);
            CHECK(app->_keyboardSlider.action == @selector(keyboardVolumeChanged:));
            CHECK(app->_mouseSlider.action == @selector(mouseVolumeChanged:));
            for (NSSlider *slider in @[ app->_keyboardSlider, app->_mouseSlider ]) {
                CHECK(slider.minValue == 0 && slider.maxValue == 100 && slider.continuous);
            }
        });

        // 1. First run, no permission: the plain guide once, [Later] leaves the app waiting.
        waitFor(^BOOL { return gAlertCount == 1; }, 3);
        onMain(^{
            read();
            CHECK(gAlertCount == 1);
            CHECK([gLastAlert.messageText isEqual:kTextGuideTitle]);
            CHECK([gLastAlert.informativeText isEqual:kTextGuideBody]);
            CHECK(app->_waitTimer != nil);
            CHECK(gTap == NULL);
            CHECK(app->_item.button.image == app->_iconPermission);
        });
        CHECK([label isEqual:kTextNeedsPermissionLabel]);
        CHECK(!hidden && !keyboardEnabled && !mouseEnabled);
        CHECK([permissionTitle isEqual:kTextPermission]);
        CHECK([keyboardTitle isEqual:kTextKeyboardOff] && [mouseTitle isEqual:kTextMouseOff]);  // nothing sounds
        CHECK(gRequests == 0);

        // 2. [Open Settings] asks once, opens the right place and remembers it.
        gAnswer = NSAlertFirstButtonReturn;
        onMain(^{
            [app fixPermission];
            read();
        });
        gAnswer = NSAlertSecondButtonReturn;
        CHECK(gRequests == 1);
        CHECK([gOpenedURL.absoluteString hasSuffix:@"Privacy_ListenEvent"]);
        CHECK([defaults boolForKey:kAwaitingGrantKey]);

        // 3. After that press, "no permission" gets the reconnect line and the reconnect alert.
        CHECK([permissionTitle isEqual:kTextReconnect]);
        onMain(^{
            [app fixPermission];
            CHECK([gLastAlert.messageText isEqual:kTextReconnectTitle]);
            CHECK([gLastAlert.informativeText isEqual:kTextReconnectBody]);
        });

        // 4. The switch is turned on: noticed without a relaunch, the sound plays once.
        CHECK(sounds(^{
            gGranted = true;
            [app checkPermission];
        }) == 1);
        onMain(^{
            read();
            CHECK(gTap != NULL);
            CHECK(gTapOptions == kCGEventTapOptionListenOnly);
            CHECK(gTapMask == (kKeyEvents | kMouseEvents));
            // Both directions of the three buttons, and nothing about movement.
            CHECK(kMouseEvents == (CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp) |
                                   CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp) |
                                   CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp)));
            CHECK(app->_waitTimer == nil);
            CHECK(app->_item.button.image == app->_iconOn);
        });
        CHECK([label isEqual:kTextOnLabel]);
        CHECK(hidden && keyboardEnabled && mouseEnabled);
        CHECK([keyboardTitle isEqual:kTextKeyboardOn] && [mouseTitle isEqual:kTextMouseOn]);
        CHECK(![defaults boolForKey:kAwaitingGrantKey]);
        CHECK([defaults boolForKey:kEverGrantedKey]);

        // 5. Every switch combination. The tap asks only for what is on, and both off removes it.
        onMain(^{
            [app toggleKeyboard];
            read();
            CHECK(gTap != NULL && gTapMask == kMouseEvents);
            CHECK(app->_item.button.image == app->_iconOn);
            CHECK(!KSLoadPrefs(defaults).enabled && KSLoadPrefs(defaults).mouseEnabled);
        });
        CHECK([keyboardTitle isEqual:kTextKeyboardOff] && [mouseTitle isEqual:kTextMouseOn]);
        CHECK([label isEqual:kTextOnLabel]);
        onMain(^{
            [app toggleMouse];
            read();
            CHECK(gTap == NULL);
            CHECK(app->_item.button.image == app->_iconOff);
            CHECK(!KSLoadPrefs(defaults).enabled && !KSLoadPrefs(defaults).mouseEnabled);
        });
        CHECK([keyboardTitle isEqual:kTextKeyboardOff] && [mouseTitle isEqual:kTextMouseOff]);
        CHECK([label isEqual:kTextOffLabel]);
        CHECK(hidden && keyboardEnabled && mouseEnabled);  // off is a choice, not a blocked state
        onMain(^{
            [app toggleKeyboard];
            read();
            CHECK(gTap != NULL && gTapMask == kKeyEvents);
        });
        CHECK([keyboardTitle isEqual:kTextKeyboardOn] && [mouseTitle isEqual:kTextMouseOff]);
        onMain(^{
            [app toggleMouse];
            CHECK(gTap != NULL && gTapMask == (kKeyEvents | kMouseEvents));
            CHECK(KSLoadPrefs(defaults).enabled && KSLoadPrefs(defaults).mouseEnabled);
        });

        // 6. Which events make a sound, through the real tap callback. A release only sounds
        // when the pack under test has a release sound.
        NSString *configPath = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"config.json"];
        NSDictionary *config = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:configPath] options:0 error:NULL];
        int release = config[@"mouse_up_sound"] ? 1 : 0;
        CGPoint point = CGPointMake(1, 1);
        struct { CGEventType type; CGMouseButton button; int expected; } mouse[] = {
            {kCGEventLeftMouseDown, kCGMouseButtonLeft, 1},   {kCGEventRightMouseDown, kCGMouseButtonRight, 1},
            {kCGEventOtherMouseDown, kCGMouseButtonCenter, 1}, {kCGEventLeftMouseUp, kCGMouseButtonLeft, release},
            {kCGEventRightMouseUp, kCGMouseButtonRight, release}, {kCGEventOtherMouseUp, kCGMouseButtonCenter, release},
            {kCGEventLeftMouseDragged, kCGMouseButtonLeft, 0},
        };
        for (size_t i = 0; i < sizeof mouse / sizeof *mouse; i++) {
            CGEventType type = mouse[i].type;
            CGEventRef event = CGEventCreateMouseEvent(NULL, type, point, mouse[i].button);
            int played = sounds(^{
                onInputEvent(NULL, type, event, NULL);
            });
            CHECK(played == mouse[i].expected);
            CFRelease(event);
        }

        // A tap: press and release together make two sounds apart, or one if the mouse sound
        // goes off while the release waits.
        if (release) {
            CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, point, kCGMouseButtonLeft);
            CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
            int (^tap)(BOOL) = ^int(BOOL switchOff) {
                int before = atomic_load(&gClipBuffers);
                onMain(^{
                    onInputEvent(NULL, kCGEventLeftMouseDown, down, NULL);
                    onInputEvent(NULL, kCGEventLeftMouseUp, up, NULL);
                    if (switchOff) [app toggleMouse];
                });
                usleep(300000);
                return atomic_load(&gClipBuffers) - before;
            };
            CHECK(tap(NO) == 2);
            CHECK(tap(YES) == 1);
            onMain(^{
                [app toggleMouse];
            });
            CFRelease(down);
            CFRelease(up);
        }

        // 7. The sliders: each applied at once to its own sound, saved on release, any value.
        // Releasing the keyboard one plays a key. The mouse one adds nothing to the real release.
        CHECK(KSLoadPrefs(defaults).volume == 50 && KSLoadPrefs(defaults).mouseVolume == 50);
        CHECK(gLastVolume == 50 && gLastMouseVolume == 50);
        onMain(^{
            app->_keyboardSlider.integerValue = 37;
            [app keyboardVolumeChanged:app->_keyboardSlider];
            CHECK(gLastVolume == 37 && gLastMouseVolume == 50);
            CHECK(KSLoadPrefs(defaults).volume == 50);  // not saved while dragging
        });
        CHECK(sounds(^{
            [app volumeReleased:app->_keyboardSlider];
        }) == 1);
        CHECK(KSLoadPrefs(defaults).volume == 37 && KSLoadPrefs(defaults).mouseVolume == 50);
        onMain(^{
            app->_mouseSlider.integerValue = 12;
            [app mouseVolumeChanged:app->_mouseSlider];
            CHECK(gLastMouseVolume == 12 && gLastVolume == 37);
            CHECK(KSLoadPrefs(defaults).mouseVolume == 50);  // not saved while dragging
        });
        CHECK(sounds(^{
            [app volumeReleased:app->_mouseSlider];
        }) == 0);
        CHECK(KSLoadPrefs(defaults).volume == 37 && KSLoadPrefs(defaults).mouseVolume == 12);
        onMain(^{
            app->_keyboardSlider.integerValue = 80;
            app->_mouseSlider.integerValue = 80;
            [app menuNeedsUpdate:app->_item.menu];
            // Reopening the menu shows the saved values.
            CHECK(app->_keyboardSlider.integerValue == 37 && app->_mouseSlider.integerValue == 12);
        });

        // 8. A sound switched off stays off, on its own slider too. The permission signal still
        // finds the sound that is on.
        int (^released)(NSSlider *) = ^int(NSSlider *slider) {
            return sounds(^{
                [app volumeReleased:slider];
            });
        };
        onMain(^{
            [app toggleKeyboard];
        });
        CHECK(released(app->_keyboardSlider) == 0 && released(app->_mouseSlider) == 0);
        CHECK(sounds(^{
            [app playSample];
        }) == 1);
        onMain(^{
            [app toggleKeyboard];
            [app toggleMouse];
        });
        CHECK(released(app->_keyboardSlider) == 1 && released(app->_mouseSlider) == 0);
        onMain(^{
            [app toggleKeyboard];
            CHECK(gTap == NULL);
        });
        CHECK(released(app->_keyboardSlider) == 0 && released(app->_mouseSlider) == 0);
        onMain(^{
            [app toggleKeyboard];
            [app toggleMouse];
        });

        // 9. Permission lost later: found when the menu opens, no sound, waits again, and
        // this Mac had it before, so the reconnect alert explains the stuck switch.
        onMain(^{
            gGranted = false;
            [app menuNeedsUpdate:app->_item.menu];
            read();
            CHECK(gTap == NULL);
            CHECK(app->_waitTimer != nil);
            [app fixPermission];
            CHECK([gLastAlert.messageText isEqual:kTextReconnectTitle]);
        });
        CHECK([label isEqual:kTextNeedsPermissionLabel]);
        CHECK(!hidden && !keyboardEnabled && !mouseEnabled);
        CHECK([permissionTitle isEqual:kTextReconnect]);
        CHECK([keyboardTitle isEqual:kTextKeyboardOff] && [mouseTitle isEqual:kTextMouseOff]);

        // 10. The alert follows the memory exactly.
        void (^alertFor)(BOOL, BOOL, NSString *) = ^(BOOL ever, BOOL awaiting, NSString *expected) {
            onMain(^{
                [defaults setBool:ever forKey:kEverGrantedKey];
                [defaults setBool:awaiting forKey:kAwaitingGrantKey];
                [app fixPermission];
                CHECK([gLastAlert.messageText isEqual:expected]);
                [app sync];
                CHECK([app->_permissionItem.title isEqual:ever || awaiting ? kTextReconnect : kTextPermission]);
            });
        };
        alertFor(NO, NO, kTextGuideTitle);
        alertFor(YES, NO, kTextReconnectTitle);
        alertFor(NO, YES, kTextReconnectTitle);
        alertFor(YES, YES, kTextReconnectTitle);

        // 11. Allowed but the tap cannot start: the relaunch alert appears.
        int alerts = gAlertCount;
        onMain(^{
            gTapWorks = false;
            gGranted = true;
            [app checkPermission];
            read();
            CHECK(gAlertCount == alerts + 1);
            CHECK([gLastAlert.messageText isEqual:kTextRelaunchTitle]);
        });
        CHECK([label isEqual:kTextNeedsPermissionLabel]);
        CHECK(!hidden && [permissionTitle isEqual:kTextPermission]);

        // 12. Releasing the slider, through the real class in a window that is never shown.
        // No drag here: a press and a release posted at once.
        __block int releases = 0;
        onMain(^{
            gTapWorks = true;
            [app sync];
        });
        NSSlider *menuSlider = app->_keyboardSlider;
        CHECK(sounds(^{
            NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 200, 40)
                                                           styleMask:NSWindowStyleMaskBorderless
                                                             backing:NSBackingStoreBuffered
                                                               defer:YES];
            VolumeSlider *slider = [VolumeSlider sliderWithValue:0 minValue:0 maxValue:100 target:app action:@selector(keyboardVolumeChanged:)];
            slider.frame = NSMakeRect(0, 0, 200, 40);
            app->_keyboardSlider = slider;  // the release has to say which slider it was
            [window.contentView addSubview:slider];
            NSEvent *(^mouseEvent)(NSEventType) = ^NSEvent *(NSEventType type) {
                return [NSEvent mouseEventWithType:type location:NSMakePoint(100, 20) modifierFlags:0 timestamp:0
                                      windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
            };
            int before = KSLoadPrefs(defaults).volume;
            [NSApp postEvent:mouseEvent(NSEventTypeLeftMouseUp) atStart:NO];
            [slider mouseDown:mouseEvent(NSEventTypeLeftMouseDown)];
            releases = KSLoadPrefs(defaults).volume != before;
            app->_keyboardSlider = menuSlider;
        }) == 1);
        CHECK(releases == 1);

        if (exportDir) onMain(^{
            // A menu's view has no window until the menu opens, so it gets one that is never shown.
            NSArray<NSMenuItem *> *items = app->_item.menu.itemArray;
            NSView *rows[] = {items[7].view, items[4].view};  // bottom up
            NSSize row = rows[0].frame.size;
            NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, row.width, row.height * 2)
                                                           styleMask:NSWindowStyleMaskBorderless
                                                             backing:NSBackingStoreBuffered
                                                               defer:YES];
            window.appearance = NSApp.appearance;
            for (int i = 0; i < 2; i++) {
                // A menu item keeps its view at the origin, so the holder sets the position.
                NSView *holder = [[NSView alloc] initWithFrame:NSMakeRect(0, i * row.height, row.width, row.height)];
                [holder addSubview:rows[i]];
                [window.contentView addSubview:holder];
            }
            exportView(window.contentView, [exportDir stringByAppendingFormat:@"/menu-volume-%@.png", theme]);
            exportIcons(exportDir);
        });
        printf("flow in %s: %d failed\n", kTextQuit.UTF8String, gFailures);
        fflush(stdout);
        exit(gFailures != 0);
    });
}

@end

int main(void) {
    @autoreleasepool {
        NSUserDefaults *args = NSUserDefaults.standardUserDefaults;
        for (NSString *key in @[ @"enabled", @"mouseEnabled", @"volume", @"mouseVolume", kAwaitingGrantKey, kEverGrantedKey ]) {
            [args removeObjectForKey:key];
        }

        double rate = [args doubleForKey:@"rate"];
        int count = (int)[args integerForKey:@"count"];
        int volume = (int)[args integerForKey:@"testvolume"];
        double idle = [args doubleForKey:@"idle"];
        NSString *flow = [args stringForKey:@"flow"];
        bool mouse = [args boolForKey:@"mouse"];
        gGranted = flow == nil;
        keepOutOfTheWay();
        NSApplication.sharedApplication.activationPolicy = NSApplicationActivationPolicyProhibited;
        if ([flow isEqual:@"dark"] || [flow isEqual:@"light"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSApp.appearance = [NSAppearance appearanceNamed:[flow isEqual:@"dark"] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
            });
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500000000), dispatch_get_main_queue(), ^{
            if (flow) {
                [(App *)NSApp.delegate checkFlow:[args stringForKey:@"export"]];
            } else if (rate > 0) {
                runKeys(rate, count, volume, mouse);
            } else {
                // One key first, so the audio stack is loaded and the output has opened and closed.
                KSSetVolume(0);
                KSPlayKey(kVK_ANSI_A);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4000000000), dispatch_get_main_queue(), ^{
                    double start = cpuSeconds();
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(idle * 1e9)), dispatch_get_main_queue(), ^{
                        printf("idle cpu over %.0f s: %.4f%%, footprint %.1f MB\n", idle, (cpuSeconds() - start) * 100 / idle, footprintMB());
                        fflush(stdout);
                        exit(0);
                    });
                });
            }
        });
        return app_main();
    }
}
