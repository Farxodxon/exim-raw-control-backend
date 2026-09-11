# Davomat Moduli Kengaytirish — Hisobot

> Vazifa manbai: `prompt_davomat_gps_audit.md` | Tugallangan: 2026-09-11
> Backend commit: `fe3386d` | Frontend commit: `81489e5` | E2E: **165/165 PASS**

---

## 1. Vazifa

Davomat modulini kengaytirish:

1. **GPS orqali o'z-o'zini belgilash** — xodim telefonda lokatsiyani yoqib "Keldim/Ketdim" bosadi, faqat ofis hududidagi radiusda (Haversine + radius tekshiruvi) amal qiladi.
2. **3 xil tezkor holat** — nazoratchi "Kuzatuv" ekranida har xodim uchun **Keldi / Kech qoldi / Kelmadi** tanlaydi; "Kech qoldi" da vaqt ko'rsatiladi ("Hozir" yoki qo'lda), "Hammasi keldi" tezkor tugmasi.
3. **Tahrirlash jurnali (audit)** — davomat yozuvidagi har bir o'zgarish (kelish/ketish/soat/holat/izoh/erta-ketish) kim, qachon, qaysi qiymatdan qaysiga o'zgartirgani saqlanadi va ko'rinadi.
4. **Erta ketish aniqlash** — `check_out < 18:00` bo'lsa avtomatik `is_early_leave = true` hisoblanadi; ro'yxatda **amber** "Erta ketdi" chipi, oylik hisobotda `days_early_leave`.

**Ochiq qaror (foydalanuvchi javobi: "har biriga to'liq login" → Variant A):**
Har bir xodim tizimga **o'z login-paroli bilan kiradi** va davomatni o'zi belgilaydi. Yagona kiosk-skript mavjud emas; har kim uchun alohida `employee` roli account yaratiladi va xodimga bog'lanadi.

## 2. Eng asosiy arxitektura qarorlari

| Qaror | Tanlov | Sabab |
|---|---|---|
| Rol | `employee` (aktiv `employee` roli) | Har xil huquqlar aralashmasligi; faqat o'z davomatini ko'radi/uyg'unlashtiradi |
| Login | To'liq login (Variant A) | Xodim o'z telefonida kirib GPS bilan belgilaydi |
| Ruxsat | `user_modules`'da `hr` granti avtomatik beriladi | Middleware modul-grant tizimi saqlanadi; xodim faqat HR endpoint'laridan faqat o'zini ko'radi |
| GPS tekshiruvi | Haversine masofa ≤ `factory_locations.radius_meters` (default 200 m) | Hozirgi joylashuv koordinatalari |
| Keyingi hisob | `is_early_leave` avtomatik (check_out < 18:00) | Qo'lda aralashuv yo'q |
| Audit | `attendance_audit_log` jadvali (PUT da INSERT'lar + UPDATE) | PostgreSQL driver bitta-statement-per-execute — haqiqiy tranzaksiya emas, ketma-ket bajariladi |

## 3. Backend o'zgarishlari

### 3.1. Migratsiya `013_attendance_gps_audit.sql`
- `fh.attendance: check_in_lat/lng, check_out_lat/lng, marked_by ('self'|'manager'), is_early_leave`
- `fh.attendance_audit_log (attendance_id, changed_by, changed_at, field_name, old_value, new_value)`
- `fh.factory_locations (name, latitude, longitude, radius_meters, is_active)` + default "Asosiy ofis" (41.311081, 69.240562, 200 m)
- `users.role CHECK` ga `employee` qo'shildi
- `monthly_payroll_summary` view `days_early_leave` bilan qayta yaratildi

### 3.2. Bootstrap (`lib/server.dart`)
Server ishga tushganda idempotent ravishda yuqoridagi DDL'larni ta'minlaydi (GPS ustunlar, marked_by CHECK, audit jadvali, factory_locations seed, users role CHECK, monthly view) — alohida migratsiya ishlatmasdan ham ishlaydi.

### 3.3. API (`lib/factoryhub/api.dart`)
| Method | Endpoint | Tavsif |
|---|---|---|
| POST | `/fh/hr/attendance/self-checkin` | `{type: in\|out, lat, lng}` — radius tekshiruvi (ofis hududidan tashqarida 400); xodim roli o'zini oladi; `marked_by='self'`; out'da hours + is_early_leave hisoblanadi |
| GET | `/fh/hr/attendance/me` | Bugungi yozuv + xodim (employee roli uchun; bog'lanmagan user 403) |
| GET | `/fh/hr/attendance/unmarked?date=` | Kun oxirida nazoratchi uchun: hali belgilanmaganlar + `selfMarked` ro'yxati |
| GET | `/fh/hr/attendance/<id>/audit` | Tahrirlash tarixi (field, old→new, kim, qachon) |
| PUT | `/fh/hr/attendance/<id>` | Audit INSERT'lar + `is_early_leave` qayta hisoblash |
| GET | `/fh/hr/attendance` | Xodim roli faqat o'z yozuvlarini ko'radi; natijaga `employeeName` + GPS + `isEarlyLeave` qo'shildi |
| POST | `/fh/users` | `role: employee` → avto `hr` granti; `employee_id` berilsa xodim link bilan bog'lanadi |
| GET | `/fh/hr/reports/monthly` | `daysEarlyLeave` ustuni qo'shildi |

### 3.4. Qo'llab-quvvatlovchi fayllar
- `policy.dart`: `AppRoles.employee`, `Policy.isEmployee`, `Policy.canSelfCheckin`
- `hr_models.dart`: `AttendanceRecord` ga GPS/markedBy/isEarlyLeave/employeeName (length-guarded `fromRow`)
- `user_storage.dart`: mavjud createUser rol CHECK'dan o'tadi

## 4. Frontend o'zgarishlari

| Fayl | O'zgarish |
|---|---|
| `self_checkin_screen.dart` (yangi) | Xodim ekrani: bugungi holat, "KELDIM" yashil / "KETDIM" tugmalari, GPS (geolocator) bilan masofa tekshiruvi, "Erta ketdi" va "GPS bilan o'zi belgilangan" ko'rsatkichlar |
| `home_shell.dart` | `employee` roli → faqat kunlik davomat ekrani |
| `hr_screen.dart` | **Kuzatuv** 3 holatli (Keldi/Kech qoldi/Kelmadi) + vaqt tanlash + "Hammasi keldi"; davomat ro'yxatida GPS ikonka va amber "Erta ketdi" chipi; forma sheet'da "Tahrirlash tarixi" dialogi; xodim uchun "Login yaratish" menyusi (admin); oylik hisobotda "Erta ketdi" ko'rsatkichi |
| `models/user.dart` | `AppRoles.employee` + `RoleX.isEmployee`, `canSelfCheckin` |
| `services/api_service.dart` | `selfCheckin`, `getMyAttendance`, `getUnmarkedEmployees`, `getAttendanceAudit` |
| `pubspec.yaml` | `geolocator: ^14.0.0` |

## 5. Testlar

- Backend: `dart analyze` — 0 error (1 eski warning: `api.dart:1816 whType`)
- Frontend: `flutter analyze` — 0 error (29 eski info-lint)
- E2E (`tool/e2e_flow.dart`): **165/165 PASS**, yangilari:
  - `/hr/attendance/me` bog'lanmagan userda 403
  - self-checkin radius ichida `in` 200; takroriy `in` 409; `out` 200
  - radiusdan tashqari (~1.1 km) `in` → 400 "ofis hududida emas"
  - `unmarked` → selfMarked ro'yxat
  - `me` → `markedBy='self'`
  - employee faqat o'z davomatini ko'radi (count=1)
  - PUT → audit qator + `isEarlyLeave` hisoblanadi; `/audit` ikkala rol (admin + employee) uchun
  - monthly hisobot `daysEarlyLeave`

## 6. Foydalanish (local)

```powershell
# Backend 8051:
$env:PORT='8051'; $env:JWT_SECRET='test-secret-hr-e2e'; dart run lib\server.dart

# E2E:
$env:JWT_SECRET='test-secret-hr-e2e'; dart run tool\e2e_flow.dart
```

**Xodim uchun login yaratish:** HR → Xodimlar → ⋮ menyu → "Login yaratish" (admin). Shu zahoti backend xodimni `employees.user_id` orqali bog'laydi va `hr` moduli grantini beradi.

**Ofis manzili sozlash:** `fh.factory_locations` jadvali (agar o'zgartirilsa, radius va koordinatalarni yangilang; `is_active=true` bo'lgan birinchi yozuv ishlatiladi).

## 7. Xulosa

Davomat moduli to'liq uzaytirildi: xodimlar GPS orqali mustaqil belgilashadi, nazoratchi 3 holatli kuzatuvdan foydalanadi, har qanday tahrir audit jurnalida saqlanadi, erta ketish avtomatik aniqlanadi va oylik hisobotga tushadi. Har bir xodim o'z logini bilan kiradi (Variant A). Barcha testlar yashil.