import Foundation
import Testing
@testable import MandroidKit

@Suite struct RepositoryManifestTests {
    static let repoURL = RepositoryManifest.repositoryURL
    static let imgURL = RepositoryManifest.systemImageManifestURL(tag: "google_apis_playstore")

    func repo() throws -> RepositoryManifest {
        try RepositoryManifest.parse(data: Fixtures.data("repository2-3.xml"), baseURL: Self.repoURL)
    }
    func images() throws -> RepositoryManifest {
        try RepositoryManifest.parse(data: Fixtures.data("sys-img2-3-google_apis_playstore.xml"), baseURL: Self.imgURL)
    }

    @Test func stableEmulatorForAppleSilicon() throws {
        let m = try repo()
        let (pkg, archive) = try #require(m.package(path: "emulator", arch: .aarch64))
        #expect(pkg.channel == "channel-0")
        #expect(pkg.revision == .init(major: 37, minor: 1, micro: 11))
        #expect(archive.hostArch == "aarch64")
        #expect(archive.url.absoluteString == "https://dl.google.com/android/repository/emulator-darwin_aarch64-15917651.zip")
        #expect(archive.size == 394_555_844)
        #expect(archive.sha1 == "f22f44948a2b7f0a0103645b9a639290eef92426")
    }

    @Test func channelFilteringSkipsCanary() throws {
        let m = try repo()
        // Both channel-2 (37.2.8) and channel-0 (37.1.11) exist; stable wins.
        let all = m.packages.filter { $0.path == "emulator" }
        #expect(all.count >= 2)
        let (any, _) = try #require(m.package(path: "emulator", arch: .aarch64, stableOnly: false))
        #expect(any.revision >= .init(major: 37, minor: 2, micro: 8))
    }

    @Test func platformToolsIsUniversal() throws {
        let m = try repo()
        let (pkg, archive) = try #require(m.package(path: "platform-tools", arch: .aarch64))
        #expect(archive.hostArch == nil)
        #expect(archive.hostOS == "macosx")
        #expect(pkg.revision.major == 37)
        // Same archive is chosen for Intel.
        #expect(m.package(path: "platform-tools", arch: .x64)?.1 == archive)
    }

    @Test func systemImageDetailsAndDependencies() throws {
        let m = try images()
        let list = m.systemImages(tag: "google_apis_playstore", abi: "arm64-v8a")
        let (pkg, archive) = try #require(list.first)
        #expect(pkg.apiLevel == "36.1")
        #expect(pkg.abi == "arm64-v8a")
        #expect(pkg.tagID == "google_apis_playstore")
        #expect(pkg.licenseRef == "android-sdk-arm-dbt-license")
        #expect(pkg.dependencies.first?.minRevision == .init(major: 35, minor: 4, micro: 9))
        #expect(archive.url.absoluteString == "https://dl.google.com/android/repository/sys-img/google_apis_playstore/arm64-v8a-36.1_r04.zip")
        #expect(archive.hostArch == nil && archive.hostOS == nil)
    }

    @Test func licensesArePerManifestAndHashed() throws {
        let m = try images()
        let lic = try #require(m.licenses["android-sdk-license"])
        #expect(lic.hash.count == 40)
        #expect(m.licenses["android-sdk-arm-dbt-license"] != nil)
        #expect(try repo().licenses["android-sdk-arm-dbt-license"] == nil)   // only in the sys-img manifest
    }

    @Test func planSkipsInstalledComponents() throws {
        let paths = SDKPaths(root: URL(fileURLWithPath: "/tmp/aar-test"))
        let plan = try SDKBootstrap.plan(repository: repo(), systemImages: images(), paths: paths,
                                         tag: "google_apis_playstore", abi: "arm64-v8a", preferredAPI: nil) { dir in
            dir.lastPathComponent == "platform-tools" ? .init(major: 37, minor: 0, micro: 1) : nil
        }
        #expect(plan.components.map(\.id) == ["emulator", "system-images;android-36.1;google_apis_playstore;arm64-v8a"])
        #expect(plan.components[1].installDirectory.path.hasSuffix("sdk/system-images/android-36.1/google_apis_playstore/arm64-v8a"))
        #expect(plan.totalBytes > 2_000_000_000)
        #expect(Set(plan.licenses.map(\.id)) == ["android-sdk-license", "android-sdk-arm-dbt-license"])
    }

    @Test func planPrefersRequestedAPI() throws {
        let paths = SDKPaths(root: URL(fileURLWithPath: "/tmp/aar-test"))
        let plan = try SDKBootstrap.plan(repository: repo(), systemImages: images(), paths: paths,
                                         tag: "google_apis_playstore", abi: "arm64-v8a", preferredAPI: "35") { _ in nil }
        #expect(plan.systemImagePath == "system-images;android-35;google_apis_playstore;arm64-v8a")
    }

    @Test func kernelSUPlanUsesManifestRevision4() throws {
        let paths = SDKPaths(root: URL(fileURLWithPath: "/tmp/aar-test"))
        let plan = try SDKBootstrap.plan(repository: repo(), systemImages: images(), paths: paths,
                                         tag: "google_apis_playstore", abi: "arm64-v8a", preferredAPI: nil, kernelSU: true) { _ in nil }
        let image = try #require(plan.components.first { $0.id == KernelSUPatcher.imagePackagePath })
        #expect(image.archive.url.lastPathComponent == KernelSUPatcher.imageArchiveName)
        #expect(image.archive.sha1 == KernelSUPatcher.imageArchiveSHA1)
        #expect(image.package.revision == KernelSUPatcher.imageRevision)
    }

    @Test func kernelSUPlanKeepsRevision4WhenManifestIsNewer() throws {
        var imgs = try images()
        let index = try #require(imgs.packages.firstIndex { $0.path == KernelSUPatcher.imagePackagePath })
        imgs.packages[index].revision = .init(major: 5)
        let current = imgs.packages[index].archives[0]
        imgs.packages[index].archives[0] = .init(hostOS: current.hostOS, hostArch: current.hostArch,
                                                url: current.url.deletingLastPathComponent().appendingPathComponent("arm64-v8a-36.1_r05.zip"),
                                                size: current.size, sha1: String(repeating: "ab", count: 20))
        let paths = SDKPaths(root: URL(fileURLWithPath: "/tmp/aar-test"))
        let pinned = try SDKBootstrap.plan(repository: repo(), systemImages: imgs, paths: paths,
                                           tag: "google_apis_playstore", abi: "arm64-v8a", preferredAPI: nil, kernelSU: true) { _ in nil }
        let image = try #require(pinned.components.first { $0.id == KernelSUPatcher.imagePackagePath })
        #expect(image.archive.url.lastPathComponent == KernelSUPatcher.imageArchiveName)
        #expect(image.archive.sha1 == KernelSUPatcher.imageArchiveSHA1)
        #expect(image.package.revision == KernelSUPatcher.imageRevision)

        let newest = try SDKBootstrap.plan(repository: repo(), systemImages: imgs, paths: paths,
                                           tag: "google_apis_playstore", abi: "arm64-v8a", preferredAPI: nil, kernelSU: false) { _ in nil }
        let latest = try #require(newest.components.first { $0.id == KernelSUPatcher.imagePackagePath })
        #expect(latest.archive.url.lastPathComponent == "arm64-v8a-36.1_r05.zip")
        #expect(latest.archive.sha1 == String(repeating: "ab", count: 20))
    }

    @Test func kernelSUPlanDownloadsUntilRevision4IsInstalled() throws {
        let paths = SDKPaths(root: URL(fileURLWithPath: "/tmp/aar-test"))
        func plan(installed: RepositoryManifest.Revision) throws -> BootstrapPlan {
            try SDKBootstrap.plan(repository: repo(), systemImages: images(), paths: paths,
                                 tag: "google_apis_playstore", abi: "arm64-v8a", preferredAPI: nil, kernelSU: true) { dir in
                dir.path.contains("system-images") ? installed : .init(major: 99)
            }
        }
        let older = try plan(installed: .init(major: 3))
        #expect(older.components.map(\.id) == [KernelSUPatcher.imagePackagePath])
        let current = try plan(installed: .init(major: 4))
        #expect(current.isEmpty)
        let newer = try plan(installed: .init(major: 5))
        #expect(newer.components.map(\.id) == [KernelSUPatcher.imagePackagePath])
        #expect(newer.components[0].archive.sha1 == KernelSUPatcher.imageArchiveSHA1)
    }
}
