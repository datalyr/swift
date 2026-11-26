#ifndef DATALYR_SDK_LAUNCH_H
#define DATALYR_SDK_LAUNCH_H

#include <stdint.h>

/// The App Tracking Transparency status read once when the SDK's code was loaded into the
/// app process (before main()), so before the app can show the tracking prompt.
/// 0 notDetermined, 1 restricted, 2 denied, 3 authorized;
/// -1 not read (the loader did not run); -2 ATTrackingManager is not present (before iOS 14).
/// Kept in memory only.
int64_t datalyr_att_status_at_process_start(void);

#endif
