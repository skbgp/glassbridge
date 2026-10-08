import Foundation

struct BridgeTests {
    func testDevicesAndAuthorization() {
        let devices = parseDevices(
            "List of devices attached\nA device product:p model:Pixel_9 transport_id:1\nB unauthorized\nC offline\n"
        )
        expectEqual(devices.count, 3)
        expectEqual(devices[0].name, "Pixel 9")
        expectTrue(devices[0].ready)
        expectFalse(devices[1].ready)
    }
    func testListingPreservesUnusualNamesAndSortsFoldersFirst() throws {
        let raw =
            [
                "photo ' 😀\n.jpg", "f", "123", "1700000000", "Downloads", "d", "4096", "1700000000",
                ".hidden", "f", "0", "0",
            ].joined(separator: "\0") + "\0"
        let entries = try parseRemoteListing(Data(raw.utf8), parent: "/sdcard")
        expectEqual(entries.first?.name, "Downloads")
        expectTrue(entries.contains { $0.name == "photo ' 😀\n.jpg" })
        expectEqual(entries.last?.size, 123)
        expectThrows(try parseRemoteListing(Data("bad\0f\0".utf8), parent: "/"))
        expectThrows(try parseRemoteListing(Data("../bad\0f\00\00\0".utf8), parent: "/"))
    }
    func testShellQuotingDoesNotExecuteFilename() async throws {
        let name = "one ' two; $(echo HACKED) `echo bad`\n😀"
        let result = try await ProcessJob().run(
            executable: "/bin/sh", arguments: ["-c", "printf %s " + shellQuote(name)], timeout: 5,
            limit: 4096, progress: nil)
        expectEqual(result.text, name)
        expectEqual(childPath("/", "test"), "/test")
    }
    func testProcessDrainsBothPipes() async throws {
        let result = try await ProcessJob().run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "i=0; while [ $i -lt 3000 ]; do printf 'stdout0123456789'; printf 'stderr0123456789' >&2; i=$((i+1)); done",
            ], timeout: 10, limit: 100000, progress: nil)
        expectEqual(result.output.count, 48000)
        expectEqual(result.error.count, 48000)
    }
    func testCancellationAndTimeout() async throws {
        let task = Task {
            try await ProcessJob().run(
                executable: "/bin/sleep", arguments: ["10"], timeout: 15, limit: 1000, progress: nil
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            fail("Cancellation was ignored")
        } catch { expectTrue(error is CancellationError) }
        do {
            _ = try await ProcessJob().run(
                executable: "/bin/sleep", arguments: ["10"], timeout: 0.1, limit: 1000,
                progress: nil)
            fail("Timeout was ignored")
        } catch { expectTrue(error.localizedDescription.contains("time")) }
    }
    func testDirectoryManifestIncludesEmptyFoldersAndRejectsLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("hello".utf8).write(to: root.appendingPathComponent("file\n'😀"))
        let manifest = try localManifest(root.path, directory: true)
        expectEqual(manifest["."], -1)
        expectEqual(manifest["./empty"], -1)
        expectEqual(manifest["./file\n'😀"], 5)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: root.appendingPathComponent("file\n'😀"))
        expectThrows(try localManifest(root.path, directory: true))
    }
    func testBinaryManifestRejectsTruncationAndDuplicates() throws {
        expectEqual(
            try parseManifest(Data((["./a", "12"].joined(separator: "\0") + "\0").utf8))["./a"], 12)
        expectThrows(try parseManifest(Data("./a\0".utf8)))
        expectThrows(try parseManifest(Data([46, 47, 97, 0, 49, 0, 46, 47, 97, 0, 50, 0])))
    }
}

struct DeviceIntegrationTests {
    @MainActor func testLiveFolderRoundTripAndDuplicateNames() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let serial = environment["GLASSBRIDGE_TEST_SERIAL"],
            let path = environment["GLASSBRIDGE_TEST_ADB"]
        else {
            throw BridgeError(
                message:
                    "Connect an authorized phone and set GLASSBRIDGE_TEST_SERIAL and GLASSBRIDGE_TEST_ADB to run the live test."
            )
        }
        let service = ADB(executable: path)
        let fm = FileManager.default
        let local = fm.temporaryDirectory.appendingPathComponent(
            "glassbridge-test-" + UUID().uuidString)
        let source = local.appendingPathComponent("Transfer's 😀 folder")
        let receive = local.appendingPathComponent("received")
        let remote = "/sdcard/Download/.glassbridge-test-" + UUID().uuidString
        try fm.createDirectory(
            at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try fm.createDirectory(at: receive, withIntermediateDirectories: true)
        let content = Data((0..<262144).map { UInt8($0 % 251) })
        try content.write(to: source.appendingPathComponent("photo ' 😀.bin"))
        try Data().write(to: source.appendingPathComponent("-zero bytes.txt"))
        defer { try? fm.removeItem(at: local) }
        _ = try await service.shell("mkdir -p " + shellQuote(remote), serial: serial)
        do {
            let model = AppModel()
            model.adbPath = path
            model.conflictResolver = { _ in .keepBoth }
            model.devices = [Device(id: serial, state: "device", name: "Live Android")]
            model.selectedDevice = serial
            model.macPath = receive.path
            model.androidPath = remote
            let entry = FileEntry(
                path: source.path, name: source.lastPathComponent, directory: true,
                symbolicLink: false,
                size: 0, modified: Date())
            model.enqueue([entry, entry], from: .mac)
            try await waitUntilIdle(model)
            expectEqual(
                model.transfers.map(\.state), [.done, .done],
                model.transfers.map(\.detail).joined(separator: "\n"))
            let remoteFiles = try await service.list(remote, serial: serial)
            expectEqual(remoteFiles.count, 2)
            expectTrue(remoteFiles.contains { $0.name == "Transfer's 😀 folder (2)" })
            let first = try require(remoteFiles.first { $0.name == source.lastPathComponent })
            let remoteManifest = try await service.manifest(
                first.path, directory: true, serial: serial)
            expectEqual(remoteManifest, try localManifest(source.path, directory: true))
            model.enqueue([first], from: .android)
            try await waitUntilIdle(model)
            expectEqual(model.transfers.last?.state, .done, model.transfers.last?.detail ?? "")
            let received = receive.appendingPathComponent(source.lastPathComponent)
            expectEqual(
                try Data(contentsOf: received.appendingPathComponent("photo ' 😀.bin")), content)
            expectTrue(fm.fileExists(atPath: received.appendingPathComponent("empty").path))
            // An inaccessible remote path must fail without publishing a destination.
            model.androidPath = "/proc/glassbridge-unwritable-" + UUID().uuidString
            model.enqueue([entry], from: .mac)
            try await waitUntilIdle(model)
            expectEqual(model.transfers.last?.state, .failed)
            _ = try await service.shell("rm -rf " + shellQuote(remote), serial: serial)
        } catch {
            _ = try? await service.shell("rm -rf " + shellQuote(remote), serial: serial)
            throw error
        }
    }
    @MainActor private func waitUntilIdle(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(90)
        while model.activeCount > 0 {
            if Date() > deadline {
                await model.shutdown()
                throw BridgeError(message: "Integration transfer timed out")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        // The queue's final browse refresh is allowed to settle before the next phase.
        try await Task.sleep(for: .milliseconds(150))
    }
}

struct CopyBehaviorChecks {
    @MainActor func conflictsAndLiveProgress() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "glassbridge-behavior-" + UUID().uuidString)
        let remote = root.appendingPathComponent("remote")
        let source = root.appendingPathComponent("source")
        let receive = root.appendingPathComponent("receive")
        for folder in [root, remote, source, receive] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }
        let statScript = #"""
            #!/usr/bin/python3
            import os, sys
            fmt=sys.argv[2]
            for path in sys.argv[3:]:
                try:
                    info=os.lstat(path)
                    print(fmt.replace('%s',str(info.st_size)).replace('%Y',str(int(info.st_mtime))))
                except OSError as error:
                    print(str(error),file=sys.stderr); sys.exit(1)
            """#
        let transportScript = #"""
            #!/usr/bin/python3
            import os, sys, time, subprocess
            here=os.path.dirname(os.path.abspath(__file__))
            args=sys.argv[1:]
            if args[:1]==['-s']: args=args[2:]
            if args[0]=='exec-out':
                env=os.environ.copy(); env['PATH']=here+':'+env.get('PATH','/usr/bin:/bin')
                sys.exit(subprocess.call(['/bin/sh','-c',args[1]],env=env))
            if args[0] in ('push','pull'):
                args=[a for a in args[1:] if a!='-a']; source,target=args
                def copy_file(src,dst):
                    os.makedirs(os.path.dirname(dst),exist_ok=True)
                    with open(src,'rb') as inp, open(dst,'wb') as out:
                        while True:
                            chunk=inp.read(65536)
                            if not chunk: break
                            out.write(chunk); out.flush(); time.sleep(0.025)
                if os.path.isdir(source):
                    for base, dirs, files in os.walk(source):
                        for name in files: copy_file(os.path.join(base,name),os.path.join(target,os.path.relpath(base,source),name))
                else: copy_file(source,target)
                sys.exit(0)
            sys.exit(1)
            """#
        for (name, script) in [("stat", statScript), ("adb-test", transportScript)] {
            let url = root.appendingPathComponent(name)
            try Data(script.utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let path = source.appendingPathComponent("progress.bin")
        let original = Data(repeating: 7, count: 4 * 1024 * 1024)
        try original.write(to: path)
        let model = AppModel()
        model.adbPath = root.appendingPathComponent("adb-test").path
        model.devices = [Device(id: "test", state: "device", name: "Test phone")]
        model.selectedDevice = "test"
        model.macPath = receive.path
        model.androidPath = remote.path
        func entry() -> FileEntry {
            FileEntry(
                path: path.path, name: path.lastPathComponent, directory: false,
                symbolicLink: false,
                size: Int64(original.count), modified: Date())
        }
        model.enqueue([entry()], from: .mac)
        let progress = try await wait(model)
        expectTrue(progress)
        expectEqual(model.transfers.last?.state, .done)
        expectEqual(try Data(contentsOf: remote.appendingPathComponent("progress.bin")), original)
        model.enqueue([entry()], from: .mac)
        try await waitForConflict(model)
        expectEqual(model.conflict?.name, "progress.bin")
        model.resolveConflict(.skip)
        _ = try await wait(model)
        expectEqual(model.transfers.last?.state, .skipped)
        expectEqual(try Data(contentsOf: remote.appendingPathComponent("progress.bin")), original)
        let replacement = Data(repeating: 9, count: original.count + 64)
        try replacement.write(to: path)
        model.enqueue([entry()], from: .mac)
        try await waitForConflict(model)
        expectEqual(try Data(contentsOf: remote.appendingPathComponent("progress.bin")), original)
        model.resolveConflict(.replace)
        expectTrue(try await wait(model))
        expectEqual(model.transfers.last?.state, .done)
        expectEqual(
            try Data(contentsOf: remote.appendingPathComponent("progress.bin")), replacement)
        expectFalse(
            try fm.contentsOfDirectory(atPath: remote.path).contains {
                $0.hasPrefix(".glassbridge")
            })
        model.enqueue([entry()], from: .mac)
        try await waitForConflict(model)
        model.resolveConflict(.keepBoth)
        _ = try await wait(model)
        expectEqual(model.transfers.last?.state, .done)
        expectTrue(fm.fileExists(atPath: remote.appendingPathComponent("progress (2).bin").path))
        // Cancelling an unanswered dialog must not deadlock the queue.
        model.enqueue([entry()], from: .mac)
        try await waitForConflict(model)
        model.cancel(try require(model.transfers.last?.id))
        _ = try await wait(model)
        expectEqual(model.transfers.last?.state, .cancelled)
        expectTrue(model.conflict == nil)
        // Pull progress is measured on the Mac rather than relying on console percentages.
        let remoteFile = FileEntry(
            path: remote.appendingPathComponent("progress.bin").path, name: "progress.bin",
            directory: false, symbolicLink: false, size: Int64(replacement.count), modified: Date())
        model.enqueue([remoteFile], from: .android)
        expectTrue(try await wait(model))
        expectEqual(model.transfers.last?.state, .done)
        expectEqual(
            try Data(contentsOf: receive.appendingPathComponent("progress.bin")), replacement)
        // Verify replacement also handles complete folders and restores an original on failure.
        let oldFolder = root.appendingPathComponent("old-folder")
        let newFolder = root.appendingPathComponent("new-folder")
        try fm.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: newFolder, withIntermediateDirectories: true)
        try Data([1]).write(to: oldFolder.appendingPathComponent("old"))
        try Data([2]).write(to: newFolder.appendingPathComponent("new"))
        _ = try publishLocal(staging: newFolder.path, destination: oldFolder.path, replacing: true)
        expectTrue(fm.fileExists(atPath: oldFolder.appendingPathComponent("new").path))
        expectFalse(fm.fileExists(atPath: oldFolder.appendingPathComponent("old").path))
        expectThrows(
            try publishLocal(
                staging: root.appendingPathComponent("absent").path, destination: oldFolder.path,
                replacing: true))
        expectTrue(fm.fileExists(atPath: oldFolder.appendingPathComponent("new").path))
    }
    @MainActor private func waitForConflict(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while model.conflict == nil {
            if Date() > deadline {
                await model.shutdown()
                throw BridgeError(message: "Conflict dialog did not appear")
            }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
    @MainActor private func wait(_ model: AppModel) async throws -> Bool {
        let deadline = Date().addingTimeInterval(30)
        var partial = false
        while model.activeCount > 0 {
            if let item = model.transfers.last, item.state == .running, item.transferredBytes > 0,
                item.transferredBytes < item.totalBytes, item.bytesPerSecond > 0,
                item.secondsRemaining != nil
            {
                partial = true
            }
            if Date() > deadline {
                await model.shutdown()
                throw BridgeError(message: "Behavior test timed out")
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        try await Task.sleep(for: .milliseconds(100))
        return partial
    }
}

private var failures = 0
private func fail(_ message: String) {
    failures += 1
    print("FAIL: " + message)
}
private func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "") {
    if lhs != rhs { fail("Expected \(rhs), got \(lhs). " + message) }
}
private func expectTrue(_ value: Bool) { if !value { fail("Expected true") } }
private func expectFalse(_ value: Bool) { if value { fail("Expected false") } }
private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw BridgeError(message: "Required value is absent") }
    return value
}
private func expectThrows<T>(_ value: @autoclosure () throws -> T) {
    do {
        _ = try value()
        fail("Expected an error")
    } catch {}
}

@main struct CheckRunner {
    @MainActor static func main() async {
        let checks = BridgeTests()
        let tests: [(String, () async throws -> Void)] = [
            ("Devices and authorization", { checks.testDevicesAndAuthorization() }),
            (
                "Unusual file names and sorting",
                { try checks.testListingPreservesUnusualNamesAndSortsFoldersFirst() }
            ),
            (
                "Safe filename quoting",
                { try await checks.testShellQuotingDoesNotExecuteFilename() }
            ),
            ("Concurrent output streams", { try await checks.testProcessDrainsBothPipes() }),
            ("Cancellation and timeouts", { try await checks.testCancellationAndTimeout() }),
            (
                "Empty folders and symbolic links",
                { try checks.testDirectoryManifestIncludesEmptyFoldersAndRejectsLinks() }
            ),
            (
                "Incomplete manifests",
                { try checks.testBinaryManifestRejectsTruncationAndDuplicates() }
            ),
            (
                "Conflict choices, safe replacement, and live byte progress",
                { try await CopyBehaviorChecks().conflictsAndLiveProgress() }
            ),
        ]
        for (name, test) in tests {
            let before = failures
            do { try await test() } catch { fail(error.localizedDescription) }
            print("\(failures == before ? "PASS" : "FAIL"): \(name)")
        }
        if ProcessInfo.processInfo.environment["GLASSBRIDGE_TEST_SERIAL"] != nil {
            let before = failures
            do {
                try await DeviceIntegrationTests().testLiveFolderRoundTripAndDuplicateNames()
            } catch {
                fail(error.localizedDescription)
            }
            print(
                "\(failures == before ? "PASS" : "FAIL"): Live ADB round trip, duplicate names, and invalid destination"
            )
        } else {
            print("SKIP: Live Android checks (no test serial configured)")
        }
        print("\(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
