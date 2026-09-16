# Wiring Peltier ON/OFF pakai MOSFET IRLZ44N (ESP32-C3)

Fan TETAP jalan terus seperti biasa (tidak diubah). Yang di on/off dari
app cuma Peltier-nya saja, lewat MOSFET IRLZ44N sebagai saklar low-side.

## Kenapa IRLZ44N cocok

IRLZ44N itu **logic-level MOSFET** (N-channel), jadi gate-nya bisa
di-drive langsung dari GPIO 3.3V ESP32 tanpa perlu driver tambahan.
Arus peltier (TEC1-12706 dkk bisa sampai 5-6A) jauh di bawah rating
IRLZ44N (~47A, tapi itu angka datasheet ideal — praktiknya tetap pakai
heatsink, lihat catatan di bawah).

## Skema

```
   PSU/PD (misal 12V dari output CH224A)
        |
        +-------------------+
        |                   |
     [PELTIER +]        (tidak nyambung ke ESP32,
        |                jangan sambung VBUS/output
     [PELTIER -]          ke GPIO manapun)
        |
        D (Drain) MOSFET IRLZ44N
        |
   G (Gate) ---[R 150-220R]--- GPIO10 (ESP32-C3)
        |
      [R 10K pulldown ke GND]  <-- WAJIB, jangan dilewatkan
        |
        S (Source) MOSFET -------- GND (nyambung ke GND PSU & GND ESP32)
```

Urutan pin IRLZ44N (dilihat dari depan, tulisan menghadap kita, kaki
ke bawah): **Gate - Drain - Source** (kiri ke kanan).

## Langkah pasang

1. **Source -> GND.** Sambung ke GND yang SAMA dengan GND ESP32 dan GND
   sumber daya peltier (ground harus jadi satu / common ground).
2. **Drain -> kaki negatif (-) Peltier.** Kaki positif (+) Peltier
   langsung ke jalur suplai (misal output 12V dari CH224A / PSU
   terpisah), BUKAN ke GPIO.
3. **Gate -> resistor 150-220Ω -> GPIO10** ESP32-C3. Resistor seri ini
   meredam ringing, bukan wajib banget tapi sangat disarankan.
4. **Resistor pulldown 10KΩ** dari Gate ke GND (langsung di kaki Gate
   MOSFET). Ini yang WAJIB — tanpa ini, gate MOSFET akan floating
   selama ESP32 boot/reset dan peltier bisa nyala sendiri sesaat
   secara tidak terkendali.
5. Kalau arus peltier > ±3A terus-menerus, kasih **heatsink kecil** ke
   body TO-220 IRLZ44N. Di 3.3V gate drive, Rds(on)-nya tidak se-optimal
   di 5-10V, jadi ada sedikit disipasi panas di MOSFET — heatsink kecil
   sudah cukup untuk pemakaian normal.
6. Opsional tapi disarankan: kapasitor keramik 100nF antara Drain dan
   Source (dekat peltier) untuk meredam noise switching.

## Yang TIDAK boleh

- Jangan sambung kaki (+) atau (-) Peltier langsung ke GPIO ESP32 —
  arusnya jauh melebihi batas aman GPIO (~12mA/pin).
- Jangan pasang MOSFET tanpa resistor pulldown di Gate.
- Jangan satukan Drain dengan jalur Source CH224A/USB power — pakai
  ground bersama tapi jalur switching (Drain) harus khusus ke peltier.

## Firmware

Firmware sudah di-update:
- Pin gate: `GPIO10` (`PELTIER_PIN`), diinisialisasikan **LOW** paling
  awal di `setup()` sebelum kode lain jalan (proteksi software di atas
  proteksi hardware pulldown 10K).
- Peltier **selalu default OFF setiap device baru nyala/restart** —
  demi keamanan, tidak auto-nyala sendiri tanpa perintah dari app.
- Kontrol dari app: field JSON `"peltier": true/false` lewat BLE atau
  `POST /set` dengan form-field `peltier=1` / `peltier=0` (WiFi/HTTP).
- Status peltier ikut dikirim balik di `/status` dan notifikasi BLE
  sebagai field `"peltier"`.
