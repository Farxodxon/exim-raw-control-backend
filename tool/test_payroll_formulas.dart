// tool/test_payroll_formulas.dart — qabul mezonlari (aniq testlar).
import "dart:io";
import "../lib/factoryhub/payroll.dart" as hr;

int fails = 0;

void chk(bool cond, String msg) {
  if (!cond) {
    print("FAIL: " + msg);
    fails++;
  }
}

void main() {
  // ---------- 1) NIGORA (oklad) ----------
  final nig = hr.computeSalaryPayroll(
    salary: 5000000,
    month: DateTime(2025, 1),
    holidays: [DateTime(2025, 1, 1)],
    restDaysWorked: 6,
    workdayOvertimeHours: 20,
  );
  chk(nig.workingDays == 25, "Nigora 25 ish kuni");
  chk(nig.normHours == 200, "Nigora norma 200 soat");
  chk(nig.hourlyRate == 25000, "Nigora stavka 25,000");
  chk(nig.overtimeHours == 68, "Nigora qoshimcha 68 soat");
  chk(nig.overtimePay == 1700000, "Nigora qoshimcha haq 1,700,000");
  chk(nig.total == 6700000, "Nigora JAMI 6,700,000");

  // ---------- 2) MADINA (ishbay) ----------
  final mad = hr.computePiecePayroll([
    hr.PieceDay(employeeId: 2, workDate: DateTime(2025, 1, 3), quantity: 158,
        hours: 0, rate: 1500),
    hr.PieceDay(employeeId: 2, workDate: DateTime(2025, 1, 4), quantity: 142,
        hours: 0, rate: 1500),
    hr.PieceDay(employeeId: 2, workDate: DateTime(2025, 1, 5), quantity: 169,
        hours: 0, rate: 1500),
    hr.PieceDay(employeeId: 2, workDate: DateTime(2025, 1, 6), quantity: 172,
        hours: 0, rate: 1500),
    hr.PieceDay(employeeId: 2, workDate: DateTime(2025, 1, 7), quantity: 141,
        hours: 0, rate: 1500),
    hr.PieceDay(employeeId: 2, workDate: DateTime(2025, 1, 8), quantity: 135,
        hours: 0, rate: 1500),
    hr.PieceDay(employeeId: 2, workDate: DateTime(2025, 1, 9), quantity: 170,
        hours: 0, rate: 1500),
    hr.PieceDay(employeeId: 2, workDate: DateTime(2025, 1, 10), quantity: 95,
        hours: 2, rate: 1500),
  ]);
  chk(mad.avgHourlyRate == 29116, "Madina ortacha stavka 29,116");
  chk(mad.pieceTotal == 1831232, "Madina pieceTotal 1,831,232");
  chk(mad.pendingDaysCount == 0, "Madina pending 0");

  // Alohida: aralash kun (95 dona + 2 soat) = 200,732
  //   95*1500 + 2*29,116 = 142,500 + 58,232 = 200,732
  final dayArr = mad.pieceTotal - 1630500;
  chk(dayArr == 200732, "Madina aralash kun 200,732");

  if (fails == 0) {
    print("ALL PASS: Nigora 6,700,000; Madina aralash 200,732");
    exit(0);
  }
  print("FAILS=" + fails.toString());
  exit(1);
}
