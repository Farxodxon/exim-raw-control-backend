# Dillerlar moduli — vazifa hisoboti

**Sana:** 2026-09-11
**Vazifa:** `prompt_diller_modul.md` asosida alohida "Dillerlar" (sotuv dillerlari) modulini backend + frontend to'liq joriy etish.
**Natija:** Backend `af7603d` | Frontend `8303dcc` | E2E: **151/151 PASS** | `flutter analyze`: **0 error** (29 pre-existing info-lint)

---

## 1. Vazifa mazmuni

- Alohida `fh.dealers` jadvali (eski `type='dealer'` omborlar bilan aralashmagan holda).
- Backend: `/dealers` CRUD API.
- Frontend: yangi "Dillerlar" ekrani + navigatsiya.
- Transfer oynasida bozor segmenti (`Ichki bozor` / `Eksport`) bo'yicha diller tanlash.
- Diller bilan qaytarish mexanizmi: dealer ombori bilan `type='dealer'`, `can_transfer=true`; yaratilishda avtomatik `dealer -> finished` yo'nalishi.

## 2. Qanday bajarildi

### 2.1. DB bo'yicha (backend)
- `lib/server.dart` bootstrap qismiga `fh.dealers` `CREATE TABLE IF NOT EXISTS` + unique indeks qo'shildi (server har startda ta'minlaydi).
- `migrations/012_dealers.sql` — mustaqil migratsiya:
  - `fh.dealers(id, name, market_type['domestic','export'], phone, address, contact_person, warehouse_id UNIQUE REFERENCES fh.warehouses ON DELETE CASCADE, is_active, created_at)`;
  - `dealers_warehouse_uk`, `dealers_market_type_idx` indekslari.

### 2.2. Backend API (`lib/factoryhub/api.dart`)
Ro'yxat saqlash uchun "dealer -> warehouse 1:1" tamoyili: har diller uchun ombor avtomatik yaratiladi:

| Method | Endpoint | Tavsif |
|---|---|---|
| GET | `/fh/dealers?market_type=` | Ro'yxat + balans (N+1 **yo'q** — bitta `LEFT JOIN` agregatsiyasi: `item_count`, `total_qty`) |
| POST | `/fh/dealers` | Bitta tranzaksiyada: warehouse (`type='dealer'`, `can_transfer=true`) → dealer → `dealer->finished` route (agar finished mavjud bo'lsa) |
| GET | `/fh/dealers/<id>` | Dealer ma'lumotlari + `transferTo` + to'liq ombor qoldig'i |
| PUT | `/fh/dealers/<id>` | Dealer tahrirlash + ombor nomini sinxron yangilash |
| DELETE | `/fh/dealers/<id>` | Qoldiq nol bo'lsa — dealer + ombor + bog'liq yo'nalishlar cascade; aks holda `409` "Diller ombori bo'sh emas" |

- Ruxsat: GET — `canControlWarehouses || canTransactStock`; POST/PUT/DELETE — faqat `canControlWarehouses`.
- Validatsiya: `name` shart, `marketType` faqat `domestic|export`.

### 2.3. Frontend
- `lib/services/api_service.dart`: `getDealers({marketType})`, `getDealerDetail`, `createDealer`, `updateDealer`, `deleteDealer`.
- `lib/screens/dealers_screen.dart` (yangi):
  - `DealersScreen` — "Ichki bozor / Eksport" segmenti, kartalar (nomi, qoldiq yig'indisi), "+" tugma;
  - `_DealerFormSheet` — yaratish/tahrirlash (nomi, bozor, telefon, manzil, aloqa shaxsi);
  - `DealerDetailScreen` — kontakt + to'liq ombor qoldig'i;
  - o'chirish faqat admin/controller.
- `lib/screens/home_shell.dart`: "Dillerlar" nav yozuvi (`Icons.storefront`) — `canControlWarehouses || isOpsManager || isDirector` bo'lsa ko'rinadi.
- `lib/screens/warehouses_screen.dart` `_TransferSheet`:
  - `_load` da `getDealers()` yuklanadi, manzillar `_dealerDests` (diller omborlari) / `_normalDests` ga bo'linadi;
  - diller omborlari mavjud bo'lsa "Ichki bozor/Eksport" `SegmentedButton` + diller `ChoiceChip`lari ko'rsatiladi (`warehouseId` manzil sifatida yuboriladi);
  - qolgan omborlar odatiy dropdown'da qoladi; fixed manzil bo'lsa avvalgi panel saqlanadi.

## 3. Tekshiruvlar

| Tekshiruv | Natija |
|---|---|
| `dart pub get` + `dart analyze lib\factoryhub\api.dart lib\server.dart` | faqat eski `whType` warning |
| `flutter pub get` + `flutter analyze` | 0 error, 29 pre-existing info-lint |
| `tool/e2e_flow.dart` (server 8051, `JWT_SECRET=test-secret-hr-e2e`) | **151/151 PASS** (126 eski + 25 diller testi) |

E2E diller bo'limi quyidagini qamraydi: ops ruxsati, bo'sh/bad body 400, yaratish 201 + avto-ombor (`type='dealer'`, `canTransfer`, `route->finished`), segment filtr, balans aks etishi (itemCount/totalQty), detail qoldiq, non-empty DELETE 409, empty DELETE 200 + ombor ham o'chishi, PUT orqali ombor nomi sinxronlanishi.

## 4. O'zingizda ishga tushirish

```powershell
# Backend (8051)
$env:PORT='8051'; $env:JWT_SECRET='test-secret-hr-e2e'; dart run lib\server.dart
# Test
$env:JWT_SECRET='test-secret-hr-e2e'; dart run tool\e2e_flow.dart
# Frontend
flutter pub get; flutter run
```

> Eslatma: `fh.dealers` jadvali server bootstrap orqali avtomatik yaratiladi; Neon'ga qo'llash uchun `migrations/012_dealers.sql` ham tayyor.