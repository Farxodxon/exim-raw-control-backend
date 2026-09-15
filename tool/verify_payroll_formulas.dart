// tool/verify_payroll_formulas.dart — qabul mezonlari (aniq).
// Sof Dart, DB'siz. payroll.dart yadrosini import qiladi.
import "dart:io";
import "package:exim_raw_backend/factoryhub/payroll.dart" as hr;

int fails = 0;
String msgp(String m) { return m; }
int misaOk(bool c, String m) {
  if (!c) { print("FAIL: " + msgp(m)); fails++; return 1; }
  return 0;
}
void done(int f) {
  if (f == 0) { print("ALL PASS"); exit(0); }
  print("FAILS=$f"); exit(1);
}

void main() {
  // ---------- 1) NIGORA: OKLAD ----------
  // 2025-yanvar: 31 kun; dam: 5 yakshanba(5,12,19,26) + 1 bayram(1-yanvar)
  //   -> ish 25 kun -> norma 25x8=200 -> stavka 5,000,000/200=25,000
  //   qo'shimcha soat = 6x8(dam) + 20(ish kuni) = 48+20 = 68
  //   -> 68x25,000=1,700,000 -> JAMI 5,000,000+1,700,000 = 6,700,000
  final nigora = hr.computeSalaryPayroll(
    salary: 5000000,
    month: DateTime(2025, 1),
    holidays: [DateTime(2025,1,1)],
    restDaysWorked: 6,
    workdayOvertimeHours: 20,
  );
  fails += misaOk(nigora.workingDays == 25, "Nigora 25 ish kuni");
  fails += misaOk(nigora.normHours == 200, "Nigora norma 200 soat");
  fails += misaOk(nigora.hourlyRate == 25000, "Nigora stavka 25,000");
  fails += misaOk(nigora.overtimeHours == 68, "Nigora qoshimcha 68 soat");
  fails += misaOk(nigora.overtimePay == 1700000, "Nigora qoshimcha 1,700,000");
  fails += misaOk(nigora.total == 6700000, "Nigora JAMI 6,700,000");

  // ---------- 2) MADINA: ISHBAY ----------
  // 7 sof kun [158,142,169,172,141,135,170] x 1500 = 1,087 dona
  //   -> 1,630,500; ortacha stavka = 1,630,500/(7x8=56) = 29,116
  // aralash kun (95 dona + 2 soat): 95x1500 + 2x29,116
  //   = 142,500 + 58,232 = 200,732  (ANIQ MEZON)
  final madina = hr.computePiecePayroll([
    for (final q in [158,142,169,172,141,135,170])
      hr.PieceDay(employeeId: 2, workDate: DateTime(2025,1,1),
          quantity: q.toDouble(), hours: 0, rate: 1500),
    hr.PieceDay(employeeId: 2, workDate: DateTime(2025,1,8),
        quantity: 95, hours: 2, rate: 1500),
  ]);
  fails += misaOk(madina.avgHourlyRate == 29116, "Madina ortacha 29,116");
  fails += misaOk(madina.pendingDaysCount == 0, "Madina pending 0");
  // aralash kun ulushi:
  final aralash = madina.pieceTotal - (1087 * 1500);
  fails += misaOk(aralash == 200732, "Madina aralash kun 200,732");

  done(fails);
}
