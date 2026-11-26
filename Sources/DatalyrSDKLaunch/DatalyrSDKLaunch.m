#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include "DatalyrSDKLaunch.h"

// iOS opens the tracking domain (tracking.datalyr.com, declared in the privacy manifest) only
// to app processes started after the user allowed tracking. The SDK therefore needs the
// status this process STARTED with, read before the app can show the prompt. A Swift static
// is read only when the SDK is first used, which can be after the prompt; this constructor
// runs when the image is loaded, before main().
//
// ATTrackingManager is looked up at run time: no link-time dependency on the framework, and
// nothing happens before iOS 14. Memory only, written once before main(), read-only after.

static int64_t datalyrATTStatusAtProcessStart = -1;

__attribute__((constructor))
static void datalyr_capture_att_status_at_process_start(void) {
    Class manager = objc_getClass("ATTrackingManager");
    SEL selector = sel_registerName("trackingAuthorizationStatus");
    if (manager == Nil || !class_getClassMethod(manager, selector)) {
        datalyrATTStatusAtProcessStart = -2;
        return;
    }
    NSUInteger (*read)(id, SEL) = (NSUInteger (*)(id, SEL))objc_msgSend;
    datalyrATTStatusAtProcessStart = (int64_t)read((id)manager, selector);
}

int64_t datalyr_att_status_at_process_start(void) {
    return datalyrATTStatusAtProcessStart;
}
