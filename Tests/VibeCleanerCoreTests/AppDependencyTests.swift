import Foundation
import Testing
@testable import VibeCleanerCore

@Suite struct AppDependencyTests {
    @Test func modulesNameTheAppsToQuit() {
        let chrome = ResultItem(name: "Cookies", action: .custom("browser:com.google.Chrome:chromeCookies"))
        #expect(ProtectionModule().appDependency(of: chrome) == AppDependency(name: "Google Chrome", bundleID: "com.google.Chrome"))
        #expect(ProtectionModule().appDependency(of: ResultItem(name: "x", action: .custom("quarantine-file"))) == nil)

        let mail = ResultItem(name: "Accélérer Mail", action: .custom(PerformanceModule.Key.vacuumMail))
        #expect(PerformanceModule().appDependency(of: mail)?.bundleID == "com.apple.mail")

        let file = ResultItem(id: "/Applications/Foo.app|/Users/x/Library/Caches/foo", name: "foo", action: .none)
        #expect(ApplicationsModule().appDependency(of: file) == AppDependency(name: "Foo", bundlePath: "/Applications/Foo.app"))
        #expect(CleanupModule().appDependency(of: file) == nil)
    }
}
