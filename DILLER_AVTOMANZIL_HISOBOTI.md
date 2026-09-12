# Transfer avtomanzillari + CHIQIM/KIRIM tuzatish — Hisobot

**Sana:** 2026-09-12
**Holat:** E2E **190/190 PASS**, `dart analyze` 0 error, `flutter analyze` 0 error
**Qamrovi:** backend (exim-backend) + frontend (factory_hub)

---

## 1. Muammo (nima buzilgan edi)

1. **Diller avtomanzillari (backend):**
   - "finished" turdagi omborlardan diller omborlariga transfer faqat **qo'lda yo'nalish
     (route)** sozlangan bo'lsa ishlardi. Yangi yaratilgan finished/dealer omborida hech
     qanday yo'nalish bo'lmasa, diller omborlariga transfer yuborib bo'lmasdi — bu diller
     moduli talabiga (diller = buyurtma ombori, finished/dealer manba) zid edi.
   - `DELETE /warehouses/<id>` va `DELETE /dealers/<id>` `fh.stock_transfers` (yangi
     transferlar jadvali) qoldiqlarini tozalamasdi → diller/finished omborini o'chirishda
     `500` (FK buzilishi), `source_warehouse_id/dest_warehouse_id` ustunlari ishlatilmay
     `from_/to_warehouse_id` deb yozilgani uchun ham noto'g'ri edi.

2. **CHIQIM/KIRIM royhati (frontend):**
   - KIRIMda tanlov ro'yxati (`_loadItems`) ombor turiga bog'lanmagan holda bitta jadvaldan
     olinar, natijada ombor sig'imiga mos kelmaydigan itemlar ko'rsatilardi.
   - CHIQIMda ombor balansidagi elementlar o'rniga butun katalog ko'rinardi → mavjud
     bo'lmagan qoldiqni chiqarish mumkin edi.
   - Desktop ekranlarda sheetlar tor (mobil o'lchamda) qolardi.

---

## 2. Yechim (nima qilindi)

### 2.1 Backend (`lib/factoryhub/api.dart`)

**a) `GET /warehouses/<id>` — dealer avtomanzillari**
- finished/dealer manba ombori uchun `fh.dealers` ichidagi **faol diller omborlari**
  avtomatik topilib `transferToWarehouses` (id+name) va `transferTo` (id ro'yxati)
  ga qo'shiladi; **o'zi mustasno** (dealer manba o'z omborini ko'rsatmaydi).
- Qo'lda yo'nalish (routes) bo'lgan omborlarda ham qo'shiladi — diller har doim
  mavjud bo'ladi.

**b) `POST /transfers/send` — auto-dest ruxsati**
- Manba turi `finished`/`dealer` bo'lsa va manzil faol diller ombori bo'lsa →
  transfer **yuboriladi (201)** va status **pending** qoladi (qabul qiluvchi
  tasdiqlaguncha balansga qo'shilmaydi).
- Qat'iy belgilangan ombor (fixed route) manba bo'lsa → qat'iy manzildan boshqasiga
  hali ham 403; raw kabi boshqa manbalardan diller omboriga 403 saqlanadi.

**c) `POST /warehouse/transaction` — allowedTypes kengaytirildi**
- Qo'lda kirim/chiqim uchun `packaging`, `semi_finished`, `spare_part`, `semi`,
  `intermediate` kabi turlar qo'shildi → qadoqlash omboriga `packaging` item_type
  qo'lda kiritish ishlaydi.

**d) DELETE tozalash tuzatildi**
- `DELETE /warehouses/<id>` va `DELETE /dealers/<id>` endi
  `fh.stock_transfers` qatorlarini (source/dest bo'yicha) ham o'chiradi;
  `source_warehouse_id`/`dest_warehouse_id` to'g'ri ustunlari ishlatiladi
  (avval `from_/to_warehouse_id` xato edi → 500). Endi transferdan keyin
  ombor/dillerni o'chirish 200.

### 2.2 Frontend (`lib/screens/warehouses_screen.dart`)

**CHIQIM/KIRIM royhati:** tanlov endi ombor turiga bog'langan:
- **KIRIM:** ombor turi bo'yicha katalog (raw→'Xom ashyo', finished→'Mahsulot',
  packaging→'Qadoqlash materiali', semi_finished→'Yarim tayyor', spare_parts→'Zap qism').
- **CHIQIM:** ombor **qoldig'idagi** elementlar (`GET /warehouses/<id>` stock,
  `balance>0`), `maxQty` cheklovi, "Bu omborda qoldiq yo'q" holati.

**Desktop kattalashtirish (`AppBreakpoints.isDesktop`):**
- `_TransferSheet`/`_TransactionSheet` sheetlari maksimal kenglik 720, `Center+ConstrainedBox`.
- Sarlavhalar va ro'yxat shrift 1.15x, yuqori/ro'yxat balandliklari kattaroq,
  tugma balandligi 48px.

---

## 3. Testlar

- E2E (`tool/e2e_flow.dart`): **190/190 PASS** — yangi guruhlar:
  - `auto-dest` (12): finished→diller detail avtomanzil, transferTo id'lar, dealer
    self-skip, finished→dealer send 201 + pending, dealer confirm → balans +1,
    raw→dealer 403 saqlanadi, packaging qo'lda kirim.
  - `fixed`, `auto-dest` cleanuplar → dealer/ombor o'chirish 200.
- `dart analyze`: **0 error** (faqat pre-existing `whType` warning api.dart:1845).
- `flutter analyze`: **0 error** (29 info, barchasi pre-existing).

---

## 4. Xulosa

Diller moduli to'liq uzaytirildi: finished/dealer manbalar uchun diller omborlari
avtomatik transfer manzili bo'lib, qo'lda yo'nalish sozlash shart emas; qabul
qiluvchi diller tasdiqlaguncha transfer pending rejimida qoladi. CHIQIM/KIRIM
royhatlari ombor turiga va balansga qat'iy bog'landi. Oldingi 500-lik o'chirish
xatosi bartaraf etildi. Barcha 190 test yashil.
