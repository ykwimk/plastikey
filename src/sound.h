#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

typedef struct {
    uint32_t start, frames;  // sample frames into the pack's audio
    bool mouse;              // follows the mouse volume instead of the keyboard volume
    _Atomic uint64_t *started;  // if set, the render thread notes here when the clip starts
} KSClip;

typedef struct {
    bool enabled;  // keyboard sound
    bool mouseEnabled;
    int volume;  // 0...100, keyboard
    int mouseVolume;  // 0...100
} KSPrefs;

// Loads <dir>/config.json (Mechvibes "single" pack), the WAV it names, and the optional
// "mouse_sound" and "mouse_up_sound" WAVs. Returns nil on success, otherwise a message
// saying what is wrong.
NSString *KSLoadPack(NSString *dir);

// Letters and digits advance through the pack's clips on each call. Others are fixed.
KSClip KSClipForKey(uint16_t macKey);

// True only for a fresh physical press: no auto-repeat, no key-up, no modifier release.
bool KSIsPress(CGEventType type, bool autorepeat, uint16_t macKey, CGEventFlags flags);

// True for a press of any mouse button. Releases and drags do not count.
bool KSIsMouseDown(CGEventType type);

// True for a release of any mouse button.
bool KSIsMouseUp(CGEventType type);

// Main thread only. Each starts the output if it is stopped, except that KSPlayMouseUp
// does nothing for a pack with no "mouse_up_sound". The key number is used here to pick
// a clip and goes no further.
void KSPlayKey(uint16_t macKey);
void KSPlayMouse(CGMouseButton button);
void KSPlayMouseUp(CGMouseButton button);

// A release sounds no sooner than 90 ms after its button's press sound. One still waiting
// is dropped by a new press of that button, or by this call when the mouse sound goes off.
void KSDropHeldMouseUps(void);

// Keyboard volume, then mouse volume. Both apply at once, also to clips already playing.
void KSSetVolume(int percent);
void KSSetMouseVolume(int percent);

// Mixes the active clips into interleaved stereo. Real-time safe.
void KSRender(float *out, uint32_t frames);

KSPrefs KSLoadPrefs(NSUserDefaults *defaults);
void KSSavePrefs(NSUserDefaults *defaults, KSPrefs prefs);
