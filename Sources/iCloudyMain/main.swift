// The application binary. Everything else lives in the `iCloudy` library, shared with the Finder extension.
import iCloudy

// Top-level code runs on the main thread; saying so here keeps both language modes in agreement about it.
MainActor.assumeIsolated { AppLauncher.run() }
