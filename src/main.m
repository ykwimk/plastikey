#import <Carbon/Carbon.h>  // kVK_ANSI_A
#import <Cocoa/Cocoa.h>

#import "sound.h"

static NSString *L(NSString *korean, NSString *english) {
    return [NSLocale.preferredLanguages.firstObject hasPrefix:@"ko"] ? korean : english;
}

// All user-facing text lives here: Korean on a Mac set to Korean, otherwise English.
#define kTextAppName @"Plastikey"
#define kTextKeyboardOn L(@"키보드 소리 켬", @"Keyboard Sound On")
#define kTextKeyboardOff L(@"키보드 소리 끔", @"Keyboard Sound Off")
#define kTextMouseOn L(@"마우스 소리 켬", @"Mouse Sound On")
#define kTextMouseOff L(@"마우스 소리 끔", @"Mouse Sound Off")
#define kTextVolume L(@"음량", @"Volume")
#define kTextKeyboardVolume L(@"키보드 음량", @"Keyboard Volume")
#define kTextMouseVolume L(@"마우스 음량", @"Mouse Volume")
#define kTextPermission L(@"키 입력 권한 켜기…", @"Turn On Input Permission…")
#define kTextReconnect L(@"키 입력 권한 다시 연결…", @"Reconnect Input Permission…")
#define kTextQuit L(@"끝내기", @"Quit")
#define kTextOpenSettings L(@"설정 열기", @"Open Settings")
#define kTextLater L(@"나중에", @"Later")
#define kTextGuideTitle                                                 \
    L(@"키와 마우스 버튼을 누를 때 소리를 내려면 권한이 하나 필요합니다", \
      @"Plastikey needs one permission to play sounds when you press keys and mouse buttons")
#define kTextGuideBody                                                                                                 \
    L(@"입력 모니터링을 켜면 키를 누른 순간과 마우스 버튼을 누르고 뗀 순간을 알아채 소리를 냅니다. 어떤 키인지는 "     \
      @"소리를 고르는 데만 쓰고 저장하지 않습니다. 마우스 위치는 읽지 않고, 인터넷도 쓰지 않습니다. 끄기와 음량은 "    \
      @"메뉴바의 키보드 아이콘에 있습니다.",                                                                           \
      @"With Input Monitoring on, Plastikey notices the moment a key goes down or a mouse button goes down or up, "    \
      @"and plays a sound. Which key it was only picks the sound and is never stored. The mouse position is not "      \
      @"read, and the internet is not used. Sound switches and volume are under the keyboard icon in the menu bar.")
#define kTextReconnectTitle L(@"키 입력 권한을 다시 연결해야 합니다", @"Input permission needs to be reconnected")
#define kTextReconnectBody                                                                                              \
    L(@"앱이 새 버전으로 바뀌면 맥이 전에 준 권한을 이어 주지 않을 수 있습니다. 그래서 스위치가 켜져 있어도 소리가 "    \
      @"나지 않고, 껐다 켜도 풀리지 않습니다.\n\n입력 모니터링 목록에서 Plastikey 를 눌러 고르고 아래 − 로 지운 뒤, "  \
      @"이 앱을 끝내고 다시 여세요. 다시 열면 이 창이 한 번 더 뜹니다. 그때 [설정 열기]를 누르고 Plastikey 스위치를 "   \
      @"켜면 됩니다. 스위치가 꺼져 있다면 켜기만 하면 됩니다.",                                                          \
      @"When the app changes to a new version, macOS may not carry over the permission it gave before. The switch can " \
      @"look on while no sound plays, and turning it off and on does not help.\n\nIn the Input Monitoring list, "       \
      @"select Plastikey, remove it with the − button below, then quit this app and open it again. This window shows "  \
      @"once more: click Open Settings and turn Plastikey on. If the switch is off, just turn it on.")
#define kTextRelaunchTitle L(@"권한을 적용하려면 앱을 다시 열어야 합니다", @"Reopen Plastikey to apply the permission")
#define kTextRelaunch L(@"다시 열기", @"Reopen")
#define kTextOnLabel L(@"Plastikey 켜짐", @"Plastikey on")
#define kTextOffLabel L(@"Plastikey 꺼짐", @"Plastikey off")
#define kTextNeedsPermissionLabel L(@"Plastikey 권한 필요", @"Plastikey needs permission")

static NSString *const kInputMonitoringURL =
    @"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent";

// Survives the quit-and-reopen macOS offers after the switch is turned on.
static NSString *const kAwaitingGrantKey = @"awaitingGrant";
// With either memory, "no permission" most likely means a stale entry, not a first run.
static NSString *const kEverGrantedKey = @"everGranted";

static const CGEventMask kKeyEvents = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventFlagsChanged);
// Buttons going down and up only: no drags or movement, so moving the mouse never wakes the app.
static const CGEventMask kMouseEvents = CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp) |
                                        CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp) |
                                        CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp);

typedef NS_ENUM(int, IconBadge) { IconBadgeNone, IconBadgeSlash, IconBadgePermission };

static CFMachPortRef gTap;

static CGEventRef onInputEvent(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(gTap, true);
        return event;
    }
    if (KSIsMouseDown(type)) {
        KSPlayMouse((CGMouseButton)CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber));
        return event;
    }
    if (KSIsMouseUp(type)) {
        KSPlayMouseUp((CGMouseButton)CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber));
        return event;
    }
    // A key re-posted by another app is not a real press (Siri re-sends ⌘+Space's Space when it is let go).
    if (CGEventGetIntegerValueField(event, kCGEventSourceStateID) != kCGEventSourceStateHIDSystemState) return event;
    uint16_t key = (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    bool autorepeat = CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0;
    if (KSIsPress(type, autorepeat, key, CGEventGetFlags(event))) KSPlayKey(key);
    return event;
}

// Shape, not color, tells the states apart. Template images follow the menu bar.
static NSImage *makeIcon(IconBadge badge) {
    NSImageSymbolConfiguration *config =
        [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightRegular];
    NSImage *keyboard = [[NSImage imageWithSystemSymbolName:@"keyboard" accessibilityDescription:nil]
        imageWithSymbolConfiguration:config];
    NSSize size = NSMakeSize(ceil(keyboard.size.width) + 4, 18);
    NSImage *icon = [NSImage imageWithSize:size
                                   flipped:NO
                            drawingHandler:^BOOL(NSRect bounds) {
                                NSRect frame = NSMakeRect(2, floor((NSHeight(bounds) - keyboard.size.height) / 2),
                                                          keyboard.size.width, keyboard.size.height);
                                [keyboard drawInRect:frame];
                                CGContextRef context = NSGraphicsContext.currentContext.CGContext;
                                if (badge == IconBadgeSlash) {
                                    NSBezierPath *line = [NSBezierPath bezierPath];
                                    [line moveToPoint:NSMakePoint(NSMaxX(frame) - 2, NSMaxY(bounds) - 1)];
                                    [line lineToPoint:NSMakePoint(NSMinX(frame) + 2, NSMinY(bounds) + 1)];
                                    line.lineCapStyle = NSLineCapStyleRound;
                                    CGContextSetBlendMode(context, kCGBlendModeClear);
                                    line.lineWidth = 4;
                                    [line stroke];
                                    CGContextSetBlendMode(context, kCGBlendModeNormal);
                                    line.lineWidth = 1.5;
                                    [NSColor.blackColor setStroke];
                                    [line stroke];
                                } else if (badge == IconBadgePermission) {
                                    NSRect dot = NSMakeRect(NSMaxX(bounds) - 10, NSMaxY(bounds) - 10, 10, 10);
                                    CGContextSetBlendMode(context, kCGBlendModeClear);
                                    [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(dot, -1.5, -1.5)] fill];
                                    CGContextSetBlendMode(context, kCGBlendModeNormal);
                                    NSImage *mark =
                                        [NSImage imageWithSystemSymbolName:@"exclamationmark.circle.fill"
                                                  accessibilityDescription:nil];
                                    [mark drawInRect:dot];
                                }
                                return YES;
                            }];
    icon.template = YES;
    return icon;
}

// NSSlider tracks the whole drag inside mouseDown:, so the line after super runs on release.
// shortcut: a view in a menu cannot take keyboard input (Apple, "Views in Menu Items"), so
// the slider is mouse only. The README says so.
@interface VolumeSlider : NSSlider
@end

@implementation VolumeSlider

- (void)mouseDown:(NSEvent *)event {
    [super mouseDown:event];
    [NSApp sendAction:@selector(volumeReleased:) to:self.target from:self];
}

@end

@interface App : NSObject <NSApplicationDelegate, NSMenuDelegate>
@end

@implementation App {
    KSPrefs _prefs;
    NSStatusItem *_item;
    NSImage *_iconOn, *_iconOff, *_iconPermission;
    NSMenuItem *_permissionItem, *_keyboardItem, *_mouseItem;
    NSSlider *_keyboardSlider, *_mouseSlider;
    CFRunLoopSourceRef _source;
    CGEventMask _tapEvents;
    NSTimer *_waitTimer;
    id<NSObject> _activity;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSString *error = KSLoadPack(NSBundle.mainBundle.resourcePath);
    if (error) {
        NSLog(@"sound pack: %@", error);  // the build checks the pack, so this means a damaged app
        exit(1);
    }
    _prefs = KSLoadPrefs(NSUserDefaults.standardUserDefaults);
    KSSetVolume(_prefs.volume);
    KSSetMouseVolume(_prefs.mouseVolume);

    // App Nap would delay the first key after a pause. This keeps priority without any wake-ups.
    _activity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                                                             reason:@"Reacting to key presses"];
    _iconOn = makeIcon(IconBadgeNone);
    _iconOff = makeIcon(IconBadgeSlash);
    _iconPermission = makeIcon(IconBadgePermission);
    [self buildMenu];
    [self sync];

    if (!CGPreflightListenEventAccess()) {
        // Not dispatch_async: a modal alert inside a main-queue block would hold the queue.
        [self performSelector:@selector(showGuide) withObject:nil afterDelay:0];
    } else if (gTap && [NSUserDefaults.standardUserDefaults boolForKey:kAwaitingGrantKey]) {
        [self announceGrant];
    }
}

- (void)buildMenu {
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    menu.showsStateColumn = NO;  // the titles say on or off
    menu.delegate = self;

    [self addItem:kTextAppName action:NULL to:menu].enabled = NO;
    _permissionItem = [self addItem:kTextPermission action:@selector(fixPermission) to:menu];
    [menu addItem:NSMenuItem.separatorItem];
    _keyboardItem = [self addItem:kTextKeyboardOn action:@selector(toggleKeyboard) to:menu];
    _keyboardSlider = [self addSlider:kTextKeyboardVolume value:_prefs.volume action:@selector(keyboardVolumeChanged:) to:menu];
    [menu addItem:NSMenuItem.separatorItem];
    _mouseItem = [self addItem:kTextMouseOn action:@selector(toggleMouse) to:menu];
    _mouseSlider = [self addSlider:kTextMouseVolume value:_prefs.mouseVolume action:@selector(mouseVolumeChanged:) to:menu];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [self addItem:kTextQuit action:@selector(terminate:) to:menu];
    quit.target = NSApp;
    quit.keyEquivalent = @"q";

    _item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    _item.menu = menu;
}

- (NSMenuItem *)addItem:(NSString *)title action:(SEL)action to:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    [menu addItem:item];
    return item;
}

- (NSSlider *)addSlider:(NSString *)name value:(int)value action:(SEL)action to:(NSMenu *)menu {
    enum { kInset = 14, kGap = 10, kSliderWidth = 140, kHeight = 28 };
    // The row under each switch says which sound it is, so the short word is enough here.
    NSTextField *label = [NSTextField labelWithString:kTextVolume];
    label.font = [NSFont menuFontOfSize:0];
    label.accessibilityElement = NO;  // the slider carries the full name
    [label sizeToFit];

    NSSlider *slider = [VolumeSlider sliderWithValue:value minValue:0 maxValue:100 target:self action:action];
    slider.continuous = YES;
    slider.accessibilityLabel = name;

    CGFloat labelWidth = NSWidth(label.frame);
    NSView *view = [[NSView alloc]
        initWithFrame:NSMakeRect(0, 0, kInset + labelWidth + kGap + kSliderWidth + kInset, kHeight)];
    [label setFrameOrigin:NSMakePoint(kInset, round((kHeight - NSHeight(label.frame)) / 2))];
    slider.frame = NSMakeRect(kInset + labelWidth + kGap, round((kHeight - NSHeight(slider.frame)) / 2), kSliderWidth,
                              NSHeight(slider.frame));
    [view addSubview:label];
    [view addSubview:slider];
    NSMenuItem *item = [NSMenuItem new];
    item.view = view;
    [menu addItem:item];
    return slider;
}

- (bool)askedBefore {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults boolForKey:kEverGrantedKey] || [defaults boolForKey:kAwaitingGrantKey];
}

// One place that turns permission + preference into tap, icon and menu state.
- (void)sync {
    bool granted = CGPreflightListenEventAccess();
    CGEventMask wanted = (_prefs.enabled ? kKeyEvents : 0) | (_prefs.mouseEnabled ? kMouseEvents : 0);
    if (!granted || wanted != _tapEvents) [self stopTap];
    if (granted && wanted) [self startTap:wanted];
    bool blocked = !granted || (wanted && !gTap);

    if (granted) {
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:kEverGrantedKey];
        [_waitTimer invalidate];
        _waitTimer = nil;
    } else if (!_waitTimer) {
        // The only periodic wake-up in the app, and only while waiting for the user.
        _waitTimer = [NSTimer timerWithTimeInterval:1 target:self selector:@selector(checkPermission) userInfo:nil repeats:YES];
        _waitTimer.tolerance = 0.5;
        [NSRunLoop.mainRunLoop addTimer:_waitTimer forMode:NSRunLoopCommonModes];
    }

    _item.button.image = blocked ? _iconPermission : wanted ? _iconOn : _iconOff;
    _item.button.accessibilityLabel = blocked  ? kTextNeedsPermissionLabel
                                      : wanted ? kTextOnLabel
                                               : kTextOffLabel;
    _permissionItem.hidden = !blocked;
    _permissionItem.title = !granted && [self askedBefore] ? kTextReconnect : kTextPermission;
    // While blocked nothing sounds, so the titles say off whatever is saved.
    _keyboardItem.title = _prefs.enabled && !blocked ? kTextKeyboardOn : kTextKeyboardOff;
    _mouseItem.title = _prefs.mouseEnabled && !blocked ? kTextMouseOn : kTextMouseOff;
    _keyboardItem.enabled = !blocked;
    _mouseItem.enabled = !blocked;
    _keyboardSlider.integerValue = _prefs.volume;
    _mouseSlider.integerValue = _prefs.mouseVolume;
}

- (void)startTap:(CGEventMask)events {
    if (gTap) return;
    // Listen-only: the tap cannot change or insert events.
    gTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly, events, onInputEvent,
                            NULL);
    if (!gTap) return;
    _tapEvents = events;
    _source = CFMachPortCreateRunLoopSource(NULL, gTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
}

- (void)stopTap {
    _tapEvents = 0;
    if (!gTap) return;
    CFRunLoopRemoveSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
    CFRelease(_source);
    CFMachPortInvalidate(gTap);
    CFRelease(gTap);
    gTap = NULL;
    _source = NULL;
}

- (void)checkPermission {
    if (!CGPreflightListenEventAccess()) return;
    [self sync];
    if (gTap) {
        [self announceGrant];
    } else if (_prefs.enabled || _prefs.mouseEnabled) {
        [self showRelaunch];
    }
}

// There is no window, so one sound is the "it worked" signal.
- (void)announceGrant {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kAwaitingGrantKey];
    [self playSample];
}

// Only with the tap running, so at least one of the two sounds is on.
- (void)playSample {
    if (_prefs.enabled) {
        KSPlayKey(kVK_ANSI_A);
    } else {
        KSPlayMouse(kCGMouseButtonLeft);
    }
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [self sync];  // permission can be switched off at any time
}

- (void)save {
    KSSavePrefs(NSUserDefaults.standardUserDefaults, _prefs);
}

- (void)toggleKeyboard {
    _prefs.enabled = !_prefs.enabled;
    [self save];
    [self sync];
}

- (void)toggleMouse {
    _prefs.mouseEnabled = !_prefs.mouseEnabled;
    if (!_prefs.mouseEnabled) KSDropHeldMouseUps();
    [self save];
    [self sync];
}

- (void)keyboardVolumeChanged:(NSSlider *)slider {
    _prefs.volume = (int)slider.integerValue;
    KSSetVolume(_prefs.volume);
}

- (void)mouseVolumeChanged:(NSSlider *)slider {
    _prefs.mouseVolume = (int)slider.integerValue;
    KSSetMouseVolume(_prefs.mouseVolume);
}

- (void)volumeReleased:(NSSlider *)slider {
    [self save];
    // The mouse slider needs no sample: letting go of it is the real release sound, at the new volume.
    if (gTap && _prefs.enabled && slider == _keyboardSlider) KSPlayKey(kVK_ANSI_A);
}

- (void)fixPermission {
    if (CGPreflightListenEventAccess()) {
        [self showRelaunch];  // allowed, yet the tap failed: only a relaunch can help
    } else {
        [self showGuide];
    }
}

- (NSAlert *)alertWithTitle:(NSString *)title firstButton:(NSString *)button {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    [alert addButtonWithTitle:button];
    [alert addButtonWithTitle:kTextLater];
    [NSApp activateIgnoringOtherApps:YES];
    return alert;
}

- (void)showGuide {
    bool reconnect = [self askedBefore];
    NSAlert *alert = [self alertWithTitle:reconnect ? kTextReconnectTitle : kTextGuideTitle firstButton:kTextOpenSettings];
    alert.informativeText = reconnect ? kTextReconnectBody : kTextGuideBody;
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:kAwaitingGrantKey];
    [self sync];                   // the menu line now offers to reconnect
    CGRequestListenEventAccess();  // the app shows up in the settings list only after asking once
    // The asynchronous call, so the permission check keeps running while Settings launches.
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:kInputMonitoringURL]
                           configuration:[NSWorkspaceOpenConfiguration configuration]
                       completionHandler:nil];
}

- (void)showRelaunch {
    NSAlert *alert = [self alertWithTitle:kTextRelaunchTitle firstButton:kTextRelaunch];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
    config.createsNewApplicationInstance = YES;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:NSBundle.mainBundle.bundleURL
                                        configuration:config
                                    completionHandler:^(NSRunningApplication *app, NSError *error) {
                                        dispatch_async(dispatch_get_main_queue(), ^{
                                            [NSApp terminate:nil];
                                        });
                                    }];
}

@end

int main(void) {
    @autoreleasepool {
        static App *app;  // NSApplication holds its delegate weakly
        app = [App new];
        NSApplication.sharedApplication.delegate = app;
        [NSApp run];
    }
    return 0;
}
