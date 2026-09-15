import 'dart:convert';
import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:dotenv/dotenv.dart';
import 'package:exim_raw_backend/factoryhub/jwt.dart';

// Payroll V2 API testi: holidays CRUD + work_records v2 (hours_worked/day_type)
// + oylik ish haqi (monthly-report) payroll.dart bilan.
// Talab: server 8051 da ishlayapti (dart run lib/server.dart, PORT=8051).
// Qabul mezonlari:
//   Nigora (oklad 5,000,000, 2025-03): 25 ish kuni, norma 200 soat,
//     6 dam kuni ishlagan, 20 soat ish kuni ortiqchasi -> JAMI 6,700,000
//   Madina (ishbay 1500 so'm/dona, 2025-03): 7 sof kun + 1 aralash kun
//     (95 dona, 2 soat, avg 29,116) -> 1,831,232

const base = 'http://127.0.0.1:8051/fh';
const P = 'PAYROLL-V2 %';

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

Future<(int, Map<String, dynamic>)> call(
  String method,
  String path, {
  Map<String, dynamic>? body,
  String? tokenStr,
}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, Uri.parse('$base$path'));
    req.headers.set('Content-Type', 'application/json');
    if (tokenStr != null) req.headers.set('Authorization', 'Bearer $tokenStr');
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

String token({required int userId, required String role}) =>
    FhJwt.generateToken(userId: userId, email: 'payrollv2@test.uz', role: role);

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    print('PASS  $name');
  } else {
    _fail++;
    print('FAIL  $name  ${detail ?? ''}');
  }
}

double num2(String? s) => double.tryParse(s ?? '') ?? double.nan;

Future<void> main() async {
  final c = await connect();
  final users = await c.execute("SELECT id FROM fh.users WHERE role='admin' ORDER BY id LIMIT 1");
  final adminTok = token(userId: (users.first[0] as num).toInt(), role: 'admin');

  // ---- tozalash ----
  final olds = await c.execute(
      "SELECT id FROM fh.employees WHERE full_name LIKE 'PayrollV2 %' OR full_name LIKE 'Nigora PayrollV2' OR full_name LIKE 'Madina PayrollV2'");
  final oldIds = olds.map((r) => (r[0] as num).toInt()).toList();
  for (final id in oldIds) {
    for (final t in ['fh.work_records', 'fh.attendance', 'fh.salary_adjustments', 'fh.piece_rates']) {
      try {
        await c.execute('DELETE FROM $t WHERE employee_id = \$1', parameters: [id]);
      } catch (_) {}
    }
    await c.execute('DELETE FROM fh.employees WHERE id = \$1', parameters: [id]);
  }
  await c.execute("DELETE FROM fh.holidays WHERE holiday_date = '2025-03-21'");

  // ---- 1) Holidays CRUD ----
  var (code, body) = await call('POST', '/hr/holidays', body: {
    'holidayDate': '2025-03-21',
    'label': 'Kun',
  }, tokenStr: adminTok);
  check('POST /hr/holidays 201', code == 201, 'code=$code body=$body');
  final holId = (body['holiday']?['id'] as num?)?.toInt();

  (code, body) = await call('POST', '/hr/holidays', body: {
    'holidayDate': '2025-03-21',
    'label': 'Kun',
  }, tokenStr: adminTok);
  check('POST duplicate 409', code == 409, 'code=$code');

  (code, body) = await call('GET', '/hr/holidays?month=2025-03', tokenStr: adminTok);
  final holList = (body['holidays'] as List).where((h) => h['id'] == holId).toList();
  check('GET /hr/holidays?month=2025-03 contains 21', holList.isNotEmpty, body.toString());

  (code, body) = await call('PUT', '/hr/holidays/$holId', body: {'label': 'Milliy bayram'}, tokenStr: adminTok);
  check('PUT /hr/holidays label', code == 200 && body['holiday']['label'] == 'Milliy bayram', 'code=$code body=$body');

  (code, body) = await call('POST', '/hr/holidays', body: {'label': 'X'}, tokenStr: adminTok);
  check('POST without date 400', code == 400, 'code=$code');

  // ---- 2) Xodimlar ----
  (code, body) = await call('POST', '/hr/employees', body: {
    'fullName': 'Nigora PayrollV2',
    'position': 'qadoqlash operatori',
    'department': 'Qadoqlash',
    'baseSalary': 5000000,
    'payType': 'salary',
    'status': 'active',
  }, tokenStr: adminTok);
  check('create Nigora 201', code == 201, 'code=$code body=$body');
  final nigoraId = (body['employee']['id'] as num?)?.toInt();

  (code, body) = await call('POST', '/hr/employees', body: {
    'fullName': 'Madina PayrollV2',
    'position': 'qadoqlash operatori',
    'department': 'Qadoqlash',
    'baseSalary': 0,
    'payType': 'piece_rate',
    'status': 'active',
  }, tokenStr: adminTok);
  check('create Madina 201', code == 201, 'code=$code body=$body');
  final madinaId = (body['employee']['id'] as num?)?.toInt();

  // ---- 3) Nigora davomati: 6 dam kuni + 20 soat ish kuni ortiqchasi ----
  final restDays = ['2025-03-02', '2025-03-09', '2025-03-16', '2025-03-23', '2025-03-30', '2025-03-21'];
  for (final d in restDays) {
    await c.execute(
      'INSERT INTO fh.attendance (employee_id, work_date, status, hours_worked, overtime_hours) '
      'VALUES (\$1, \$2, \'present\', 0, 0) ON CONFLICT (employee_id, work_date) DO UPDATE SET status=\'present\', hours_worked=0, overtime_hours=0',
      parameters: [nigoraId, d]);
  }
  final otDays = ['2025-03-03', '2025-03-04', '2025-03-05', '2025-03-06', '2025-03-07',
                  '2025-03-10', '2025-03-11', '2025-03-12', '2025-03-13', '2025-03-14'];
  for (final d in otDays) {
    await c.execute(
      'INSERT INTO fh.attendance (employee_id, work_date, status, hours_worked, overtime_hours) '
      'VALUES (\$1, \$2, \'present\', 8, 2) ON CONFLICT (employee_id, work_date) DO UPDATE SET status=\'present\', hours_worked=8, overtime_hours=2',
      parameters: [nigoraId, d]);
  }

  // ---- 4) Madina work_records v2 (API orqali) ----
  final sof = [158, 142, 169, 172, 141, 135, 170];
  final sofDates = ['2025-03-03', '2025-03-04', '2025-03-05', '2025-03-06', '2025-03-07',
                    '2025-03-10', '2025-03-11'];
  int? aralashId;
  for (var i = 0; i < sof.length; i++) {
    (code, body) = await call('POST', '/hr/work-records', body: {
      'employeeId': madinaId,
      'workDate': sofDates[i],
      'workType': 'packaging',
      'quantity': sof[i],
      'unit': 'dona',
      'rateApplied': 1500,
      'dayType': 'sof_qadoqlash',
    }, tokenStr: adminTok);
    check('sof_qadoqlash #$i 201', code == 201, 'code=$code body=$body');
  }
  (code, body) = await call('POST', '/hr/work-records', body: {
    'employeeId': madinaId,
    'workDate': '2025-03-12',
    'workType': 'packaging',
    'quantity': 95,
    'unit': 'dona',
    'rateApplied': 1500,
    'dayType': 'aralash',
    'hoursWorked': 2,
  }, tokenStr: adminTok);
  check('aralash 201 (computed null, pending)', code == 201 && body['dayType'] == 'aralash' && body['computedAmount'] == null, 'code=$code body=$body');
  aralashId = (body['id'] as num?)?.toInt();

  // soatbay: quantity=0 bilan
  final (sCode, sBody) = await call('POST', '/hr/work-records', body: {
    'employeeId': madinaId,
    'workDate': '2025-03-13',
    'workType': 'packaging',
    'quantity': 0,
    'unit': 'dona',
    'rateApplied': 1500,
    'dayType': 'sof_soatbay',
    'hoursWorked': 4,
  }, tokenStr: adminTok);
  check('sof_soatbay 201 (qty=0, soat 4)', sCode == 201 && sBody['dayType'] == 'sof_soatbay', 'code=$sCode body=$sBody');
  final soatbayId = (sBody['id'] as num?)?.toInt();

  // Validation xatolari
  (code, body) = await call('POST', '/hr/work-records', body: {
    'employeeId': madinaId, 'quantity': 3, 'rateApplied': 1500, 'dayType': 'sof_soatbay'},
    tokenStr: adminTok);
  check('sof_soatbay qty>0 -> 400', code == 400, 'code=$code');
  (code, body) = await call('POST', '/hr/work-records', body: {
    'employeeId': madinaId, 'quantity': 3, 'rateApplied': 1500, 'dayType': 'aralash'},
    tokenStr: adminTok);
  check('aralash hours<>0 -> 400', code == 400, 'code=$code');
  (code, body) = await call('POST', '/hr/work-records', body: {
    'employeeId': madinaId, 'quantity': 0, 'rateApplied': 1500, 'dayType': 'sof_qadoqlash'},
    tokenStr: adminTok);
  check('sof_qadoqlash qty=0 -> 400', code == 400, 'code=$code');
  (code, body) = await call('POST', '/hr/work-records', body: {
    'employeeId': madinaId, 'quantity': 3, 'rateApplied': 1500, 'dayType': 'noto_gri'},
    tokenStr: adminTok);
  check('dayType noto`g`ri -> 400', code == 400, 'code=$code');

  // GET work-records v2 maydonlari
  (code, body) = await call('GET', '/hr/work-records?employee_id=$madinaId&month=2025-03', tokenStr: adminTok);
  final recs = body['records'] as List;
  final ar = recs.firstWhere((r) => r['id'] == aralashId, orElse: () => <String, dynamic>{});
  check('GET work-records has dayType+hours', ar['dayType'] == 'aralash' && num2(ar['hoursWorked']) == 2.0 && (ar['computedAmount'] == null), ar.toString());
  final sb = recs.firstWhere((r) => r['id'] == soatbayId, orElse: () => <String, dynamic>{});
  check('GET soatbay record qty=0 hours=4', sb['dayType'] == 'sof_soatbay' && num2(sb['quantity']) == 0.0 && num2(sb['hoursWorked']) == 4.0, sb.toString());
  check('GET work-records count=9', (recs).length == 9, 'count=${recs.length}');

  // ---- 5) Monthly-report: Nigora oklad ----
  (code, body) = await call('GET', '/hr/monthly-report?year=2025&month=3&employee_id=$nigoraId', tokenStr: adminTok);
  check('monthly-report Nigora 200 (1 row)', code == 200 && (body['rows'] as List).length == 1, 'code=$code body=$body');
  final nr = (body['rows'] as List).first as Map<String, dynamic>;
  check('Nigora workingDays=25', nr['workingDays'] == 25, nr.toString());
  check('Nigora normHours=200', nr['normHours'] == 200, nr.toString());
  check('Nigora hourlyRate=25000', nr['hourlyRate'] == '25000', nr.toString());
  check('Nigora restDaysWorked=6', nr['restDaysWorked'] == 6, nr.toString());
  check('Nigora workdayOvertimeHours=20', nr['workdayOvertimeHours'] == '20.0', nr.toString());
  check('Nigora overtimeHours=68', nr['overtimeHours'] == '68.0', nr.toString());
  check('Nigora overtimePay=1,700,000', nr['overtimePay'] == '1700000', nr.toString());
  check('Nigora JAMI=6,700,000', nr['total'] == '6700000', '${nr['total']}');

  // ---- 6) Monthly-report: Madina ishbay ----
  (code, body) = await call('GET', '/hr/monthly-report?year=2025&month=3&employee_id=$madinaId', tokenStr: adminTok);
  check('monthly-report Madina 200', code == 200, 'code=$code body=$body');
  final mr = (body['rows'] as List).first as Map<String, dynamic>;
  check('Madina pieceDays=9', mr['pieceDays'] == 9, mr.toString());
  check('Madina avgHourlyRate=29116', mr['avgHourlyRate'] == '29116', '${mr['avgHourlyRate']}');
  // pendingDays faqat sof kun yo'q bo'lganda >0 bo'ladi; Madinada 7 sof kun -> avg bor.
  check('Madina pendingDays=0', mr['pendingDays'] == 0, '${mr['pendingDays']}');

  // 7 sof kuni (havo) = 1087 dona, aralash 95 dona = 1182 dona -> sof qismi
  // 7*1500*... hisob: 1087*1500=1,630,500; 1,630,500/(7*8)=29,116.07->29,116
  // aralash: 95*1500 + 2*29116 = 142,500+58,232 = 200,732 -> JAMI 1,831,232
  // soatbay (4 soat, 2025-03-13): 4*29116 = 116,464 -> JAMI 1,947,696
  check('Madina JAMI=1,947,696', mr['pieceTotal'] == '1947696', '${mr['pieceTotal']}');

  // soatbay kunini o'chirsak -> canonical 1,831,232
  await call('DELETE', '/hr/work-records/$soatbayId', tokenStr: adminTok);
  (code, body) = await call('GET', '/hr/monthly-report?year=2025&month=3&employee_id=$madinaId', tokenStr: adminTok);
  final mr2 = (body['rows'] as List).first as Map<String, dynamic>;
  check('Madina SOf 7 kun JAMI=1,831,232', mr2['pieceTotal'] == '1831232', '${mr2['pieceTotal']}');
  check('Madina avg=29116 (kanonik)', mr2['avgHourlyRate'] == '29116', '${mr2['avgHourlyRate']}');

  // ---- 7) Umumiy hisobot + birga ----
  (code, body) = await call('GET', '/hr/monthly-report?year=2025&month=3', tokenStr: adminTok);
  final rows = body['rows'] as List;
  final nRow = rows.firstWhere((r) => r['employeeId'] == nigoraId, orElse: () => <String, dynamic>{});
  final mRow = rows.firstWhere((r) => r['employeeId'] == madinaId, orElse: () => <String, dynamic>{});
  check('umumiy hisobot 200', code == 200, 'code=$code');
  check('umumiy: Nigora 6,700,000', nRow['total'] == '6700000', nRow.toString());
  check('umumiy: Madina 1,831,232', mRow['total'] == '1831232', mRow.toString());
  final sumTotals = rows.fold<num>(0, (s, r) => s + int.parse(r['total'].toString()));
  check('summary.totalPayroll = satrlar yig`indisi', body['summary']['totalPayroll'] == '$sumTotals', '${body['summary']['totalPayroll']} vs $sumTotals');

  // ---- 8) Legacy POST (dayType/isiz) hali ishlaydi ----
  (code, body) = await call('POST', '/hr/work-records', body: {
    'employeeId': nigoraId,
    'workDate': '2025-03-17',
    'workType': 'packaging',
    'quantity': 100,
    'unit': 'dona',
    'rateApplied': 1500,
  }, tokenStr: adminTok);
  check('legacy POST 201 computed=150000', code == 201 && body['computedAmount'] == '150000.00', 'code=$code body=$body');
  final legId = (body['id'] as num?)?.toInt();
  await call('DELETE', '/hr/work-records/$legId', tokenStr: adminTok);

  // ---- 9) O'chirishlar ----
  (code, body) = await call('DELETE', '/hr/holidays/$holId', tokenStr: adminTok);
  check('DELETE /hr/holidays 200', code == 200, 'code=$code');
  (code, body) = await call('GET', '/hr/holidays?month=2025-03', tokenStr: adminTok);
  check('holidays bo`sh', (body['holidays'] as List).isEmpty, body.toString());

  // tozalash
  for (final did in [nigoraId, madinaId]) {
    for (final t in ['fh.work_records', 'fh.attendance', 'fh.salary_adjustments']) {
      try {
        await c.execute('DELETE FROM $t WHERE employee_id = \$1', parameters: [did]);
      } catch (_) {}
    }
    await c.execute('DELETE FROM fh.employees WHERE id = \$1', parameters: [did]);
  }
  await c.execute("DELETE FROM fh.holidays WHERE holiday_date = '2025-03-21'");
  await c.close();

  print('\n$P RESULT: pass=$_pass fail=$_fail');
  exit(_fail == 0 ? 0 : 1);
}