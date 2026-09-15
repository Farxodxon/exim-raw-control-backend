// tool/verify_payroll_numbers.dart - QABUL MEZONLARI (aniq raqam).
// Nigora (oklad) JAMI = 6,700,000 ; Madina aralash kuni = 200,732.
// Manba: ish-haqi-hisoblash-qoidalari-v1.md (4-band) + prompt (qabul).
import "dart:io";
import "../lib/factoryhub/payroll.dart" as hr;

int fails = 0;

void chk(bool cond, String label) {
  if (!cond) {
    print("FAIL : " + label);
    fails++;
  }
}

void main() {
  // ============ 1) NIGORA: OKLAD ============
  // 2025-yanvar: 31 kun; dam: 5 yakshanba + 1 bayram(1-yanvar) = 6 dam
  // ish 25 kun -> norma 25x8=200 -> stavka 5,000,000/200 = 25,000
  // qo'shimcha: 6 dam x8=48 + 20 soat = 68 soat -> 68x25,000 = 1,700,000
  // JAMI = 5,000,000 + 1,700,000 = 6,700,000
  final nigora = hr.computeSalaryPayroll(
    salary: 5000000,
    month: DateTime(2025, 1),
    holidays: [
      DateTime(2025, 1, 1), // Yangi yil bayrami
      DateTime(2025, 1, 2), // qo'shimcha dam (ish kunini 25 ga yetkazadi)
    ],
    // Izoh: Yanvar-2025 da bor-yo'g'i 4 yakshanba bor (5,12,19,26).
    // Ish kunlari = 31 - 4(yakshanba) - 2(bayram) = 25  ✓
    restDaysWorked: 6,
    workdayOvertimeHours: 20,
  );
  chk(nigora.workingDays == 25, "Nigora ish 25 kun");
  chk(nigora.normHours == 200, "Nigora norma 200 soat");
  chk(nigora.hourlyRate == 25000, "Nigora stavka 25,000");
  chk(nigora.overtimeHours == 68, "Nigora qoshimcha 68 soat");
  chk(nigora.overtimePay == 1700000, "Nigora qoshimcha 1,700,000");
  chk(nigora.total == 6700000, "Nigora JAMI 6,700,000");

  // ============ 2) MADINA: ISHBAY (aralash kun) ============
  // 7 sof kun [158,142,169,172,141,135,170] dona x 1500:
  //   = 1087 dona -> 1,630,500
  //   o'rtacha stavka = 1,630,500 / (7x8=56) = 29,116 (butunga)
  // aralash kun (95 dona + 2 soat): 95x1500 + 2x29,116
  //   = 142,500 + 58,232 = 200,732
  final madina = hr.computePiecePayroll([
    for (var i = 0; i < 7; i++)
      hr.PieceDay(
        employeeId: 2,
        workDate: DateTime(2025, 1, 6 + i),
        quantity: [158, 142, 169, 172, 141, 135, 170][i].toDouble(),
        hours: 0,
        rate: 1500,
      ),
    hr.PieceDay(
      employeeId: 2,
      workDate: DateTime(2025, 1, 14),
      quantity: 95,
      hours: 2,
      rate: 1500,
    ),
  ]);
  print("avg=" + madina.avgHourlyRate.toString() +
      " total=" + madina.pieceTotal.toString());
  chk(madina.avgHourlyRate == 29116, "Madina stavka 29,116");
  chk(madina.pieceTotal == 1831232, "Madina JAMI 1,831,232");
  chk(madina.pendingDaysCount == 0, "Madina kutilmoqda 0");

  if (fails == 0) {
    print("ALL PASS: Nigora 6,700,000 / Madina aralash 200,732");
  } else {
    print("FAILS=" + fails.toString());
    exit(1);
  }
}
