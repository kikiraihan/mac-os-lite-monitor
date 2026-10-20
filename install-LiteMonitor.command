#!/bin/bash
# ============================================================
#  Installer LiteMonitor — klik dua kali file ini di Finder
#  (compile + pasang ke /Applications + jalankan otomatis)
# ============================================================
set -e
clear
echo "=========================================="
echo "   Installer LiteMonitor"
echo "=========================================="

# 1. Cek versi macOS (butuh 13 Ventura ke atas)
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MAJOR" -lt 13 ]; then
  echo "❌ Butuh macOS 13 (Ventura) atau lebih baru. Versi Anda: $(sw_vers -productVersion)"
  read -n 1 -s -r -p "Tekan tombol apa saja untuk keluar..."; exit 1
fi

# 2. Cek compiler Swift (Xcode Command Line Tools)
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
  echo "⚠️  Xcode Command Line Tools belum terpasang."
  echo "   Jendela instalasi Apple akan muncul — klik 'Install' dan tunggu sampai selesai."
  echo "   Setelah itu, jalankan installer ini lagi."
  xcode-select --install 2>/dev/null || true
  read -n 1 -s -r -p "Tekan tombol apa saja untuk keluar..."; exit 0
fi

# 3. Siapkan folder kerja sementara
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# 4. Source code aplikasi
cat > main.swift <<'SWIFT_EOF'
// LiteMonitor — indikator sistem ringan untuk menu bar macOS
// Build: ./build.sh  (butuh Xcode Command Line Tools)

import Cocoa
import IOKit.ps
import ServiceManagement

// MARK: - Pengambil data (sampler)

let hostPort = mach_host_self()

final class CPUSampler {
    private var prev: (UInt32, UInt32, UInt32, UInt32)?

    /// Persentase CPU sejak pemanggilan sebelumnya
    func sample() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let t = info.cpu_ticks // (user, system, idle, nice)
        defer { prev = t }
        guard let p = prev else { return 0 }
        let user = Double(t.0 &- p.0), sys = Double(t.1 &- p.1)
        let idle = Double(t.2 &- p.2), nice = Double(t.3 &- p.3)
        let total = user + sys + idle + nice
        return total > 0 ? (user + sys + nice) / total * 100 : 0
    }
}

/// Memori terpakai ala Activity Monitor: App Memory + Wired + Compressed
func memoryInfo() -> (used: UInt64, total: UInt64) {
    let total = ProcessInfo.processInfo.physicalMemory
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return (0, total) }
    let page = UInt64(vm_kernel_page_size)
    let internal = UInt64(stats.internal_page_count)
    let purgeable = UInt64(stats.purgeable_count)
    let app = internal > purgeable ? internal - purgeable : 0
    let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    return (min(used, total), total)
}

final class NetSampler {
    private var lastIn: UInt64 = 0, lastOut: UInt64 = 0
    private var lastTime: TimeInterval = 0

    /// Kecepatan (byte/detik) untuk interface en* (Wi-Fi & Ethernet)
    func sample() -> (up: Double, down: Double) {
        var inB: UInt64 = 0, outB: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while let p = ptr {
                let ifa = p.pointee
                if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                   String(cString: ifa.ifa_name).hasPrefix("en"),
                   let raw = ifa.ifa_data {
                    let d = raw.assumingMemoryBound(to: if_data.self).pointee
                    inB += UInt64(d.ifi_ibytes)
                    outB += UInt64(d.ifi_obytes)
                }
                ptr = ifa.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastIn = inB; lastOut = outB; lastTime = now }
        guard lastTime > 0, now > lastTime else { return (0, 0) }
        let dt = now - lastTime
        // counter 32-bit bisa wrap; kalau turun anggap 0 untuk tick ini
        let dIn = inB >= lastIn ? Double(inB - lastIn) : 0
        let dOut = outB >= lastOut ? Double(outB - lastOut) : 0
        return (dOut / dt, dIn / dt)
    }
}

struct DiskInfo { let name: String; let used: Int64; let total: Int64 }

func diskInfo() -> DiskInfo? {
    let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey,
                                     .volumeAvailableCapacityForImportantUsageKey]
    guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
          let total = v.volumeTotalCapacity,
          let avail = v.volumeAvailableCapacityForImportantUsage else { return nil }
    return DiskInfo(name: v.volumeName ?? "Disk", used: Int64(total) - avail, total: Int64(total))
}

struct Battery { let percent: Int; let charging: Bool; let charged: Bool; let onAC: Bool }

func batteryInfo() -> Battery? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for ps in list {
        guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
              (d["Type"] as? String) == "InternalBattery",
              let cur = d["Current Capacity"] as? Int,
              let max = d["Max Capacity"] as? Int, max > 0 else { continue }
        return Battery(percent: cur * 100 / max,
                       charging: d["Is Charging"] as? Bool ?? false,
                       charged: d["Is Charged"] as? Bool ?? false,
                       onAC: (d["Power Source State"] as? String) == "AC Power")
    }
    return nil // Mac tanpa baterai (Mac mini / iMac)
}

// MARK: - Format angka

func fmtRate(_ b: Double, short: Bool) -> String {
    let k = b / 1024
    if k < 1000 { return String(format: short ? "%.1fK" : "%.1f KB/s", k) }
    return String(format: short ? "%.1fM" : "%.1f MB/s", k / 1024)
}
func gib(_ b: UInt64) -> Double { Double(b) / 1_073_741_824 }   // memori (biner)
func gbDec(_ b: Int64) -> Double { Double(b) / 1_000_000_000 }   // disk (desimal, sama seperti Finder)

// MARK: - Render gambar menu bar

struct Col { let top: String; let bottom: String; let topIsLabel: Bool; let template: String }
struct CompactItem { let symbol: String; let text: String; let template: String }

func textWidth(_ s: String, _ f: NSFont) -> CGFloat {
    (s as NSString).size(withAttributes: [.font: f]).width
}

/// Mode normal: 2 baris (label di atas, nilai di bawah), mirip contoh
func renderFull(_ cols: [Col]) -> NSImage {
    let labelFont = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
    let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    let gap: CGFloat = 8
    // lebar kolom dikunci pakai template supaya ikon tidak "goyang"
    let widths = cols.map { c -> CGFloat in
        let tf = c.topIsLabel ? labelFont : valueFont
        return ceil(max(textWidth(c.top, tf), textWidth(c.bottom, valueFont), textWidth(c.template, valueFont)))
    }
    let total = widths.reduce(0, +) + gap * CGFloat(max(cols.count - 1, 0))
    let img = NSImage(size: NSSize(width: max(total, 1), height: 22), flipped: true) { _ in
        let ps = NSMutableParagraphStyle(); ps.alignment = .center
        var x: CGFloat = 0
        for (i, c) in cols.enumerated() {
            let topAttr: [NSAttributedString.Key: Any] = [
                .font: c.topIsLabel ? labelFont : valueFont, .foregroundColor: NSColor.black, .paragraphStyle: ps]
            let botAttr: [NSAttributedString.Key: Any] = [
                .font: valueFont, .foregroundColor: NSColor.black, .paragraphStyle: ps]
            (c.top as NSString).draw(in: NSRect(x: x, y: 0, width: widths[i], height: 11), withAttributes: topAttr)
            (c.bottom as NSString).draw(in: NSRect(x: x, y: 10, width: widths[i], height: 12), withAttributes: botAttr)
            x += widths[i] + gap
        }
        return true
    }
    img.isTemplate = true // otomatis ikut warna menu bar (terang/gelap)
    return img
}

/// Mode ringkas: 1 baris, ikon SF Symbol + angka (paling hemat tempat)
func renderCompact(_ items: [CompactItem]) -> NSImage {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
    let icon: CGFloat = 13, iconGap: CGFloat = 2, gap: CGFloat = 7
    let widths = items.map { ceil(max(textWidth($0.text, font), textWidth($0.template, font))) }
    var total: CGFloat = 0
    for w in widths { total += icon + iconGap + w }
    total += gap * CGFloat(max(items.count - 1, 0))
    let img = NSImage(size: NSSize(width: max(total, 1), height: 22), flipped: true) { _ in
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textH = font.ascender - font.descender
        var x: CGFloat = 0
        for (i, it) in items.enumerated() {
            if let sym = NSImage(systemSymbolName: it.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) {
                let s = sym.size
                let scale = min(icon / max(s.width, 1), icon / max(s.height, 1), 1)
                let w = s.width * scale, h = s.height * scale
                sym.draw(in: NSRect(x: x + (icon - w) / 2, y: (22 - h) / 2, width: w, height: h))
            }
            x += icon + iconGap
            (it.text as NSString).draw(at: NSPoint(x: x, y: (22 - textH) / 2), withAttributes: attr)
            x += widths[i] + gap
        }
        return true
    }
    img.isTemplate = true
    return img
}

// MARK: - Aplikasi

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let d = UserDefaults.standard

    let cpu = CPUSampler()
    let net = NetSampler()
    var timer: Timer?
    var tick = 0
    var menuOpen = false

    // nilai terakhir
    var cpuPct = 0.0
    var mem: (used: UInt64, total: UInt64) = (0, 1)
    var rate: (up: Double, down: Double) = (0, 0)
    var disk: DiskInfo?
    var bat: Battery?

    // baris info di menu
    let cpuRow = NSMenuItem(), memRow = NSMenuItem(), diskRow = NSMenuItem()
    let netRow = NSMenuItem(), batRow = NSMenuItem()

    // item pengaturan
    let metrics: [(key: String, title: String)] = [
        ("showCPU", "CPU"), ("showRAM", "RAM"), ("showDisk", "SSD"),
        ("showNet", "Jaringan"), ("showBat", "Baterai")]
    var metricItems: [NSMenuItem] = []
    var intervalItems: [NSMenuItem] = []
    let compactItem = NSMenuItem(title: "Mode ringkas (1 baris)", action: #selector(toggleCompact), keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Buka saat login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ n: Notification) {
        d.register(defaults: ["showCPU": true, "showRAM": true, "showDisk": false,
                              "showNet": true, "showBat": false,
                              "compact": false, "interval": 2.0])
        statusItem.autosaveName = "LiteMonitor" // posisi ikon diingat
        statusItem.button?.imagePosition = .imageOnly
        buildMenu()
        statusItem.menu = menu
        _ = cpu.sample(); _ = net.sample() // sampel awal (baseline)
        refresh(full: true)
        startTimer()
    }

    func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: d.double(forKey: "interval"), repeats: true) { [weak self] _ in
            self?.refresh(full: false)
        }
        t.tolerance = 0.5 // biarkan macOS menggabungkan wakeup → hemat energi
        RunLoop.main.add(t, forMode: .common) // tetap jalan saat menu terbuka
        timer = t
    }

    func refresh(full: Bool) {
        cpuPct = cpu.sample()
        mem = memoryInfo()
        rate = net.sample()
        tick += 1
        // disk & baterai jarang berubah → diambil lebih jarang
        if full || tick % 15 == 0 { disk = diskInfo() }
        if full || tick % 5 == 0 { bat = batteryInfo() }
        updateBar()
        if menuOpen { updateRows() }
    }

    // MARK: menu bar

    func updateBar() {
        let memPct = Double(mem.used) / Double(max(mem.total, 1)) * 100
        let compact = d.bool(forKey: "compact")
        var cols: [Col] = []
        var items: [CompactItem] = []

        if d.bool(forKey: "showCPU") {
            let v = String(format: "%.0f%%", cpuPct)
            cols.append(Col(top: "CPU", bottom: v, topIsLabel: true, template: "100%"))
            items.append(CompactItem(symbol: "cpu", text: v, template: "100%"))
        }
        if d.bool(forKey: "showRAM") {
            let v = String(format: "%.0f%%", memPct)
            cols.append(Col(top: "RAM", bottom: v, topIsLabel: true, template: "100%"))
            items.append(CompactItem(symbol: "memorychip", text: v, template: "100%"))
        }
        if d.bool(forKey: "showDisk"), let dk = disk {
            let v = String(format: "%.0fGB", gbDec(dk.total - dk.used)) // sisa ruang
            cols.append(Col(top: "SSD", bottom: v, topIsLabel: true, template: "999GB"))
            items.append(CompactItem(symbol: "internaldrive", text: v, template: "999GB"))
        }
        if d.bool(forKey: "showNet") {
            let up = fmtRate(rate.up, short: true), dn = fmtRate(rate.down, short: true)
            cols.append(Col(top: "↑" + up, bottom: "↓" + dn, topIsLabel: false, template: "↓999.9K"))
            items.append(CompactItem(symbol: "arrow.up.arrow.down", text: "↓" + dn, template: "↓999.9K"))
        }
        if d.bool(forKey: "showBat"), let b = bat {
            let v = (b.onAC ? "⚡" : "") + "\(b.percent)%"
            cols.append(Col(top: "BAT", bottom: v, topIsLabel: true, template: "⚡100%"))
            items.append(CompactItem(symbol: b.onAC ? "battery.100.bolt" : "battery.100",
                                     text: "\(b.percent)%", template: "100%"))
        }

        guard let button = statusItem.button else { return }
        if cols.isEmpty {
            // semua metrik dimatikan → tampilkan ikon kecil saja supaya menu tetap bisa dibuka
            button.image = NSImage(systemSymbolName: "gauge", accessibilityDescription: "LiteMonitor")
        } else {
            button.image = compact ? renderCompact(items) : renderFull(cols)
        }
    }

    // MARK: menu dropdown

    func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self

        let rows: [(NSMenuItem, String)] = [(cpuRow, "cpu"), (memRow, "memorychip"),
                                            (diskRow, "internaldrive"), (netRow, "network"),
                                            (batRow, "battery.100")]
        for (row, sym) in rows {
            row.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
            row.isEnabled = true // tanpa action → hanya tampilan, warna tetap normal
            menu.addItem(row)
        }
        menu.addItem(.separator())

        // submenu: metrik yang tampil di menu bar
        let showMenu = NSMenu()
        for m in metrics {
            let it = NSMenuItem(title: m.title, action: #selector(toggleMetric(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = m.key
            showMenu.addItem(it)
            metricItems.append(it)
        }
        let showItem = NSMenuItem(title: "Tampilkan di menu bar", action: nil, keyEquivalent: "")
        showItem.submenu = showMenu
        menu.addItem(showItem)

        compactItem.target = self
        menu.addItem(compactItem)

        // submenu: interval update
        let intMenu = NSMenu()
        for s in [1.0, 2.0, 5.0] {
            let it = NSMenuItem(title: "\(Int(s)) detik", action: #selector(setInterval(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = s
            intMenu.addItem(it)
            intervalItems.append(it)
        }
        let intItem = NSMenuItem(title: "Interval update", action: nil, keyEquivalent: "")
        intItem.submenu = intMenu
        menu.addItem(intItem)

        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let am = NSMenuItem(title: "Buka Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "")
        am.target = self
        menu.addItem(am)
        menu.addItem(NSMenuItem(title: "Keluar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func updateRows() {
        let memPct = Double(mem.used) / Double(max(mem.total, 1)) * 100
        cpuRow.title = String(format: "CPU: %.0f%%", cpuPct)
        memRow.title = String(format: "Memori: %.1f dari %.0f GB (%.0f%%)", gib(mem.used), gib(mem.total), memPct)
        if let dk = disk {
            diskRow.title = String(format: "%@: %.0f dari %.0f GB terpakai — sisa %.0f GB",
                                   dk.name, gbDec(dk.used), gbDec(dk.total), gbDec(dk.total - dk.used))
        } else {
            diskRow.title = "Disk: tidak terbaca"
        }
        netRow.title = "Jaringan: ↑ \(fmtRate(rate.up, short: false))   ↓ \(fmtRate(rate.down, short: false))"
        if let b = bat {
            let state = b.charged ? "Terisi penuh" : b.charging ? "Mengisi daya" : b.onAC ? "Terhubung charger" : "Pakai baterai"
            batRow.title = "Baterai: \(b.percent)% — \(state)"
            batRow.isHidden = false
        } else {
            batRow.isHidden = true
        }
    }

    func updateChecks() {
        for it in metricItems {
            it.state = d.bool(forKey: it.representedObject as? String ?? "") ? .on : .off
        }
        compactItem.state = d.bool(forKey: "compact") ? .on : .off
        let cur = d.double(forKey: "interval")
        for it in intervalItems { it.state = (it.representedObject as? Double) == cur ? .on : .off }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        disk = diskInfo(); bat = batteryInfo()
        updateRows()
        updateChecks()
    }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    // MARK: aksi

    @objc func toggleMetric(_ s: NSMenuItem) {
        guard let k = s.representedObject as? String else { return }
        d.set(!d.bool(forKey: k), forKey: k)
        updateChecks(); updateBar()
    }
    @objc func toggleCompact() {
        d.set(!d.bool(forKey: "compact"), forKey: "compact")
        updateChecks(); updateBar()
    }
    @objc func setInterval(_ s: NSMenuItem) {
        guard let v = s.representedObject as? Double else { return }
        d.set(v, forKey: "interval")
        updateChecks(); startTimer()
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Gagal mengatur 'Buka saat login'"
            a.informativeText = "Pastikan LiteMonitor.app ada di folder Applications.\n\n\(error.localizedDescription)"
            a.runModal()
        }
        updateChecks()
    }
    @objc func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // tanpa ikon di Dock
app.run()
SWIFT_EOF

APP="LiteMonitor.app"
echo "▶ Compile (± 30 detik)..."
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/LiteMonitor"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LiteMonitor</string>
    <key>CFBundleDisplayName</key><string>LiteMonitor</string>
    <key>CFBundleIdentifier</key><string>id.local.litemonitor</string>
    <key>CFBundleExecutable</key><string>LiteMonitor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "▶ Codesign (ad-hoc)..."
codesign --force --sign - "$APP"

# 5. Tutup versi lama (kalau ada), lalu pasang
pkill -x LiteMonitor 2>/dev/null || true
DEST="/Applications"
if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
rm -rf "$DEST/$APP"
cp -R "$APP" "$DEST/"
xattr -cr "$DEST/$APP" 2>/dev/null || true

echo "▶ Menjalankan LiteMonitor..."
open "$DEST/$APP"

echo ""
echo "✅ Selesai! LiteMonitor terpasang di: $DEST/$APP"
echo "   • Lihat ikonnya di menu bar (kanan atas)."
echo "   • Tahan ⌘ lalu seret ikon ke dekat jam supaya tidak tersembunyi."
echo "   • Centang 'Buka saat login' di menu ikon agar otomatis jalan."
echo ""
read -n 1 -s -r -p "Tekan tombol apa saja untuk menutup jendela ini..."
