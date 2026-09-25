// An app extension has no main of its own: the binary is linked with NSExtensionMain as its entry point and the
// system instantiates `FileProviderExtension`, named in the Info.plist, for each domain. Nothing here runs.
import Foundation
