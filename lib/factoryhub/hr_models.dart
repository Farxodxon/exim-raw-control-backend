import 'package:postgres/postgres.dart';

class Employee {
  final int id;
  final String fullName;
  final String? position;
  final String? department;
  final String? phone;
  final DateTime? hireDate;
  final DateTime? terminationDate;
  final String status;
  final double? baseSalary;
  final String? note;
  final String payType;
  final int? userId;

  Employee({
    required this.id,
    required this.fullName,
    this.position,
    this.department,
    this.phone,
    this.hireDate,
    this.terminationDate,
    this.status = 'active',
    this.baseSalary,
    this.note,
    this.payType = 'salary',
    this.userId,
  });

  factory Employee.fromRow(List<dynamic> r) => Employee(
        id: r[0] as int,
        fullName: r[1] as String,
        position: r[2] as String?,
        department: r[3] as String?,
        phone: r[4] as String?,
        hireDate: (r[5] as DateTime?)?.toLocal(),
        terminationDate: (r[6] as DateTime?)?.toLocal(),
        status: r[7] as String? ?? 'active',
        baseSalary: r[8] == null ? null : double.parse(r[8].toString()),
        note: r[9] as String?,
        payType: r[10] as String? ?? 'salary',
        userId: r[11] as int?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'fullName': fullName,
        'position': position,
        'department': department,
        'phone': phone,
        'hireDate': hireDate?.toIso8601String(),
        'terminationDate': terminationDate?.toIso8601String(),
        'status': status,
        'baseSalary': baseSalary,
        'note': note,
        'payType': payType,
        'userId': userId,
      };
}

class AttendanceRecord {
  final int id;
  final int employeeId;
  final DateTime workDate;
  final String? checkIn;
  final String? checkOut;
  final double? hoursWorked;
  final String status;
  final String? note;
  final int? recordedBy;
  final String? employeeName;

  AttendanceRecord({
    required this.id,
    required this.employeeId,
    required this.workDate,
    this.checkIn,
    this.checkOut,
    this.hoursWorked,
    this.status = 'present',
    this.note,
    this.recordedBy,
    this.employeeName,
  });

  factory AttendanceRecord.fromRow(List<dynamic> r) => AttendanceRecord(
        id: r[0] as int,
        employeeId: r[1] as int,
        workDate: (r[2] as DateTime).toLocal(),
        checkIn: _timeToString(r[3]),
        checkOut: _timeToString(r[4]),
        hoursWorked: r[5] == null ? null : double.parse(r[5].toString()),
        status: r[6] as String? ?? 'present',
        note: r[7] as String?,
        recordedBy: r[8] as int?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'employeeId': employeeId,
        'workDate': workDate.toIso8601String().substring(0, 10),
        'checkIn': checkIn,
        'checkOut': checkOut,
        'hoursWorked': hoursWorked,
        'status': status,
        'note': note,
        'recordedBy': recordedBy,
        'employeeName': employeeName,
      };
}

class SalaryAdjustment {
  final int id;
  final int employeeId;
  final String adjustmentType;
  final double amount;
  final String reason;
  final DateTime adjustmentDate;
  final String status;
  final int? approvedBy;
  final String? employeeName;

  SalaryAdjustment({
    required this.id,
    required this.employeeId,
    required this.adjustmentType,
    required this.amount,
    required this.reason,
    required this.adjustmentDate,
    this.status = 'pending',
    this.approvedBy,
    this.employeeName,
  });

  factory SalaryAdjustment.fromRow(List<dynamic> r) => SalaryAdjustment(
        id: r[0] as int,
        employeeId: r[1] as int,
        adjustmentType: r[2] as String,
        amount: double.parse(r[3].toString()),
        reason: r[4] as String,
        adjustmentDate: (r[5] as DateTime).toLocal(),
        status: r[6] as String? ?? 'pending',
        approvedBy: r[7] as int?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'employeeId': employeeId,
        'adjustmentType': adjustmentType,
        'amount': amount,
        'reason': reason,
        'adjustmentDate': adjustmentDate.toIso8601String().substring(0, 10),
        'status': status,
        'approvedBy': approvedBy,
        'employeeName': employeeName,
      };
}

String? _timeToString(dynamic v) {
  if (v == null) return null;
  if (v is Time) {
    final h = v.hour == 24 ? 0 : v.hour;
    return '${h.toString().padLeft(2, '0')}:${v.minute.toString().padLeft(2, '0')}';
  }
  return '$v';
}