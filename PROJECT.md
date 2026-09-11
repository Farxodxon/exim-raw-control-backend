# FactoryHub Backend — Loyiha Dokumentatsiyasi

> Oxirgi yangilanish: 2026-09-11 | Backend: `af7603d` | Frontend: `8303dcc`

---

## 1. Loyiha haqida

FactoryHub (exim-raw-control-backend) — O'zbekistondagi ishlab chiqarish korxonasi uchun **boshqaruv tizimi**. Qamrab oladigan yo'nalishlar:

- **Omborlar** — xom ashyo, tayyor mahsulot, yarim tayyor, qadoqlash omborlari; zaxiralar, tranzaksiyalar, regime-51 hisobotlari
- **Ishlab chiqarish** — BOM retseptlar, ikki bosqichli (mixing → packaging), karantin nazorati, buyurtmalar asosida ishlab chiqarish
- **Transferlar** — o'zaro omborlararo yuborish/qabul qilish zanjiri (pending → confirm/reject)
- **HR** — xodimlar, davomat (08:00–18:00 + 8 soatlik mehnat normasi), oylik haq hisobi, premiya/jarima/avans, qo'shimcha ish soati
- **Savdo** — buyurtmalar, hamkorlar (Éclair rekvizitlari), shtrix-kodli skanerlash, schyot-faktura/TIR/dalolatnoma
- **Xavfsizlik** — JWT auth, rolga asoslangan (admin/warehouse_keeper/production_manager/hr_manager/hr_engineer), modul va ombor bo'yicha ruxsatlar

---

## 2. Tech Stack

| Komponent | Texnologiya |
|---|---|
| **Backend** | Dart 3.12, Shelf + shelf_router |
| **DB** | PostgreSQL (Neon Serverless, aws eu-central-1) |
| **DB driver** | `postgres: ^3.4.8` (one-statement-per-execute) |
| **Auth** | `dart_jsonwebtoken: ^3.4.1` (JWT), `bcrypt: ^1.2.0` |
| **Deploy** | Render.com (Docker, Dart SDK 3.12, free plan) |
| **Frontend** | Flutter (Windows + Android + Web), `api_service.dart` HTTP client |
| **Frontend repo** | [Farxodxon/factory_hub](https://github.com/Farxodxon/factory_hub) |

---

## 3. Loyiha tuzilishi

```
exim-raw-control-backend/
├── lib/
│   ├── server.dart              # Entry point, legacy routes (/api/*), DB bootstrap
│   ├── database/
│   │   └── connection.dart      # Neon connection pool
│   └── factoryhub/
│       ├── api.dart             # Asosiy API: /fh/* route'lari (~5600 qator)
│       ├── hr_models.dart       # AttendanceRecord, WorkRecord modellari
│       ├── jwt.dart             # JWT generate/verify
│       ├── policy.dart          # Ruxsat tekshirish (_canRead/_canWrite)
│       ├── user.dart            # User model
│       └── user_storage.dart    # Foydalanuvchi CRUD
├── migrations/                  # SQL migratsiyalar (001–011)
│   ├── 001_warehouse_types_and_regime51.sql
│   ├── 002_hr_module.sql
│   ├── 003_module_permissions.sql
│   ├── 004_production_packaging_transfers.sql
│   ├── 005_unify_transfer_chain.sql
│   ├── 006_allow_legacy_transfer_refs.sql
│   ├── 007_wide_item_identifiers.sql
│   ├── 008_module_corrections.sql
│   ├── 009_hr_pay_types.sql
│   ├── 010_attendance_overtime.sql
│   └── 011_fixed_route.sql        # fh.warehouses.fixed_route_to_id
│   └── 012_dealers.sql            # fh.dealers + indekslar
├── tool/                        # Test skriptlari va migration runner'lar
│   ├── e2e_flow.dart           # To'liq e2e test (151 test, server 8051)
│   ├── test_hr_pay.dart        # HR + ish haqi testlari (38 test)
│   ├── probe_overtime.dart     # Overtime tekshiruvi (9 test)
│   └── migrate_*.dart          # Migratsiya runner'lar
├── .env                         # DATABASE_URL (Neon)
├── Dockerfile                   # Dart 3.12 SDK, JIT
├── render.yaml                  # Render deploy konfiguratsiyasi
└── pubspec.yaml
```

---

## 4. Deploy

### Backend (Render)
- **URL:** [exim-raw-api](https://exim-raw-api.onrender.com)
- **Render konfiguratsiyasi:** `render.yaml` — `type: web`, `runtime: image`, `dockerfilePath: ./Dockerfile`
- **ENV:** `PORT=8080`, `DATABASE_URL` (Neon), `JWT_SECRET`
- **Auto-deploy:** `git push main` → Render avtomatik qayta deploy qiladi

### Database (Neon)
- **Host:** `ep-shy-hall-as1mo6qc-pooler.c-4.eu-central-1.aws.neon.tech`
- **Schema:** `fh` (app tables) + `public` (legacy: products, partners, orders)
- **Migratsiyalar:** `.env` dagi DATABASE_URL orqali `dart run tool/migrate_*.dart` bilan qo'llanadi

### Frontend (Flutter)
- **Dev:** `flutter run` (Windows/Android/Web)
- **API base URL:** `https://exim-raw-api.onrender.com/fh` (production) yoki `http://127.0.0.1:8051/fh` (local)

---

## 5. Local ishga tushirish

### Backend (8051 port)
```powershell
$env:PORT='8051'
$env:JWT_SECRET='test-secret-hr-e2e'
dart run lib\server.dart
```

### Testlar (server 8051 ustida)
```powershell
$env:JWT_SECRET='test-secret-hr-e2e'
dart run tool\e2e_flow.dart    # 105 test (mahsulotlar, omborlar, transferlar, ishlab chiqarish)
dart run tool\test_hr_pay.dart  # 38 test (HR, davomat, oylik hisob)
dart run tool\probe_overtime.dart  # 9 test (overtime tekshiruvi)
```

### Migratsiyani Neon'ga qo'llash
```powershell
$env:DATABASE_URL='postgresql://...'  # .env dan olingan
dart run tool\migrate_010.dart
```

---

## 6. DB sxemasi (fh schema — 28 jadval, 2 view)

### Asosiy modullar

| Jadval | Tavsif |
|---|---|
| `fh.users` | Foydalanuvchilar (id, username, email, password, role, department) |
| `fh.warehouses` | Omborlar (name, type, can_analyze/transfer/income/expense, is_default) |
| `fh.stock_ledger` | Ombor daftar (har bir tranzaksiya: direction IN/OUT, source_type, qty) |
| `fh.items` | Yagona mahsulot katalogi (name, item_type, code, unit, content_ml) |
| `fh.boms` | BOM retseptlar (name, stage, output_item_id, output_qty_per_batch) |
| `fh.bom_items` | BOM tarkibi (bom_id, item_type, ref_id, ref_barcode, qty) |
| `fh.production_batches` | Ishlab chiqarish partiyalari (plan_id, bom_id, stage, source/dest_warehouse_id) |
| `fh.dealers` | Sotuv dillerlari (name, market_type, phone, address, contact_person, warehouse_id 1:1) |

### Ombor zanjiri

| Jadval | Tavsif |
|---|---|
| `fh.transfers` | O'zaro omborlararo transferlar (from/to, status: pending/confirmed/rejected, is_sale) |
| `fh.transfer_items` | Transfer tarkibi (item_type, ref_id, ref_barcode, qty) |
| `fh.product_warehouses` | Mahsulot ↔ ombor bog'liqligi (M2M) |
| `fh.stock_writes` | Qo'lda chiqim/yozish (reason, qty, performed_by) |
| `fh.stock_thresholds` | Kritik zaxira darajalari (min_qty per item per warehouse) |
| `fh.warehouse_transfer_routes` | Ruxsat etilgan omborlar yo'nalishlari (from → to) |
| `fh.inspections` | Karantin tekshiruvi (quarantine_warehouse, status: pending/approved/rejected) |

### HR

| Jadval | Tavsif |
|---|---|
| `fh.employees` | Xodimlar (full_name, position, department, hire_date, pay_type: salary/piece_rate/hybrid, user_id) |
| `fh.attendance` | Davomat (work_date, check_in/out: TIME, hours_worked: 8h cap, overtime_hours: manual) |
| `fh.piece_rates` | Ish turi ↔ narx (work_type, item_id, rate_per_unit, unit) |
| `fh.work_records` | Ish yozuvlari (work_type, item_id, quantity, rate_applied, computed_amount) |
| `fh.salary_adjustments` | Premiya/jarima/avans (adjustment_type, amount, status: pending/approved/rejected) |

### View'lar

| View | Tavsif |
|---|---|
| `fh.monthly_payroll_summary` | Oylik hisob (days_present/absent/late, total_hours, total_overtime_hours, base/piece/net_amount) |
| `fh.user_access_overview` | Foydalanuvchi ruxsatlari (modules + warehouses birlashtirilgan) |

### Modullar va ruxsatlar

| Jadval | Tavsif |
|---|---|
| `fh.app_modules` | Tizim modullari (module_key, name_uz, category) |
| `fh.user_modules` | Foydalanuvchi ↔ modul bog'liqligi |

---

## 7. API endpoint'lari

> **Prefix farqi:** `server.dart` route'lari — `/api/*`, `api.dart` route'lari — `/fh/*` (server.dart:1621 da mount qilingan)
> **JSON formati:** Production endpoint'lari snake_case (`ref_id`), HR endpoint'lari camelCase (`employeeId`)

### Auth & Foydalanuvchilar
| Method | Endpoint | Tavsif |
|---|---|---|
| POST | `/fh/login` | Kirish (username+password → JWT) |
| POST | `/fh/setup` | Dastlabki admin yaratish |
| GET | `/fh/auth/my-access` | Joriy foydalanuvchi ruxsatlari |
| GET | `/fh/users` | Barcha foydalanuvchilar |
| POST | `/fh/users` | Yangi foydalanuvchi |
| PUT | `/fh/users/<id>` | Tahrirlash |
| DELETE | `/fh/users/<id>` | O'chirish |
| POST | `/fh/users/assign` | Ruxsat tayinlash |

### Admin ruxsatlar
| Method | Endpoint | Tavsif |
|---|---|---|
| GET | `/fh/admin/modules` | Barcha modullar |
| GET | `/fh/admin/users/<id>/access` | Foydalanuvchi ruxsatlari |
| POST/DELETE | `/fh/admin/users/<id>/warehouses` | Ombor ruxsatlari |
| POST/DELETE | `/fh/admin/users/<id>/modules` | Modul ruxsatlari |

### Omborlar
| Method | Endpoint | Tavsif |
|---|---|---|
| GET | `/fh/warehouses` | Barcha omborlar (capabilities bilan) |
| POST | `/fh/warehouses` | Yangi ombor |
| GET | `/fh/warehouses/<id>` | Detal (stock + transferToWarehouses) |
| PUT | `/fh/warehouses/<id>` | Tahrirlash |
| DELETE | `/fh/warehouses/<id>` | O'chirish |
| GET | `/fh/warehouses/<id>/transactions` | Tranzaksiya tarixi |
| POST | `/fh/warehouse/transaction` | Qo'lda tranzaksiya |

### Zaxira va hisobotlar
| Method | Endpoint | Tavsif |
|---|---|---|
| GET | `/fh/stock` | Barcha omborlar zaxirasi (grouped) |
| GET | `/fh/reports/transactions` | Tranzaksiyalar hisoboti (Excel) |
| GET | `/fh/reports/warehouse` | Ombor hisoboti |
| GET | `/fh/reports/regime51-balance` | Rejim-51 zaxirasi |
| GET | `/fh/thresholds` | Kritik darajalar |
| PUT | `/fh/thresholds` | Yangilash |

### Transferlar
| Method | Endpoint | Tavsif |
|---|---|---|
| GET | `/fh/transfers` | Barcha transferlar |
| POST | `/fh/transfers/send` | Qo'lda yuborish (ledger OUT darhol) |
| POST | `/fh/transfers` | Avtomatik (production) |
| GET | `/fh/transfers/pending` | Kutilayotgan tasdiqlashlar |
| GET | `/fh/transfers/pending/summary` | Omborlar bo'yicha summary |
| GET | `/fh/transfers/<id>` | Detal |
| POST | `/fh/transfers/<id>/confirm` | Tasdiqlash (ledger IN) |
| POST | `/fh/transfers/<id>/reject` | Rad etish (reverse) |

### Dillerlar
| Method | Endpoint | Tavsif |
|---|---|---|
| GET | `/fh/dealers?market_type=` | Ro'yxat + balans (N+1 yo'q — LEFT JOIN agregatsiya) |
| POST | `/fh/dealers` | Yaratish (avto ombor type='dealer' + dealer→finished route) |
| GET | `/fh/dealers/<id>` | Detal (kontakt + to'liq qoldiq) |
| PUT | `/fh/dealers/<id>` | Tahrirlash (ombor nomini sinxron) |
| DELETE | `/fh/dealers/<id>` | O'chirish (qoldiq<>0 → 409; aks holda ombor + routes cascade)

### Ishlab chiqarish
| Method | Endpoint | Tavsif |
|---|---|---|
| GET | `/fh/boms` | Barcha retseptlar |
| GET | `/fh/boms/<id>` | Retsept detali |
| POST | `/fh/boms` | Retsept yaratish |
| PUT | `/fh/boms/<id>` | Retsept tahrirlash (+ items almashtirish) |
| GET | `/fh/items` | Yagona mahsulot katalogi |
| POST | `/fh/items` | Yangi item |
| GET | `/fh/production/norms/<barcode>` | BOM normasi |
| POST | `/fh/production/start` | Oddiy ishlab chiqarish |
| POST | `/fh/production/bom/start` | BOM asosida ishlab chiqarish (+ employee_id → avto work_record) |
| GET/POST | `/fh/production/mixing/preview/start` | Mixing bosqichi |
| GET/POST | `/fh/production/packaging/preview/start` | Packaging bosqichi |
| PUT | `/fh/production/<id>` | Partiya tahrirlash |
| POST | `/fh/stock/write-off` | Yozib tashlash / yo'qotish |

### Karantin nazorati
| Method | Endpoint | Tavsif |
|---|---|---|
| POST | `/fh/inspections/receive` | Karantin omboriga qabul qilish |
| GET | `/fh/inspections/pending` | Kutilayotgan tekshiruvlar |
| POST | `/fh/inspections/<id>/decide` | Qaror: approve (→ transfer) / reject (→ defective) |

### HR (Davomat + Ish haqi)
| Method | Endpoint | Tavsif |
|---|---|---|
| GET/POST | `/fh/hr/employees` | Xodimlar CRUD |
| GET/PUT/DELETE | `/fh/hr/employees/<id>` | Xodim detali |
| GET | `/fh/hr/attendance` | Davomat (employee_id, month filtrlash) |
| POST | `/fh/hr/attendance` | Bitta kun uchun davomat |
| POST | `/fh/hr/attendance/bulk` | Bir nech kun (till date) |
| PUT | `/fh/hr/attendance/<id>` | Tahrirlash (+ overtime qo'lda) |
| GET/POST | `/fh/hr/piece-rates` | Ish turi ↔ narx |
| PUT/DELETE | `/fh/hr/piece-rates/<id>` | Tahrirlash/O'chirish |
| GET/POST | `/fh/hr/work-records` | Ish yozuvlari (avto + qo'lda) |
| DELETE | `/fh/hr/work-records/<id>` | O'chirish |
| GET/POST | `/fh/hr/salary-adjustments` | Premiya/jarima/avans |
| PUT | `/fh/hr/salary-adjustments/<id>/approve` | Tasdiqlash |
| PUT | `/fh/hr/salary-adjustments/<id>/reject` | Rad etish |
| GET | `/fh/hr/reports/monthly` | Oylik hisob (total_hours, total_overtime_hours, net_amount) |

### Boshqa
| Method | Endpoint | Tavsif |
|---|---|---|
| GET | `/fh/catalog/raw-materials/products/partners` | Kataloglar |
| GET | `/fh/plans` | Rejalar |
| POST/PUT | `/fh/plans` | CRUD |
| GET | `/fh/supplier-orders` | Yetkazib beruvchi buyurtmalari |
| POST/PUT | `/fh/supplier-orders` | CRUD |
| GET | `/fh/reports/production` | Ishlab chiqarish hisoboti |
| GET | `/fh/dashboard/summary` | Dashboard ma'lumotlari |
| GET | `/fh/alerts` | Ogohlantirishlar |
| GET | `/fh/factory/settings` | Fabrika sozlamalari |
| PUT | `/fh/factory/settings` | Yangilash |

### Legacy (server.dart, /api/*)
| Method | Endpoint | Tavsif |
|---|---|---|
| GET | `/health` | Sog'liq tekshiruvi |
| GET/POST/PUT/DELETE | `/api/products` | Mahsulotlar (products jadvali) |
| GET | `/api/products/categories` | Kategoriyalar |
| GET | `/api/products/barcode/<barcode>` | Shtrix-kod bo'yicha |
| GET/POST/PUT/DELETE | `/api/partners` | Hamkorlar |
| GET/PUT | `/api/own-company/<id>` | Éclair rekvizitlari |
| GET/POST | `/api/orders` | Buyurtmalar |
| POST | `/api/orders/<id>/items` | Buyurtma itemlari |
| POST | `/api/orders/check` | Shtrix-kod tekshirish |
| GET | `/api/orders/<id>/invoice-data` | Schyot-faktura |
| GET | `/api/orders/<id>/tir-data` | TIR hujjati |
| GET | `/api/orders/<id>/dalolatnoma-data` | Dalolatnoma |
| GET/POST/DELETE | `/api/raw-materials-catalog` | Xom ashyo katalogi |
| GET/POST | `/api/material-incomes` | Kirim |
| GET | `/api/material-expenses` | Chiqim |

---

## 8. Frontend ekranlari

| Fayl | Modul |
|---|---|
| `login_screen.dart` | Autentifikatsiya |
| `home_shell.dart` | Asosiy shell (bottom nav) |
| `dashboard_home.dart` | Dashboard |
| `warehouses_screen.dart` | Omborlar (stock, tranzaksiyalar, transfer) |
| `production_screen.dart` | Ishlab chiqarish (mixing/packaging/start) |
| `mixing_screen.dart` | Mixing bosqichi |
| `packaging_screen.dart` | Packaging bosqichi |
| `recipes_screen.dart` | BOM retseptlar |
| `plans_screen.dart` | Rejalar |
| `catalog_screen.dart` | Mahsulotlar katalogi |
| `supplier_orders_screen.dart` | Yetkazib beruvchi buyurtmalari |
| `reports_screen.dart` | Hisobotlar |
| `thresholds_screen.dart` | Kritik darajalar |
| `inspection_screen.dart` | Karantin nazorati |
| `hr_screen.dart` | HR (xodimlar, davomat, oylik hisob, ish haqi) |
| `dealers_screen.dart` | Dillerlar (segmentli ro'yxat, yaratish/tahrirlash, detail qoldiq) |
| `users_screen.dart` | Foydalanuvchilar |
| `user_access_screen.dart` | Ruxsatlar boshqaruvi |
| `alerts_screen.dart` | Ogohlantirishlar |

---

## 9. Testlar

| Skript | Testlar | Tavsif |
|---|---|---|
| `tool/e2e_flow.dart` | 151 | To'liq oqim: mahsulot → ombor → transfer → ishlab chiqarish → karantin → dillerlar |
| `tool/test_hr_pay.dart` | 38 | HR: xodimlar, davomat, ish haqi turlari, oylik hisob, avtomatik work_records |
| `tool/probe_overtime.dart` | 9 | Overtime: 8 soatlik chegara, qo'shimcha ish soati, monthly total |

```powershell
# Server 8051 ustida:
$env:JWT_SECRET='test-secret-hr-e2e'; dart run tool\e2e_flow.dart
$env:JWT_SECRET='test-secret-hr-e2e'; dart run tool\test_hr_pay.dart
```

---

## 10. Muhim qoidalari

1. **Postgres driver:** bitta `execute()` = bitta SQL. Migratsiyalarda `--` comment'larni olib tashlash, `;` bo'yicha ajratish kerak.
2. **JSON formati:** Production — snake_case (`ref_id`, `source_type`), HR — camelCase (`employeeId`, `checkIn`).
3. **Ombor zanjiri:** Xom ombor → Production ombor → (Mixing/Packaging) → Karantin ombori → Tayyor mahsulot ombori → Sotuv ombori.
4. **Transfer tasdiqlash:** `send` da ledger OUT darhol, `confirm` da ledger IN + transfer completed.
5. **Davomat:** `hours_worked = min(diff_in_hours, 8)` (obed 2 soat, kecha smenada +1440 min). `overtime_hours` faqat qo'lda kiritiladi.
6. **`.dart_tool/package_config.json`** — repo'da track qilinadi; `dart pub get` dan keyin tekshirib chiqish kerak.

---

## 11. Changelog

| Sana | Commit | Tavsif |
|---|---|---|
| 2026-09-11 | `af7603d` | **Dillerlar (dealers) moduli:** `fh.dealers` (012), `/dealers` CRUD — avto ombor (type='dealer', can_transfer) + dealer→finished qaytarish yo'nalishi, ro'yxat balans N+1 siz, detail to'liq qoldiq, PUT ombor nomi sinxron, DELETE qoldiq<>0 da 409 + cascade. Frontend `8303dcc`: "Dillerlar" ekrani (Ichki bozor/Eksport segment), forma + detail; TransferSheet bozor segmentlari (ichki/eksport) bo'yicha diller tanlash. E2E 151/151 |
| 2026-09-07 | `86ddeaf` | **Qat'iy transfer sherigi (fixed_route_to_id):** admin ombor sozlamalarida yangi `fixed_route_to_id` ustuni (migratsiya 011). PUT/POST/GET `/warehouses` qat'iy omborni qabul qiladi (faqat transferTo ro'yxati ichidan, canTransfer bo'lsa). `/transfers/send` va legacy `/transfers` qat'iy belgilangan ombor boshqa manzilga yuborilganda 403 qaytaradi; qat'iy manzilga ruxsat etiladi. Packaging `finishedWarehouses` preview endi yarim tayyor omborining finished-routes'laridan (qat'iy bo'lsa faqat o'sha) to'ldiriladi; packaging/start faqat tayinlangan finished omboriga ishlaydi (boshqasiga 403). Frontend `357ca28`: ombor sozlamalarida "Qat'iy (avtomatik) ombor" tanlagichi; transfer oynasida qat'iy ombor bo'lsa manzil tanlanmaydi (avtomatik). E2E yangilandi (125/125) |
| 2026-09-07 | `96394c2` | **Qadoqlash darhol o'tishi:** /production/packaging/start endi natijani tanlangan tayyor mahsulot omboriga **darhol** o'tkazadi (transfer auto-confirmed, partiya completed, pending=false) — qabul qiluvchi ombor tasdig'ini kutmaydi. E2E yangilandi (104/104) |
| 2026-09-07 | `10c1f7a` | **Dashboard statistika:** totalEmployees + dealerWarehouses, activeWarehouses/batchesInProgress olib tashlandi; **Tekshiruv:** approve yarim tayyor → yarim tayyor ombori, xom ashyo → xom ombori (item_type bo'yicha, destType javobda) |
| 2026-09-06 | `95c697d` | **Davomat overtime:** attendance.overtime_hours (manual), ish vaqti 8h cap (obed bilan), monthly total_overtime_hours |
| 2026-09-06 | `a4bfabd` | **BOM employee_id:** /production/bom/start ga employee_id qo'shildi, avtomatik work_record, warning javobda |
| 2026-09-06 | `0127522` | **HR haq turlari:** salary/piece_rate/hybrid + avtomatik ish yozuvlari |
| 2026-09-06 | `9d48c18` | **Fix:** shtrix-kodli mahsulot send/confirm — int4 overflow (item_id bigint) |
| 2026-09-05 | `5803d4d` | **Fix:** qabul tasdiqlash endi ombor biriktirmasi orqali (modul emas) |
| 2026-09-05 | `d821fe5` | **Fix:** qo'lda transfer — qoldig'i faqat confirm da kamayadi |
| 2026-09-05 | `f1cbff0` | **GET /transfers/pending/summary** — omborlar uchun badge soni |
| 2026-09-05 | `8cbe93f` | **Yagona transfer zanjiri:** POST /transfers/send (ledger out darhol) |
| 2026-09-05 | `9c30aed` | **Ishlab chiqarish oqimi:** mixing/packaging preview+start, karantin nazorati |
| 2026-09-05 | `364f3af` | **Ruxsatlar tizimi:** app_modules, user_modules, my-access endpoint |
| 2026-09-05 | `8b7c974` | **HR moduli:** xodimlar, davomat, premiya/jarima/avans, oylik hisobot |
| 2026-09-04 | `209cb3b` | **Katalog:** items, BOM, multi-stage production, write-off, warehouse flow |
| 2026-09-04 | `51b4a69` | **Product ↔ Warehouse M2M**, inter-warehouse transfers |
| 2026-09-03 | `726b2d9` | **Transactions endpoint** + Excel hisobot |
| 2026-09-03 | `322484d` | **/fh prefiksi** ostida bitta Render servis |
| 2026-09-02 | `3f7aa3d` | **Kritik darajalar** API + Excel import |
| 2026-09-02 | `feccd22` | **Invoice-data** to'liq xaridor rekvizitlari |
| 2026-09-01 | `5394afa` | **Schyot-faktura** endpoint |
| 2026-09-01 | `80b9386` | **TIR hujjati** endpoint |
| 2026-09-01 | `f9e999b` | **Mahsulotlar:** ierarxik kategoriya + karobka o'lchamlari |

---

## 12. Frontend repo

Flutter frontend: [Farxodxon/factory_hub](https://github.com/Farxodxon/factory_hub) — push ⇒ avtomatik build. Frontend commit `8303dcc` (2026-09-11): Dillerlar ekrani — Ichki bozor/Eksport segmentlar, yaratish/tahrirlash formasi, detail qoldiq; TransferSheet bozor segmentlari bo'yicha diller tanlash. Avvalgi: `357ca28` Qat'iy transfer yo'nalishi — ombor sozlamalarida "Qat'iy (avtomatik) ombor" tanlagichi (`_EditWarehouseSheet`); transfer oynasi (`_TransferSheet`) qat'iy ombor belgilangan bo'lsa manzilni yashirib avtomatik yuboradi.
