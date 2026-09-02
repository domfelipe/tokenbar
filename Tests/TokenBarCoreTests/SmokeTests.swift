import Testing
@testable import TokenBarCore

struct SmokeTests {
    @Test
    func coreVersionIsSet() {
        #expect(!TokenBarCoreInfo.version.isEmpty)
    }
}
