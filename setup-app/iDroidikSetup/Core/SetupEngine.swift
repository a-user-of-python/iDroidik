import Foundation
import CryptoKit
import Security

/// Runs the on-device iDroidik setup, mirroring setup-device.sh and
/// tools/gen-firmware.sh. All operations run locally as root — no Mac, no SSH.
///
/// Safety rules (from docs/STATE.md):
/// - NEVER restore/erase the iPhone; only ADD an APFS volume.
/// - Only writes inside the "Android" volume (mounted at /var/mnt/android).
/// - Firmware is copied from the phone's own iOS — never downloaded.
final class SetupEngine {

    private let state: SetupState
    private let fm = FileManager.default

    init(state: SetupState) {
        self.state = state
    }

    // MARK: - Step 1: Preflight

    /// Returns true if all checks pass.
    func runPreflight() -> Bool {
        state.appendLog("Running preflight checks…")

        // Must be root (the .deb postinst makes the binary setuid root).
        let uid = getuid()
        state.isRoot = (uid == 0)
        state.appendLog("uid = \(uid)")
        guard state.isRoot else {
            state.fail("Not running as root (uid \(uid)). Reinstall the .deb from Sileo — postinst must set the setuid bit.")
            return false
        }

        // Device model must be iPhone 7.
        let model = Shell.run("/usr/bin/sysctl", args: ["-n", "hw.machine"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        state.deviceModel = model
        state.appendLog("hw.machine = \(model)")
        guard model == "iPhone9,1" || model == "iPhone9,3" else {
            state.fail("This is not an iPhone 7 (found '\(model)'). iDroidik only supports iPhone9,1 / iPhone9,3.")
            return false
        }

        // iOS 15.x required.
        let ver = readIOSVersion()
        state.iosVersion = ver
        state.appendLog("iOS version = \(ver)")
        guard ver.hasPrefix("15.") else {
            state.fail("iOS \(ver) is not supported — iDroidik targets iOS 15.x only.")
            return false
        }

        // Free space on the shared APFS container (use /var).
        if let free = Shell.freeBytes(atPath: "/var") {
            state.freeBytes = free
            state.appendLog("free space: \(formatGB(free))")
        } else {
            state.fail("Could not read free space — refusing to continue blind.")
            return false
        }

        state.preflightPassed = true
        state.appendLog("Preflight passed.")
        return true
    }

    private func readIOSVersion() -> String {
        let r = Shell.run("/usr/bin/plutil", args: [
            "-extract", "ProductVersion", "raw",
            "/System/Library/CoreServices/SystemVersion.plist"
        ])
        let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty { return v }
        let r2 = Shell.sh("grep -a -oE '1[0-9]\\.[0-9]+(\\.[0-9]+)?' /System/Library/CoreServices/SystemVersion.plist 2>/dev/null | head -1")
        return r2.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Step 2: APFS volume

    /// Finds the "Android" volume device node, or "" if none.
    func findAndroidVolume() -> String {
        let r = Shell.sh("""
            for d in /dev/disk0s1s*; do
              [ -b "$d" ] || continue
              [ "$(/System/Library/Filesystems/apfs.fs/apfs.util -p "$d" 2>/dev/null)" = "Android" ] && { echo "$d"; break; }
            done
            """)
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Creates the volume. Only call after user confirmation.
    func createAndroidVolume() -> Bool {
        state.appendLog("Creating APFS volume 'Android' (additive — iOS is not touched)…")
        let r = Shell.run("/sbin/newfs_apfs", args: ["-A", "-v", "Android", "-e", "/dev/disk0s1"])
        if !r.succeeded {
            state.fail("newfs_apfs failed: \(r.stderr)")
            return false
        }
        // Re-scan for it.
        sleep(2)
        let dev = findAndroidVolume()
        guard !dev.isEmpty else {
            state.fail("Volume created but could not be found afterwards.")
            return false
        }
        state.androidVolumeDevice = dev
        state.appendLog("Android volume: \(dev)")
        return true
    }

    func mountAndroidVolume() -> Bool {
        let mp = state.mountPoint
        try? fm.createDirectory(atPath: mp, withIntermediateDirectories: true)
        let mounted = Shell.sh("mount | grep -q ' \(mp) ' || mount | grep -q '\(mp)$'").succeeded
        // Simpler: check via mount output containing the mount point.
        let check = Shell.sh("mount | grep -q '\(mp)'").succeeded
        if check {
            state.appendLog("Already mounted at \(mp).")
            return true
        }
        let dev = state.androidVolumeDevice
        guard !dev.isEmpty else {
            state.fail("No Android volume device known — cannot mount.")
            return false
        }
        let r = Shell.run("/sbin/mount", args: ["-t", "apfs", dev, mp])
        if !r.succeeded {
            state.fail("mount failed: \(r.stderr)")
            return false
        }
        state.appendLog("Mounted \(dev) at \(mp).")
        return true
    }

    func unmountAndroidVolume() {
        _ = Shell.run("/sbin/umount", args: [state.mountPoint])
    }

    // MARK: - Step 3: Image download

    struct ImagePart {
        let sha256: String
        let filename: String
    }

    /// Fetches the parts manifest and parses it.
    func fetchPartsManifest() -> [ImagePart]? {
        let urlStr = "\(state.releaseBaseURL)/\(state.imageName).parts.sha256"
        guard let url = URL(string: urlStr) else {
            state.fail("Bad manifest URL.")
            return nil
        }
        state.appendLog("Fetching parts manifest…")
        var parts: [ImagePart]? = nil
        var fetchError: String? = nil
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { data, _, error in
            defer { sem.signal() }
            if let error = error { fetchError = error.localizedDescription; return }
            guard let data = data, let text = String(data: data, encoding: .utf8) else {
                fetchError = "empty manifest"; return
            }
            var out: [ImagePart] = []
            for line in text.components(separatedBy: "\n") {
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count >= 2 else { continue }
                let sha = String(fields[0])
                let name = String(fields[1]).trimmingCharacters(in: .init(charactersIn: "*"))
                // Reject path traversal.
                if name.contains("/") || name.contains("..") { continue }
                out.append(ImagePart(sha256: sha, filename: name))
            }
            parts = out
        }.resume()
        sem.wait()
        if let e = fetchError {
            state.fail("Could not fetch parts manifest: \(e)")
            return nil
        }
        guard let p = parts, !p.isEmpty else {
            state.fail("Parts manifest was empty.")
            return nil
        }
        state.appendLog("Manifest lists \(p.count) parts.")
        return p
    }

    /// Downloads parts, verifies each sha256, appends to nand.part, then
    /// verifies the whole image and renames to nand. Returns true on success.
    /// If nand already exists with the right hash, skips everything.
    func downloadImage(parts: [ImagePart], progress: @escaping (Double, String) -> Void) -> Bool {
        let mp = state.mountPoint
        let finalPath = "\(mp)/nand"
        let partPath = "\(mp)/nand.part"

        // Skip if already present and correct.
        if fm.fileExists(atPath: finalPath) {
            state.appendLog("Checking existing nand image hash (takes ~1 min for 3 GB)…")
            progress(0.05, "Verifying existing image…")
            if let hash = sha256OfFile(atPath: finalPath, progress: { f in
                progress(0.05 + 0.9 * f, "Verifying existing image…")
            }), hash.lowercased() == state.expectedImageSHA256.lowercased() {
                state.imageAlreadyPresent = true
                state.appendLog("Image already on phone and matches — skipping download.")
                progress(1.0, "Image verified.")
                return true
            }
            state.appendLog("Existing image hash mismatch — re-downloading.")
            try? fm.removeItem(atPath: finalPath)
        }

        // Free-space gate: parts are deleted as they are joined, so we need
        // image size + 1 GB headroom (parts stream through, not stored twice).
        guard let free = Shell.freeBytes(atPath: mp) else {
            state.fail("Could not read free space — refusing to download blind.")
            return false
        }
        // Estimate total from manifest is not available; use 3.5 GB estimate + headroom.
        let need = state.estimatedImageBytes + 1_073_741_824
        guard free > need else {
            state.fail("Not enough space: need ~\(formatGB(need)), have \(formatGB(free)). Free space in iOS first.")
            return false
        }

        // Remove any stale partial download.
        try? fm.removeItem(atPath: partPath)
        fm.createFile(atPath: partPath, contents: nil)

        guard let outHandle = FileHandle(forWritingAtPath: partPath) else {
            state.fail("Could not open \(partPath) for writing.")
            return false
        }
        defer { try? outHandle.close() }

        let totalParts = parts.count
        for (idx, part) in parts.enumerated() {
            let label = "Part \(idx + 1)/\(totalParts): \(part.filename)"
            state.appendLog("Downloading \(part.filename)…")
            progress(Double(idx) / Double(totalParts) * 0.85, label)

            guard let data = downloadData(
                urlString: "\(state.releaseBaseURL)/\(part.filename)",
                progress: { f in
                    let overall = (Double(idx) + f) / Double(totalParts) * 0.85
                    progress(overall, label)
                }
            ) else {
                try? fm.removeItem(atPath: partPath)
                return false // downloadData already called fail()
            }

            // Verify part hash before appending.
            let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard got.lowercased() == part.sha256.lowercased() else {
                state.fail("Part \(part.filename) checksum mismatch — deleted partial download.")
                try? fm.removeItem(atPath: partPath)
                return false
            }
            outHandle.write(data)
            state.appendLog("  ✓ \(part.filename) (\(formatBytes(Int64(data.count))) verified)")
        }

        try? outHandle.close()
        progress(0.9, "Verifying full image…")
        state.appendLog("Verifying reassembled image sha256…")
        guard let whole = sha256OfFile(atPath: partPath, progress: { f in
            progress(0.9 + 0.08 * f, "Verifying full image…")
        }) else {
            try? fm.removeItem(atPath: partPath)
            return false
        }
        guard whole.lowercased() == state.expectedImageSHA256.lowercased() else {
            state.fail("Image checksum mismatch after download (got \(whole.prefix(16))…). Deleted.")
            try? fm.removeItem(atPath: partPath)
            return false
        }

        do {
            if fm.fileExists(atPath: finalPath) { try fm.removeItem(atPath: finalPath) }
            try fm.moveItem(atPath: partPath, toPath: finalPath)
        } catch {
            state.fail("Could not finalize image: \(error.localizedDescription)")
            return false
        }
        _ = Shell.run("/bin/sync", args: [])
        progress(1.0, "Image ready.")
        state.appendLog("Image on phone, checksum verified.")
        return true
    }

    /// Downloads data with progress reporting. Returns nil on failure (fail() called).
    private func downloadData(urlString: String, progress: @escaping (Double) -> Void) -> Data? {
        guard let url = URL(string: urlString) else {
            state.fail("Bad URL: \(urlString)")
            return nil
        }
        var result: Data? = nil
        var dlError: String? = nil
        let sem = DispatchSemaphore(value: 0)
        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        delegate.completion = { data, error in
            result = data
            dlError = error
            sem.signal()
        }
        session.dataTask(with: url).resume()
        // Pump the runloop so delegate callbacks fire while we wait.
        while sem.wait(timeout: .now() + 0.25) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        session.invalidateAndCancel()
        if let e = dlError {
            state.fail("Download failed: \(e)")
            return nil
        }
        return result
    }

    private final class DownloadDelegate: NSObject, URLSessionDataDelegate {
        let progress: (Double) -> Void
        var completion: ((Data?, String?) -> Void)?
        private var data = Data()
        private var expected: Int64 = 0

        init(progress: @escaping (Double) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            expected = response.expectedContentLength
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            data.append(chunk)
            if expected > 0 {
                DispatchQueue.main.async { self.progress(Double(self.data.count) / Double(self.expected)) }
            }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = error {
                completion?(nil, error.localizedDescription)
            } else {
                completion?(data, nil)
            }
        }
    }

    /// Streams a file through SHA256 without loading it into memory.
    func sha256OfFile(atPath path: String, progress: @escaping (Double) -> Void) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            state.fail("Could not open \(path) for hashing.")
            return nil
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        let attrs = try? fm.attributesOfItem(atPath: path)
        let total = (attrs?[.size] as? Int64) ?? 0
        var done: Int64 = 0
        while true {
            let chunk = handle.readData(ofLength: 8 * 1024 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            done += Int64(chunk.count)
            if total > 0 {
                let f = Double(done) / Double(total)
                DispatchQueue.main.async { progress(f) }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Step 4: Firmware (on-device, from the phone's own iOS)

    /// Copies touch + Wi-Fi firmware from the phone's own iOS into the
    /// Android volume. NOTHING is downloaded — this is the legal requirement.
    func generateFirmware() -> Bool {
        let src = "/usr/share/firmware"
        let dst = "\(state.mountPoint)/usr/share/firmware"
        state.appendLog("Copying firmware from this phone's own iOS (nothing downloaded)…")

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src, isDirectory: &isDir), isDir.boolValue else {
            state.fail("iOS firmware dir \(src) not found on this iOS build.")
            return false
        }

        var copiedAny = false
        var fileCount = 0
        for sub in ["multitouch", "wifi"] {
            let s = "\(src)/\(sub)"
            var sd: ObjCBool = false
            guard fm.fileExists(atPath: s, isDirectory: &sd), sd.boolValue else {
                state.appendLog("  (no \(s) on this iOS — skipping)")
                continue
            }
            let d = "\(dst)/\(sub)"
            do {
                try fm.createDirectory(atPath: d, withIntermediateDirectories: true)
                // cp -a semantics: copy contents recursively, preserving attributes.
                let r = Shell.run("/bin/cp", args: ["-a", "\(s)/.", "\(d)/"])
                guard r.succeeded else {
                    state.fail("cp failed for \(sub): \(r.stderr)")
                    return false
                }
                copiedAny = true
                state.appendLog("  copied \(sub)")
            } catch {
                state.fail("Could not create \(d): \(error.localizedDescription)")
                return false
            }
        }
        guard copiedAny else {
            state.fail("Nothing copied — no firmware found on iOS.")
            return false
        }
        _ = Shell.run("/bin/sync", args: [])
        // Count files for the summary.
        let count = Shell.sh("find '\(dst)' -type f 2>/dev/null | wc -l").stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        state.firmwareFileCount = Int(count) ?? 0
        state.appendLog("Firmware on Android volume: \(state.firmwareFileCount) files.")
        return true
    }

    // MARK: - Step 5: userdata.img (persistent /data)

    /// Creates userdata.img with nonce-tagged 4K blocks:
    /// "SCUDATA1" + nonce u64 LE + index u64 LE + total u64 LE + 4064 zero bytes.
    /// Writes the nonce to <mountPoint>/userdata-a16.conf for the boot script.
    func provisionUserdata(gb: Int, progress: @escaping (Double, String) -> Void) -> Bool {
        guard gb >= 2 else {
            state.fail("userdata size must be ≥ 2 GB.")
            return false
        }
        let mp = state.mountPoint
        let imgPath = "\(mp)/userdata.img"
        let partPath = "\(mp)/userdata.img.part"
        let confPath = "\(mp)/userdata-a16.conf"

        if fm.fileExists(atPath: imgPath) {
            // Keep existing if a nonce conf is present.
            if fm.fileExists(atPath: confPath),
               let conf = try? String(contentsOfFile: confPath),
               conf.contains("UD_NONCE=") {
                state.appendLog("userdata.img already exists with a nonce — keeping it.")
                // Read back the nonce for display.
                for line in conf.components(separatedBy: "\n") where line.hasPrefix("UD_NONCE=") {
                    state.userdataNonce = String(line.dropFirst("UD_NONCE=".count))
                }
                progress(1.0, "Already provisioned.")
                return true
            }
            state.appendLog("userdata.img exists but no nonce conf — removing and re-provisioning.")
            try? fm.removeItem(atPath: imgPath)
        }

        // Free-space gate: keep ≥3 GB for iOS.
        guard let free = Shell.freeBytes(atPath: mp) else {
            state.fail("Could not read free space — refusing to write a multi-GB file blind.")
            return false
        }
        let need = Int64(gb) * 1_073_741_824
        guard free > need + 3 * 1_073_741_824 else {
            state.fail("Not enough space for \(gb) GB userdata + 3 GB iOS headroom (have \(formatGB(free))).")
            return false
        }

        // 16 random hex chars = 64-bit nonce.
        var nonceBytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, 8, &nonceBytes)
        let nonce = nonceBytes.map { String(format: "%02x", $0) }.joined()
        let nonceU64 = nonceBytes.withUnsafeBytes { $0.load(as: UInt64.self) }
        state.appendLog("Creating \(gb) GB userdata.img (nonce \(nonce))…")

        let totalBlocks = gb * 262_144  // 1 GB = 262144 × 4K blocks
        try? fm.removeItem(atPath: partPath)
        fm.createFile(atPath: partPath, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: partPath) else {
            state.fail("Could not open \(partPath) for writing.")
            return false
        }

        // Write in 4 MB chunks (1024 blocks) to keep memory flat.
        let blocksPerChunk = 1024
        var header = Data()
        header.append(contentsOf: "SCUDATA1".utf8)
        var le = nonceU64.littleEndian
        header.append(Data(bytes: &le, count: 8))
        // index + total vary per block; padding is zeros.
        let padding = Data(count: 4064)

        var failed = false
        var block = 0
        while block < totalBlocks && !failed {
            let n = min(blocksPerChunk, totalBlocks - block)
            var chunk = Data()
            chunk.reserveCapacity(n * 4096)
            for i in 0..<n {
                let idx = UInt64(block + i)
                var idxLE = idx.littleEndian
                var totalLE = UInt64(totalBlocks).littleEndian
                chunk.append(header)                       // magic + nonce
                chunk.append(Data(bytes: &idxLE, count: 8)) // index
                chunk.append(Data(bytes: &totalLE, count: 8))// total
                chunk.append(padding)                      // 4064 zeros
            }
            handle.write(chunk)
            block += n
            let f = Double(block) / Double(totalBlocks)
            DispatchQueue.main.async {
                progress(f, "Writing userdata.img… \(Int(f * 100))%")
            }
            // Yield periodically so the UI stays alive.
            if block % 16384 == 0 { Thread.sleep(forTimeInterval: 0.01) }
        }
        try? handle.close()

        if failed {
            try? fm.removeItem(atPath: partPath)
            return false
        }

        // Verify size.
        let attrs = try? fm.attributesOfItem(atPath: partPath)
        let gotSize = (attrs?[.size] as? Int64) ?? -1
        guard gotSize == Int64(gb) * 1_073_741_824 else {
            state.fail("userdata.img has wrong size (\(gotSize)). Deleted.")
            try? fm.removeItem(atPath: partPath)
            return false
        }
        do {
            if fm.fileExists(atPath: imgPath) { try fm.removeItem(atPath: imgPath) }
            try fm.moveItem(atPath: partPath, toPath: imgPath)
            try "UD_NONCE=\(nonce)\nUD_HDR=\n".write(toFile: confPath, atomically: true, encoding: .utf8)
        } catch {
            state.fail("Could not finalize userdata.img: \(error.localizedDescription)")
            return false
        }
        _ = Shell.run("/bin/sync", args: [])
        state.userdataNonce = nonce
        progress(1.0, "userdata.img ready.")
        state.appendLog("Persistent /data provisioned (\(gb) GB). Nonce saved to userdata-a16.conf.")
        return true
    }

    // MARK: - Helpers

    func formatGB(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824.0)
    }

    func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 { return formatGB(bytes) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
    }
}
