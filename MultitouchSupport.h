// Minimal declarations for Apple's private MultitouchSupport.framework,
// which reports where each finger is on the trackpad.
#include <CoreFoundation/CoreFoundation.h>

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;

typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier;   // stable for one finger from touch-down to lift
    int32_t state;        // 3 = touching down, 4 = touching, others = hovering/lifting
    int32_t fingerID;
    int32_t handID;
    MTVector normalized;  // 0...1, origin at the trackpad's bottom-left corner
    float size;
    int32_t zero1;
    float angle, majorAxis, minorAxis;
    MTVector absolute;
    int32_t zero2[2];
    float density;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef device, MTTouch *touches, int count, double timestamp, int frame);

CFMutableArrayRef MTDeviceCreateList(void) CF_RETURNS_RETAINED;
void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallback);
void MTUnregisterContactFrameCallback(MTDeviceRef, MTContactCallback);
void MTDeviceStart(MTDeviceRef, int);
void MTDeviceStop(MTDeviceRef);
