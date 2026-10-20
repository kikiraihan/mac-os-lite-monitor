# LiteMonitor

Indikator sistem **ringan** untuk menu bar macOS: CPU, RAM, sisa SSD, kecepatan jaringan, dan baterai.
Ditulis dengan Swift + AppKit murni (tanpa SwiftUI/library tambahan), sekitar 15–25 MB RAM.

## Install

**Cara 1 — unduh jadi (tanpa Xcode):**
buka tab **Releases** (atau **Actions → run terbaru → Artifacts**), unduh `LiteMonitor.zip`,
ekstrak, pindahkan `LiteMonitor.app` ke **Applications**, lalu **klik kanan → Open** saat pertama kali.

**Cara 2 — installer (compile di Mac sendiri):**
klik kanan `install-LiteMonitor.command` → **Open**. Butuh Xcode Command Line Tools (installer akan memandu).

**Cara 3 — manual:**
```bash
./build.sh
mv LiteMonitor.app /Applications/ && open /Applications/LiteMonitor.app
```

Butuh macOS 13 (Ventura) atau lebih baru.

## Tips supaya ikon tidak tersembunyi

- Tahan **⌘** lalu seret ikon ke paling kanan (dekat jam).
- Aktifkan **Mode ringkas (1 baris)** di menu ikon.
- Matikan metrik yang tidak perlu lewat **Tampilkan di menu bar**.
