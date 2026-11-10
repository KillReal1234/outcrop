import Testing
@testable import ClarcCore

// The Application Support directory name is derived from the bundle identifier
// so alternate builds never share state with the production build.

@Suite("AppSupport.directoryName(forBundleID:)")
struct AppSupportTests {

    @Test("Production bundle id keeps the historical Clarc directory")
    func productionBundleID() {
        #expect(AppSupport.directoryName(forBundleID: "com.idealapp.Clarc") == "Clarc")
    }

    @Test("Dev bundle id maps to Clarc.dev")
    func devBundleID() {
        #expect(AppSupport.directoryName(forBundleID: "com.idealapp.Clarc.dev") == "Clarc.dev")
    }

    @Test("Any other bundle id maps to Clarc.<last component>")
    func otherBundleID() {
        #expect(AppSupport.directoryName(forBundleID: "com.example.something") == "Clarc.something")
    }
}
