import XCTest
@testable import RinkMasterCore

/// Records the commands it is asked to run and returns canned results.
final class RecordingRunner: ProcessRunning, @unchecked Sendable {
    var calls: [(String, [String])] = []
    var result = CommandResult(status: 0, stdout: "ok\n", stderr: "")
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        calls.append((executable, arguments)); return result
    }
}

final class SSHShellTests: XCTestCase {
    func testRunBuildsBatchModeSSHCommand() async throws {
        let runner = RecordingRunner()
        let shell = SSHShell(target: SSHTarget(user: "pi", host: "cabinet1.lan"), runner: runner)
        let out = try await shell.run("ls /home/pi/RetroPie/roms")
        XCTAssertEqual(out.stdout, "ok\n")
        let (exe, args) = runner.calls[0]
        XCTAssertEqual(exe, "/usr/bin/ssh")
        XCTAssertEqual(args, ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "pi@cabinet1.lan", "ls /home/pi/RetroPie/roms"])
    }

    func testFetchUsesRsyncOverSSHWithQuotedRemotePath() async throws {
        let runner = RecordingRunner()
        let shell = SSHShell(target: SSHTarget(user: "tester", host: "cabinet2.lan"), runner: runner)
        _ = try await shell.fetch(remotePath: "/home/pi/RetroPie/roms/my games/", to: "/tmp/out/")
        let (exe, args) = runner.calls[0]
        XCTAssertEqual(exe, "/usr/bin/rsync")
        XCTAssertEqual(args, ["-rlt", "-e", "ssh -o BatchMode=yes -o ConnectTimeout=8",
                              "tester@cabinet2.lan:'/home/pi/RetroPie/roms/my games/'", "/tmp/out/"])
    }

    func testPushPutsLocalFirstThenRemote() async throws {
        let runner = RecordingRunner()
        let shell = SSHShell(target: SSHTarget(user: "pi", host: "cabinet1.lan"), runner: runner)
        _ = try await shell.push(localPath: "/tmp/galaga.zip", toRemotePath: "/home/pi/RetroPie/roms/mame-libretro/")
        let args = runner.calls[0].1
        XCTAssertEqual(args.suffix(2), ["/tmp/galaga.zip", "pi@cabinet1.lan:'/home/pi/RetroPie/roms/mame-libretro/'"])
    }

    func testNonZeroExitThrowsWithStderr() async {
        let runner = RecordingRunner()
        runner.result = CommandResult(status: 255, stdout: "", stderr: "Permission denied")
        let shell = SSHShell(target: SSHTarget(user: "pi", host: "h"), runner: runner)
        do {
            _ = try await shell.run("true")
            XCTFail("expected failure")
        } catch let error as RemoteError {
            XCTAssertEqual(error, .commandFailed(status: 255, stderr: "Permission denied"))
        } catch { XCTFail("wrong error \(error)") }
    }

    func testOpenSSHPostQuantumBannerIsStrippedSoTheRealErrorShows() async {
        let runner = RecordingRunner()
        runner.result = CommandResult(status: 23, stdout: "", stderr: """
            ** WARNING: connection is not using a post-quantum key exchange algorithm.
            ** This session may be vulnerable to "store now, decrypt later" attacks.
            ** The server may need to be upgraded. See https://openssh.com/pq.html
            rsync: [receiver] mkstemp "/x/.sf2.zip.AbC" failed: Permission denied (13)

            """)
        let shell = SSHShell(target: SSHTarget(user: "pi", host: "h"), runner: runner)
        do { _ = try await shell.push(localPath: "a", toRemotePath: "/x/"); XCTFail("expected failure") }
        catch let error as RemoteError {
            XCTAssertEqual(error, .commandFailed(status: 23, stderr: "rsync: [receiver] mkstemp \"/x/.sf2.zip.AbC\" failed: Permission denied (13)"))
        } catch { XCTFail("wrong error \(error)") }
    }

    func testBannerOnlyStderrBecomesAGenericMessage() async {
        let runner = RecordingRunner()
        runner.result = CommandResult(status: 1, stdout: "", stderr: "** WARNING: connection is not using a post-quantum key exchange algorithm.\n")
        do { _ = try await SSHShell(target: SSHTarget(user: "pi", host: "h"), runner: runner).run("false"); XCTFail() }
        catch let error as RemoteError { XCTAssertEqual(error, .commandFailed(status: 1, stderr: "")) }
        catch { XCTFail("\(error)") }
    }

    func testTargetDescriptionAndValidation() {
        XCTAssertEqual(SSHTarget(user: "pi", host: "a.lan").destination, "pi@a.lan")
        XCTAssertTrue(SSHTarget(user: "pi", host: "a.lan").isValid)
        XCTAssertFalse(SSHTarget(user: "", host: "a.lan").isValid)
        XCTAssertFalse(SSHTarget(user: "pi", host: "a b").isValid)
        XCTAssertFalse(SSHTarget(user: "pi;x", host: "a.lan").isValid)
    }
}
