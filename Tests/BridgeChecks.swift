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
            expectEqual(model.transfers.count, 1)
            model.enqueue([entry], from: .mac)
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
                if 'rm -rf -- ' in args[1] and 'denied-delete.txt' in args[1]:
                    print('Permission denied',file=sys.stderr); sys.exit(1)
                if '; else printf 0; fi' in args[1] and 'stat -c %s' in args[1]:
                    counter=os.path.join(here,'.progress-samples')
                    try:
                        with open(counter) as inp: count=int(inp.read())+1
                    except FileNotFoundError: count=1
                    with open(counter,'w') as out: out.write(str(count))
                    if count % 3 == 0:
                        print(0); sys.exit(0)
                env=os.environ.copy(); env['PATH']=here+':'+env.get('PATH','/usr/bin:/bin')
                sys.exit(subprocess.call(['/bin/sh','-c',args[1]],env=env))
            if args[0] in ('push','pull'):
                args=[a for a in args[1:] if a!='-a']; source,target=args
                with open(os.path.join(here,'copy-log'),'a') as log: log.write(os.path.basename(source)+'\n')
                def copy_file(src,dst):
                    os.makedirs(os.path.dirname(dst),exist_ok=True)
                    with open(src,'rb') as inp, open(dst,'wb') as out:
                        while True:
                            chunk=inp.read(65536)
                            if not chunk: break
                            out.write(chunk); out.flush(); time.sleep(0.025)
                    if os.path.exists(os.path.join(here,'corrupt-copy')):
                        with open(dst,'r+b') as out: out.write(b'!')
                    if os.path.basename(src)=='z-fail.bin' and os.path.exists(os.path.join(here,'fail-copy')):
                        print('Injected copy failure',file=sys.stderr); sys.exit(1)
                if os.path.isdir(source):
                    for base, dirs, files in os.walk(source):
                        for name in files: copy_file(os.path.join(base,name),os.path.join(target,os.path.relpath(base,source),name))
                else: copy_file(source,target)
                sys.exit(0)
            sys.exit(1)
            """#
        let hashScript = #"""
            #!/usr/bin/python3
            import hashlib, sys
            for path in sys.argv[1:]:
                hash=hashlib.sha256()
                with open(path,'rb') as inp:
                    while True:
                        data=inp.read(1048576)
                        if not data: break
                        hash.update(data)
                print(hash.hexdigest()+'  '+path)
            """#
        for (name, script) in [
            ("stat", statScript), ("sha256sum", hashScript), ("adb-test", transportScript),
        ] {
            let url = root.appendingPathComponent(name)
            try Data(script.utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let path = source.appendingPathComponent("progress.bin")
        let largeFolder = root.appendingPathComponent("large-progress")
        try fm.createDirectory(at: largeFolder, withIntermediateDirectories: true)
        for (name, size) in [("first", UInt64(3_000_000_000)), ("second", UInt64(4_000_000_000))] {
            let file = largeFolder.appendingPathComponent(name)
            fm.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: size)
            try handle.close()
        }
        let sizeService = ADB(executable: root.appendingPathComponent("adb-test").path)
        expectEqual(
            try await sizeService.transferredBytes(
                largeFolder.path, directory: true, serial: "test"),
            7_000_000_000)
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
        let nested = remote.appendingPathComponent("Dropped folder")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let payload = DragPayload(side: .mac, entries: [entry()], serial: nil)
        model.receive(payload, on: .android, folder: nested.path, serial: "test")
        let cancelledPrompt = try require(model.copyPrompt)
        expectEqual(model.transfers.count, 0)
        model.copyPrompt = nil
        model.confirmCopy(cancelledPrompt)
        expectEqual(model.transfers.count, 0)
        model.receive(payload, on: .android, folder: nested.path, serial: "test")
        let prompt = try require(model.copyPrompt)
        expectEqual(prompt.folder, nested.path)
        model.androidPath = receive.path
        model.confirmCopy(prompt)
        model.confirmCopy(prompt)
        model.enqueue([entry(), entry()], from: .mac, folder: nested.path, serial: "test")
        model.receive(payload, on: .android, folder: nested.path, serial: "test")
        expectTrue(model.copyPrompt == nil)
        expectEqual(model.transfers.count, 1)
        _ = try await wait(model)
        expectEqual(model.transfers.last?.state, .done)
        expectEqual(try Data(contentsOf: nested.appendingPathComponent("progress.bin")), original)
        expectFalse(fm.fileExists(atPath: receive.appendingPathComponent("progress.bin").path))
        model.androidPath = remote.path
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
        try await checkMergesAndDeletion(
            model, root: root, source: source, remote: remote, receive: receive)
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
    @MainActor private func checkMergesAndDeletion(
        _ model: AppModel, root: URL, source: URL, remote: URL, receive: URL
    ) async throws {
        let fm = FileManager.default
        let folderName = "Merge ' 😀 folder"
        let beforeFailures = failures
        let input = source.appendingPathComponent(folderName)
        let output = remote.appendingPathComponent(folderName)
        for folder in [
            input, output, input.appendingPathComponent("empty"),
            input.appendingPathComponent("nested"),
        ] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        func put(_ folder: URL, _ name: String, _ data: Data) throws {
            try data.write(to: folder.appendingPathComponent(name))
        }
        func entry(_ url: URL, directory: Bool = false) -> FileEntry {
            FileEntry(
                path: url.path, name: url.lastPathComponent, directory: directory,
                symbolicLink: false, size: 0, modified: Date())
        }
        let unchanged = Data(repeating: 7, count: 2_000_000)
        try put(input, "unchanged.bin", unchanged)
        try put(output, "unchanged.bin", unchanged)
        try put(input, "changed.bin", Data("NEW!".utf8))
        try put(output, "changed.bin", Data("OLD!".utf8))
        try put(input, "missing-empty.bin", Data())
        try put(input, "nested/photo '\n😀.bin", Data([1, 2, 3]))
        try put(output, "extra.bin", Data([9]))
        model.androidPath = remote.path
        model.macPath = receive.path
        model.conflictResolver = { _ in .merge }
        model.enqueue([entry(input, directory: true)], from: .mac)
        _ = try await wait(model)
        expectEqual(model.transfers.last?.state, .done, model.transfers.last?.detail ?? "")
        expectTrue(model.transfers.last?.detail.contains("3 updated · 1 unchanged") == true)
        expectEqual(
            try Data(contentsOf: output.appendingPathComponent("changed.bin")), Data("NEW!".utf8))
        expectEqual(try Data(contentsOf: output.appendingPathComponent("extra.bin")), Data([9]))
        expectTrue(fm.fileExists(atPath: output.appendingPathComponent("empty").path))
        let log = root.appendingPathComponent("copy-log")
        expectFalse(try String(contentsOf: log, encoding: .utf8).contains("unchanged.bin"))
        let before = try Data(contentsOf: log)
        model.enqueue([entry(input, directory: true)], from: .mac)
        _ = try await wait(model)
        expectEqual(model.transfers.last?.totalBytes, 0)
        expectEqual(model.transfers.last?.state, .done, model.transfers.last?.detail ?? "")
        expectEqual(try Data(contentsOf: log), before)

        let back = receive.appendingPathComponent(folderName)
        try fm.createDirectory(at: back, withIntermediateDirectories: true)
        try put(back, "unchanged.bin", unchanged)
        try put(back, "changed.bin", Data("DIFF".utf8))
        try put(back, "mac-extra.bin", Data([8]))
        model.enqueue([entry(output, directory: true)], from: .android)
        _ = try await wait(model)
        expectEqual(model.transfers.last?.state, .done, model.transfers.last?.detail ?? "")
        expectEqual(
            try Data(contentsOf: back.appendingPathComponent("changed.bin")), Data("NEW!".utf8))
        expectEqual(try Data(contentsOf: back.appendingPathComponent("mac-extra.bin")), Data([8]))
        expectFalse(try String(contentsOf: log, encoding: .utf8).contains("unchanged.bin"))

        // A nested file/folder collision fails before unrelated paths are modified.
        try fm.removeItem(at: output.appendingPathComponent("nested"))
        try put(output, "nested", Data([5]))
        model.enqueue([entry(input, directory: true)], from: .mac)
        _ = try await wait(model)
        expectEqual(model.transfers.last?.state, .failed)
        expectEqual(try Data(contentsOf: output.appendingPathComponent("nested")), Data([5]))
        let clash = source.appendingPathComponent("root-clash")
        try fm.createDirectory(at: clash, withIntermediateDirectories: true)
        try put(remote, "root-clash", Data([4]))
        model.enqueue([entry(clash, directory: true)], from: .mac)
        _ = try await wait(model)
        expectEqual(model.transfers.last?.state, .failed)
        expectEqual(try Data(contentsOf: remote.appendingPathComponent("root-clash")), Data([4]))

        // Corruption must not replace the old file. Retrying can finish the merge.
        try put(source, "hash-fail.bin", Data("new".utf8))
        try put(remote, "hash-fail.bin", Data("old".utf8))
        try put(root, "corrupt-copy", Data())
        model.enqueue([entry(source.appendingPathComponent("hash-fail.bin"))], from: .mac)
        _ = try await wait(model)
        expectEqual(model.transfers.last?.state, .failed)
        expectEqual(
            try Data(contentsOf: remote.appendingPathComponent("hash-fail.bin")), Data("old".utf8))
        try fm.removeItem(at: root.appendingPathComponent("corrupt-copy"))
        model.enqueue([entry(source.appendingPathComponent("hash-fail.bin"))], from: .mac)
        _ = try await wait(model)
        expectEqual(model.transfers.last?.state, .done)

        let partial = source.appendingPathComponent("partial")
        let partialTarget = remote.appendingPathComponent("partial")
        for folder in [partial, partialTarget] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for name in ["a.bin", "z-fail.bin"] {
            try put(partial, name, Data("new".utf8))
            try put(partialTarget, name, Data("old".utf8))
        }
        try put(root, "fail-copy", Data())
        model.enqueue([entry(partial, directory: true)], from: .mac)
        _ = try await wait(model)
        expectEqual(model.transfers.last?.state, .failed)
        expectEqual(
            try Data(contentsOf: partialTarget.appendingPathComponent("a.bin")), Data("new".utf8))
        expectEqual(
            try Data(contentsOf: partialTarget.appendingPathComponent("z-fail.bin")),
            Data("old".utf8))
        try fm.removeItem(at: root.appendingPathComponent("fail-copy"))
        model.enqueue([entry(partial, directory: true)], from: .mac)
        _ = try await wait(model)
        expectEqual(model.transfers.last?.state, .done)
        expectTrue(model.transfers.last?.detail.contains("1 updated · 1 unchanged") == true)

        // Cancellation leaves the current file intact and removes temporary data.
        try put(source, "cancel-merge.bin", Data(repeating: 1, count: 4_000_000))
        try put(remote, "cancel-merge.bin", Data(repeating: 2, count: 4_000_000))
        model.enqueue([entry(source.appendingPathComponent("cancel-merge.bin"))], from: .mac)
        let deadline = Date().addingTimeInterval(10)
        while model.transfers.last?.detail.hasPrefix("Updating") != true {
            if Date() > deadline { throw BridgeError(message: "Merge did not start") }
            try await Task.sleep(for: .milliseconds(20))
        }
        model.cancel(try require(model.transfers.last?.id))
        _ = try await wait(model)
        expectEqual(model.transfers.last?.state, .cancelled)
        expectEqual(
            try Data(contentsOf: remote.appendingPathComponent("cancel-merge.bin")),
            Data(repeating: 2, count: 4_000_000))
        expectFalse(
            try fm.contentsOfDirectory(atPath: remote.path).contains {
                $0.hasPrefix(".glassbridge-merge-")
            })

        let deleteFile = remote.appendingPathComponent("delete ' 😀; $(echo BAD).txt")
        try Data([6]).write(to: deleteFile)
        let selected = entry(deleteFile)
        model.androidFiles = [selected]
        model.androidSelection = [selected.id]
        model.requestDeleteSelection(.android)
        let cancelled = try require(model.deletePrompt)
        model.deletePrompt = nil
        model.confirmDeletion(cancelled)
        expectTrue(fm.fileExists(atPath: deleteFile.path))
        let active = Transfer(
            id: UUID(), source: selected, from: .android, serial: "test",
            destinationFolder: receive.path, deviceName: "Test phone")
        model.transfers.append(active)
        model.requestDeleteSelection(.android)
        expectTrue(model.deletePrompt == nil)
        model.transfers.removeAll { $0.id == active.id }
        model.requestDeleteSelection(.android)
        let approved = try require(model.deletePrompt)
        model.confirmDeletion(approved)
        model.confirmDeletion(approved)
        while model.deleting { try await Task.sleep(for: .milliseconds(20)) }
        expectFalse(fm.fileExists(atPath: deleteFile.path))
        let deleteFolder = remote.appendingPathComponent("delete folder")
        try fm.createDirectory(
            at: deleteFolder.appendingPathComponent("child"), withIntermediateDirectories: true)
        try put(deleteFolder, "child/file", Data([1]))
        try await model.adb.delete(
            entry(deleteFolder, directory: true), folder: remote.path, serial: "test")
        expectFalse(fm.fileExists(atPath: deleteFolder.path))
        let denied = remote.appendingPathComponent("denied-delete.txt")
        try Data([8]).write(to: denied)
        model.androidFiles = [entry(denied)]
        model.androidSelection = [denied.path]
        model.requestDeleteSelection(.android)
        let deniedPrompt = try require(model.deletePrompt)
        model.confirmDeletion(deniedPrompt)
        while model.deleting { try await Task.sleep(for: .milliseconds(20)) }
        expectTrue(fm.fileExists(atPath: denied.path))
        expectTrue(model.alert?.contains("Permission denied") == true)
        model.androidFiles = [entry(denied)]
        model.androidSelection = [denied.path]
        model.requestDeleteSelection(.android)
        let disconnectedPrompt = try require(model.deletePrompt)
        model.devices = []
        model.confirmDeletion(disconnectedPrompt)
        while model.deleting { try await Task.sleep(for: .milliseconds(20)) }
        expectTrue(fm.fileExists(atPath: denied.path))
        expectTrue(model.alert?.contains("disconnected") == true)
        model.devices = [Device(id: "test", state: "device", name: "Test phone")]
        model.androidSelection = []
        model.requestDeleteSelection(.android)
        expectTrue(model.deletePrompt == nil)
        model.macPath = source.path
        let macEntry = entry(source.appendingPathComponent("hash-fail.bin"))
        model.macFiles = [macEntry]
        model.macSelection = [macEntry.id]
        model.requestDeleteSelection(.mac)
        expectEqual(model.deletePrompt?.side, .mac)
        model.deletePrompt = nil
        expectTrue(fm.fileExists(atPath: macEntry.path))
        expectThrows(
            try validateDeletion(
                entry(URL(fileURLWithPath: "/sdcard"), directory: true), folder: "/"))
        expectThrows(try validateDeletion(entry(deleteFile), folder: source.path))
        try validateDeletion(
            entry(source.appendingPathComponent("hash-fail.bin")), folder: source.path)
        print(
            "\(failures == beforeFailures ? "PASS" : "FAIL"): Merge hashes, both directions, partial folders, failures, cancellation, and deletion safeguards"
        )
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
        var highest: Int64 = 0
        while model.activeCount > 0 {
            if let item = model.transfers.last, item.state == .running {
                expectTrue(item.transferredBytes >= highest)
                highest = max(highest, item.transferredBytes)
            }
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
                try await LiveMergeChecks().run(
                    serial: ProcessInfo.processInfo.environment["GLASSBRIDGE_TEST_SERIAL"]!,
                    adbPath: ProcessInfo.processInfo.environment["GLASSBRIDGE_TEST_ADB"]!)
            } catch {
                fail(error.localizedDescription)
            }
            print(
                "\(failures == before ? "PASS" : "FAIL"): Live ADB round trip, duplicate names, and invalid destination"
            )
        } else {
            print("SKIP: Live Android checks (no test serial configured)")
        }
        if ProcessInfo.processInfo.environment["GLASSBRIDGE_TEST_TRASH"] == "1" {
            let before = failures
            do { try checkMacTrashRoundTrip() } catch { fail(error.localizedDescription) }
            print("\(failures == before ? "PASS" : "FAIL"): Mac Trash and restoration")
        }
        print("\(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
