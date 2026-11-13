#include "iCloudyTestBootstrap.h"

// Defined in Swift, in Tests/iCloudyTests/TestSupport.swift, with @_cdecl. Weak so this target links on its own.
extern void icloudy_tests_bootstrap(void) __attribute__((weak));

// XCTest has no bundle-level setUp that also runs when `swift test --parallel` or `--filter` starts the bundle for a
// single test, so the isolation the suite relies on is installed from a load-time constructor instead.
__attribute__((constructor)) static void icloudy_tests_load(void) {
    if (icloudy_tests_bootstrap) icloudy_tests_bootstrap();
}
