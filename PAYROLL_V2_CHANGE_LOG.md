# PAYROLL_V2 - CHANGE LOG

## TUGALLANDI VA TEKSHIRILDI (API + Frontend + e2e)

1) lib\factoryhub\payroll.dart -- payroll yadrosi. dart analyze: 0 xato.
   - Nigora (oylik): JAMI 6,700,000 (oklad 5,000,000 + qoshimcha 68soat/25,000 = 1,700,000).
   - Madina (ishbay): avg stavka 29,116, piece 1,831,232, ARALASH kun = 200,732.
   - Natijalar API test orqali dalillar bilan tasdiqlandi (tool\test_payroll_v2_api.dart).

2) migrations\014_hr_payroll_v2.sql -- holidays jadvali + work_records.hours_worked + day_type.
   Server boot'iga ham idempotent ko'chirildi (CREATE IF NOT EXISTS, ALTER ADD COLUMN):
   `✅ fh.holidays + work_records v2 ensured` boot logida ko'rinadi.

3) lib\factoryhub\api.dart -- ulangan:
   - GET/POST /fh/hr/work-records v2 (quantity/hours/day_type: sof_qadoqlash|sof_soatbay|aralash;
     validatsiya: sof_qadoqlash qty>0, sof_soatbay qty=0+hours, aralash qty+hours;
     soatbay/aralash -> computed NULL + status 'pending'; stavka work_type boyicha avto lookup;
     from/to/day_type filtrlari).
   - GET/POST/PUT/DELETE /fh/hr/holidays (409 duplicate, month filtr).
   - GET /fh/hr/monthly-report?year=&month=&employee_id= -- payroll.dart natijasi
     (workingDays/normHours/hourlyRate/overtimeHours+Pay/pieceTotal/avgHourlyRate/pendingDays + summary).

4) lib\factoryhub\jwt.dart fix -- DotEnv()..load() (dotenv 4.x avtomatik load qilmaydi;
   JWT_SECRET doim null bo'lardi). .env ga JWT_SECRET qo'shildi.

5) Tuzatishlar:
   - 23505: PgException'da `code` yo'q -> `on ServerException catch (e)`.
   - NUMERIC -> driver String qaytaradi -> double.parse((x ?? 0).toString()).
   - DATE parametrlar 'YYYY-MM-01' string + ::date cast (TZ xatosi).

6) Test'lar:
   - tool\test_payroll_v2_api.dart -- 46/46 PASS (Nigora 6,700,000; Madina 1,831,232; 400 validatsiyalar; legacy POST).
   - tool\e2e_flow.dart -- 191/191 PASS (qo'shimcha 191-check: /fh/hr/monthly-report smoke).
   - e2e GPS testi idempotent: e2e_gps@test.uz qoldiqlari oldindan tozalanadi.

7) Frontend (D:\Flutter\factory hub\frontend):
   - api_service.dart: getHolidays/createHoliday/updateHoliday/deleteHoliday + getPayrollReport.
   - hr_screen.dart: 7 tab (yangisi 'Bayramlar'), kunlik work-record dayType/hours/status,
     'Qo'shish' sheet (xodim/sana/ish turi/dayType/miqdor/soat/stavka), OYLIK HISOBOT
     payroll maydonlari (workingDays/normHours/hourlyRate/overtime/pieceTotal/avg).
   - flutter analyze: 0 xato (faqat legacy info).

8) PROJECT.md yangilandi (endpointlar, jadval, tree, testlar).

## Eslatma

- Daro/komissiya formulasini (real ko'rsatkich) tarmoq yopilishidan oldin
  oylik hisobotga qo'shish keyingi sessiyada ko'rib chiqiladi.