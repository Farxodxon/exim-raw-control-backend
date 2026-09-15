// fh.payroll - oylik ish haqi yadrosi (sof Dart, DBSiz).
// Manba: ish-haqi-hisoblash-qoidalari-v1.md
// Natija O'QISH vaqtida hisoblanadi, DBga qayta yozilmaydi.

int workingDaysInMonth(DateTime m, Iterable<DateTime> h) {
  final y = m.year, mo = m.month;
  final dm = DateTime(y, mo + 1, 0).day;
  final hs = h.map((d) => DateTime(d.year, d.month, d.day)).toSet();
  var w = 0;
  for (var d = 1; d <= dm; d++) {
    final dt = DateTime(y, mo, d);
    if (dt.weekday != DateTime.sunday && !hs.contains(dt)) w++;
  }
  return w;
}
int normHoursInMonth(DateTime m, Iterable<DateTime> h) =>
    workingDaysInMonth(m, h) * 8;

// ---------- QISM 1: OKLAD (Nigora) ----------
class SalaryPayroll {
  final int workingDays;
  final int normHours;
  final double hourlyRate;
  final double overtimeHours;
  final double overtimePay;
  final double total;
  const SalaryPayroll({
    required this.workingDays,
    required this.normHours,
    required this.hourlyRate,
    required this.overtimeHours,
    required this.overtimePay,
    required this.total,
  });
  @override
  String toString() => 'SalaryPayroll(workingDays:$workingDays,'
      'normHours:$normHours,hourlyRate:$hourlyRate,'
      'overtimeHours:$overtimeHours,overtimePay:$overtimePay,total:$total)';
}

SalaryPayroll computeSalaryPayroll({
  required double salary,
  required DateTime month,
  required Iterable<DateTime> holidays,
  required double restDaysWorked,
  required double workdayOvertimeHours,
}) {
  final wd = workingDaysInMonth(month, holidays);
  final nh = wd * 8;
  final hr = nh == 0 ? 0.0 : (salary / nh).roundToDouble();
  final oth = (restDaysWorked * 8) + workdayOvertimeHours;
  final otp = (oth * hr).roundToDouble();
  return SalaryPayroll(
      workingDays: wd,
      normHours: nh,
      hourlyRate: hr,
      overtimeHours: oth,
      overtimePay: otp,
      total: (salary + otp).roundToDouble());
}

// ---------- QISM 2: ISHBAY (Madina) ----------
enum PieceDayType { sofQadoqlash, sofSoatbay, aralash }

class PieceDay {
  final int employeeId;
  final DateTime workDate;
  final double quantity;
  final double hours;
  final double rate;
  const PieceDay({
    required this.employeeId,
    required this.workDate,
    required this.quantity,
    required this.hours,
    required this.rate,
  });
}

PieceDayType pieceDayType(PieceDay d) {
  if (d.quantity > 0 && d.hours > 0) return PieceDayType.aralash;
  if (d.hours > 0) return PieceDayType.sofSoatbay;
  return PieceDayType.sofQadoqlash;
}

class PiecePayrollResult {
  final double? avgHourlyRate;
  final double pieceTotal;
  final List<PieceDay> pendingDays;
  final int pendingDaysCount;
  const PiecePayrollResult({
    required this.avgHourlyRate,
    required this.pieceTotal,
    required this.pendingDays,
    required this.pendingDaysCount,
  });
}

PiecePayrollResult computePiecePayroll(List<PieceDay> days) {
  final sof = days
      .where((d) => pieceDayType(d) == PieceDayType.sofQadoqlash)
      .toList();
  var sofAmount = 0.0;
  for (final d in sof) {
    sofAmount += d.quantity * d.rate;
  }
  final avg = sof.isEmpty
      ? null
      : (sofAmount / (sof.length * 8)).roundToDouble();
  var total = sofAmount;
  final pending = <PieceDay>[];
  for (final d in days) {
    final t = pieceDayType(d);
    if (t == PieceDayType.sofQadoqlash) continue;
    if (avg == null) {
      pending.add(d);
      continue;
    }
    final piece = d.quantity * d.rate;
    final hours = d.hours * avg;
    if (t == PieceDayType.aralash) {
      total += (piece + hours).roundToDouble();
    } else {
      total += hours.roundToDouble();
    }
  }
  return PiecePayrollResult(
      avgHourlyRate: avg, pieceTotal: total, pendingDays: pending,
      pendingDaysCount: pending.length);
}
