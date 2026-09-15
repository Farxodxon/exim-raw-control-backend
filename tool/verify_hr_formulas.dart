// tool/quick_verify_hr_formulas.dart - QABUL MEZONLARI sonli tekshiruv
// (formula kodi to'g'ri ekanini tasdiqlaydi; test-MA'LUMOTI aniq sozlangan).
// Mart-2025: 31 kun, 5 yakshanba (2,9,16,23,30) + 1 bayram (21-noyabr? yo'q:
// 21-mark) => 6 dam => 25 ish kuni => norma 200 => stavka 25,000 => 6,700,000.
import "dart:io";
import "../lib/factoryhub/payroll.dart" as hr;

int fails = 0;
void chk(bool c, String m) {
  if (!c) { print("FAIL: $m"); fails++; }
}

void main() {
  // ---------- 1) NIGORA: OKLAD (Mart-2025) ----------
  // 31 kun, 5 yakshanba (2,9,16,23,30) + 1 bayram (21-mark) = 6 dam
  // -> ish 25 kun -> norma 25x8=200 soat
  // -> stavka 5,000,000/200 = 25,000
  // -> qo'shimcha: 6 dam x8=48 + ish kunlarida 20 => 68 soat
  // -> 68 x 25,000 = 1,700,000
  // -> JAMI 5,000,000 + 1,700,000 = 6,700,000  (MEZON)
  DateTime dt(int d) => DateTime(2025, 3, d);
  final nigora = hr.computeSalaryPayroll(
    salary: 5000000,
    month: DateTime(2025, 3),
    holidays: [dt(21)],
    restDaysWorked: 6,
    workdayOvertimeHours: 20,
  );
  chk(nigora.workingDays == 25, "Nigora 25 ish kuni (bo'ldi:${nigora.workingDays})");
  chk(nigora.normHours == 200, "Nigora norma 200 soat (bo'ldi:${nigora.normHours})");
  chk(nigora.hourlyRate == 25000, "Nigora stavka 25,000 (bo'ldi:${nigora.hourlyRate})");
  chk(nigora.overtimeHours == 68, "Nigora qo'shimcha 68 soat (bo'ldi:${nigora.overtimeHours})");
  chk(nigora.overtimePay == 1700000, "Nigora qo'shimcha 1,700,000");
  chk(nigora.total == 6700000, "Nigora JAMI 6,700,000 (bo'ldi:${nigora.total})");

  // ---------- 2) MADINA: ISHBAY (aralash kun) ----------
  // 7 sof kun [158,142,169,172,141,135,170] dona x 1500
  //   = 1087 dona -> 1,630,500
  //   o'rtacha stavka = 1,630,500 / (7x8=56) = 29,116 (butunga)
  //   aralash kun (95 dona + 2 soat):
  //     95x1500 + 2x29,116 = 142,500 + 58,232 = 200,732  (MEZON)
  final madina = hr.computePiecePayroll([
    for (final q in const [158.0, 142.0, 169.0, 172.0, 141.0, 135.0, 170.0])
      hr.PieceDay(
        employeeId: 2, workDate: DateTime(2025, 3, 3), quantity: q, hours: 0, rate: 1500),
    hr.PieceDay(
        employeeId: 2, workDate: DateTime(2025, 3, 10), quantity: 95, hours: 2, rate: 1500),
  ]);
  chk(madina.avgHourlyRate == 29116, "Madina o'rtacha 29,116 (bo'ldi:${madina.avgHourlyRate})");
  chk(madina.pieceTotal == 1831232, "Madina JAMI 1,831,232 (bo'ldi:${madina.pieceTotal})");
  chk((madina.pieceTotal - 1630500) == 200732,
      "Madina aralash kun 200,732 (bo'ldi:${madina.pieceTotal - 1630500})");

  if (fails == 0) { print("ALL PASS: Nigora 6,700,000 / Madina 200,732"); exit(0); }
  print("FAILS=$fails"); exit(1);
}
