# AGENTS.md

Panduan untuk agen AI (Claude Code, dsb.) yang bekerja di repo ini.

## Versioning (wajib di setiap PR)

Format versi: `va.b.c` (Semantic Versioning). Versi disimpan di `Resources/Info.plist`:

- `CFBundleShortVersionString` → versi rilis, mis. `1.3.1` (jadi tag `v1.3.1`)
- `CFBundleVersion` → nomor build, **selalu +1** setiap kali versi naik

Aturan menaikkan versi:

| Bagian | Naik ketika | Contoh |
|---|---|---|
| `a` (major) | perubahan besar (sangat jarang) atau ada **breaking change** | `1.4.2` → `2.0.0` |
| `b` (minor) | ada **fitur baru**, atau **perubahan style mayor** | `1.4.2` → `1.5.0` |
| `c` (patch) | **perbaikan bug**, atau **perubahan style minor** (padding, warna, ukuran font, dll.) | `1.4.2` → `1.4.3` |

Ketentuan:

1. Setiap PR yang mengubah aplikasi **harus** menaikkan versi di `Resources/Info.plist`, karena rilis otomatis
   (`.github/workflows/build.yml`) hanya dibuat kalau tag `v<versi>` belum ada. Tanpa naik versi → tidak ada rilis.
2. Naikkan satu bagian saja sesuai perubahan terbesar di PR; bagian di kanannya di-reset ke `0`
   (naik `b` → `c` jadi `0`; naik `a` → `b` dan `c` jadi `0`).
3. Patokan versi adalah versi di `main` saat ini (cek juga tag terakhir dengan `git tag -l`), bukan versi di branch lama.
4. PR yang hanya mengubah dokumentasi / CI / file non-aplikasi tidak perlu naik versi.
5. Sebutkan versi baru di judul atau deskripsi PR (mis. "… (v1.4.0)"), dan beri tahu pengguna versi berapa yang akan dirilis.
