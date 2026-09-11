import 'dart:convert';
import 'dart:io';
import 'package:dotenv/dotenv.dart';
import 'package:postgres/postgres.dart';
import 'package:exim_raw_backend/factoryhub/jwt.dart';

// Overtime + soat chegarasi tekshiruvi (local 8051 server).
const base = 'http://127.0.0.1:8051/fh';
const P = 'OT %';

Future<Connection> connect() async {
  final env = DotEnv()..load();
  String? url = Platform.environment['DATABASE_URL'];
  if (url == null || url.isEmpty) url = env['DATABASE_URL'];
  final uri = Uri.parse(url!);
  final ui = uri.userInfo.split(':');
  return Connection.open(
    Endpoint(
      host: uri.host,
      port: uri.hasPort ? uri.port : 5432,
      database: uri.path.substring(1),
      username: ui.isNotEmpty ? ui[0] : null,
      password: ui.length > 1 ? ui.sublist(1).join(':') : null,
    ),
    settings: ConnectionSettings(sslMode: SslMode.require),
  );
}

String token() =>
    FhJwt.generateToken(userId: 1, email: 'ot@test.uz', role: 'admin');

Future<(int, Map<String, dynamic>)> call(
  String method,
  String path, {
  Map<String, dynamic>? body,
}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, Uri.parse('$base$path'));
    req.headers.set('Content-Type', 'application/json');
    req.headers.set('Authorization', 'Bearer ${token()}');
    if (body != null) req.write(jsonEncode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    Map<String, dynamic> json = <String, dynamic>{};
    try {
      if (text.isNotEmpty) json = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {}
    return (res.statusCode, json);
  } finally {
    client.close();
  }
}

int pass = 0;
int fail = 0;
void check(String label, bool ok, [String? extra]) {
  if (ok) {
    pass++;
    stdout.writeln('PASS  $label${extra != null ? ' — $extra' : ''}');
  } else {
    fail++;
    stdout.writeln('FAIL  $label${extra != null ? ' — $extra' : ''}');
  }
}

Future<void> main() async {
  final c = await connect();
  final dateStr =
      DateTime.now().toUtc().add(const Duration(hours: 5)).toIso8601String().substring(0, 10);

  // Xodim yaratamiz (salary).
  final empResp = await call('POST', '/hr/employees', body: {
    'fullName': 'OT Test Xodim',
    'status': 'active',
    'baseSalary': 1000000,
    'payType': 'salary',
  });
  final empId = empResp.$2['employee']?['id'] as int?;
  check('employee created', empResp.$1 == 201 || empResp.$1 == 201, 'id=$empId');

  try {
    // 08:00-18:00 => hoursWorked 8, overtime yo'q
    final r1 = await call('POST', '/hr/attendance', body: {
      'employeeId': empId,
      'workDate': dateStr,
      'checkIn': '08:00',
      'checkOut': '18:00',
    });
    final a1 = r1.$2['attendance'];
    check('08:00-18:00 -> hours 8', a1?['hoursWorked']?.toString() == '8.0',
        'hours=${a1?['hoursWorked']} ot=${a1?['overtimeHours']}');
    check('overtime default 0', (num.tryParse(a1?['overtimeHours']?.toString() ?? '') ?? -1) == 0,
        'ot=${a1?['overtimeHours']}');

    // Keyingi kun qo'shimcha ish bilan
    final date2 = DateTime.now().toUtc().add(const Duration(hours: 5, days: 1)).toIso8601String().substring(0, 10);
    final r2 = await call('POST', '/hr/attendance', body: {
      'employeeId': empId,
      'workDate': date2,
      'checkIn': '08:00',
      'checkOut': '18:00',
      'overtimeHours': 2.5,
    });
    final a2 = r2.$2['attendance'];
    check('with overtime 2.5 saved', a2?['overtimeHours']?.toString() == '2.5',
        'ot=${a2?['overtimeHours']}');

    // Qisqa kun: 08:00-12:00 => 4 soat (chegara bilans emas)
    final date3 = DateTime.now().toUtc().add(const Duration(hours: 5, days: 2)).toIso8601String().substring(0, 10);
    final r3 = await call('POST', '/hr/attendance', body: {
      'employeeId': empId,
      'workDate': date3,
      'checkIn': '08:00',
      'checkOut': '12:00',
    });
    final a3 = r3.$2['attendance'];
    check('08:00-12:00 -> hours 4', a3?['hoursWorked']?.toString() == '4.0',
        'hours=${a3?['hoursWorked']}');

    // PUT: overtime o'zgartirish
    final r4 = await call('PUT', '/hr/attendance/${a1?['id']}', body: {
      'overtimeHours': 3,
    });
    final a4 = r4.$2['attendance'];
    check('PUT overtime -> 3', a4?['overtimeHours']?.toString() == '3.0',
        'ot=${a4?['overtimeHours']}');

    // PUT: vaqt o'zgartirganda hours qayta hisoblanadi (cap bilan)
    final r5 = await call('PUT', '/hr/attendance/${a1?['id']}', body: {
      'checkIn': '08:00',
      'checkOut': '20:00',
    });
    final a5 = r5.$2['attendance'];
    check('PUT 08:00-20:00 -> hours 8 (8 soatlik mehnat normasi)', a5?['hoursWorked']?.toString() == '8.0',
        'hours=${a5?['hoursWorked']} ot=${a5?['overtimeHours']}');

    // Monthly reportda total_overtime_hours
    final mr = await call('GET', '/hr/reports/monthly?employee_id=$empId');
    final rows = (mr.$2['rows'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
    final row = rows.isEmpty
        ? <String, dynamic>{}
        : rows.firstWhere(
            (x) => x['fullName'] == 'OT Test Xodim',
            orElse: () => <String, dynamic>{},
          );
    check('monthly totalOvertimeHours present', row.isNotEmpty && row['totalOvertimeHours'] != null,
        'totalOt=${row['totalOvertimeHours']} totalHours=${row['totalHours']}');

    // GET attendance overtime ko'rinadi
    final g = await call('GET', '/hr/attendance?employee_id=$empId');
    final list = (g.$2['attendance'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
    final hasOt = list.any((x) => (x['overtimeHours'] ?? 0) > 0);
    check('GET attendance overtime visible', hasOt, 'count=${list.length}');

    await c.execute('DELETE FROM fh.attendance WHERE employee_id = \$1', parameters: [empId]);
    await c.execute('DELETE FROM fh.employees WHERE id = \$1', parameters: [empId]);
  } finally {
    try {
      await c.execute('DELETE FROM fh.attendance WHERE employee_id = \$1', parameters: [empId]);
      await c.execute('DELETE FROM fh.employees WHERE id = \$1', parameters: [empId]);
    } catch (_) {}
    await c.close();
  }
  stdout.writeln('\nOT PROBE: PASS=$pass FAIL=$fail');
  if (fail > 0) exit(1);
}