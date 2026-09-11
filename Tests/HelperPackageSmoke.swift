import Foundation

@MainActor final class KeepAliveController {}

nonisolated enum CodexPercentageFormat {
    static func string(from value: Int) -> String {
        "\(value)%"
    }
}

@main
struct HelperPackageSmoke {
    static func main() throws {
        typealias Status = KeepAliveController.HelperInstallationStatus
        precondition(Status(registration: .notFound, packageIssue: nil, registrationError: nil) == .notInstalled)
        precondition(Status(registration: .requiresApproval, packageIssue: nil, registrationError: nil) == .requiresApproval)
        precondition(Status(registration: .enabled, packageIssue: nil, registrationError: nil) == .authorized)
        precondition(Status(registration: .enabled, packageIssue: .invalid, registrationError: nil) == .unavailable(HelperPackageIssue.invalid.message))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-helper-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let service = "io.github.yatotm.codexbar.helper"
        precondition(KeepAliveHelperConfiguration.validatePackage(appURL: root, machServiceName: service) == .missing)
        let helper = resources.appendingPathComponent("CodexBarHelper")
        try Data("invalid".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let daemons = root.appendingPathComponent("Contents/Library/LaunchDaemons")
        try FileManager.default.createDirectory(at: daemons, withIntermediateDirectories: true)
        try Data("invalid plist".utf8).write(to: daemons.appendingPathComponent(service + ".plist"))
        precondition(KeepAliveHelperConfiguration.validatePackage(appURL: root, machServiceName: service) == .invalid)

        if let path = CommandLine.arguments.dropFirst().first {
            let app = URL(fileURLWithPath: path)
            let identifier = Bundle(url: app)!.bundleIdentifier!
            precondition(
                KeepAliveHelperConfiguration.validatePackage(appURL: app, machServiceName: identifier + ".helper") == nil,
                "开发签名安装包也必须通过所有架构的组件校验"
            )
        }
        print("Helper registration, missing/invalid package and optional signed-app checks passed")
    }
}
