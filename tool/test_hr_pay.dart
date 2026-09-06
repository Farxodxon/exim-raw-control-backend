import 'dart:convert';
import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:dotenv/dotenv.dart';
import 'package:exim_raw_backend/factoryhub/jwt.dart';

// HR pay_type (salary/piece_rate/hybrid) tugunlari — e2e (009 migratsiya).
// Talab: local server 8051 da ishlayapti.

const base = 'http://127.0.0.1:8051/fh';
const P = 'HRE2E %';

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

String token({required int userId, required String role}) =>
    FhJwt.generateToken(userId: userId, email: 'hre2e@test.uz', role: role);

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

Future<void> main() async {
  final c = await connect();

  final users = await c.execute('SELECT id, role FROM fh.users WHERE is_active ORDER BY id');
  var adminId = 0;
  for (final r in users) {
    if (r[1] == 'admin') { adminId = (r[0] as num).toInt(); break; }
  }
  final adminTok = token(userId: adminId, role: 'admin');

  var whProd = 0;
  final warehouses = await c.execute(
      'SELECT id, type, is_default FROM fh.warehouses WHERE is_active ORDER BY id');
  final defs = <String, int>{};
  final firsts = <String, int>{};
  for (final r in warehouses) {
    final id = (r[0] as num).toInt();
    final id2 = r[1] as String;
    final isDefault = r[2] as bool;
    firsts.putIfAbsent(id2, () => id);
    if (isDefault) defs[id2] = id;
  }
  whProd = (defs['production'] ?? firsts['production'])!;

  // ── TOZALASH ──────────────────────────────────────────────────────────
  Future<void> cleanup() async {
    // ish yozuvlari avval (batch/employee FK)
    await c.execute('DELETE FROM fh.work_records WHERE employee_id IN '
        '(SELECT id FROM fh.employees WHERE full_name LIKE \$1)', parameters: [P]);
    await c.execute('DELETE FROM fh.piece_rates WHERE description LIKE \$1 OR unit = \'kg\' AND work_type = \'mixing\' '
        'AND created_at > now() - interval \'1 day\'', parameters: [P]);
    await c.execute('UPDATE fh.production_batches SET transfer_id = NULL WHERE product_barcode LIKE \$1',
        parameters: [P]);
    await c.execute('DELETE FROM fh.stock_transfers WHERE item_id IN '
        '(SELECT id FROM fh.items WHERE name LIKE \$1)', parameters: [P]);
    await c.execute('DELETE FROM fh.production_batches WHERE product_barcode LIKE \$1', parameters: [P]);
    await c.execute('DELETE FROM fh.bom_items WHERE bom_id IN (SELECT id FROM fh.boms WHERE name LIKE \$1)',
        parameters: [P]);
    await c.execute('DELETE FROM fh.boms WHERE name LIKE \$1', parameters: [P]);
    await c.execute('DELETE FROM fh.stock_ledger WHERE name_snapshot LIKE \$1', parameters: [P]);
    // attendance / salary_adjustments → employees
    await c.execute('DELETE FROM fh.attendance WHERE employee_id IN '
        '(SELECT id FROM fh.employees WHERE full_name LIKE \$1)', parameters: [P]);
    await c.execute('DELETE FROM fh.salary_adjustments WHERE employee_id IN '
        '(SELECT id FROM fh.employees WHERE full_name LIKE \$1)', parameters: [P]);
    await c.execute('DELETE FROM fh.employees WHERE full_name LIKE \$1', parameters: [P]);
    await c.execute('DELETE FROM fh.items WHERE name LIKE \$1', parameters: [P]);
  }
  await cleanup();

  // ── TES DATA ──────────────────────────────────────────────────────────
  final raw = await c.execute(
      "INSERT INTO fh.items (name, item_type, code, unit) VALUES ('HRE2E Xom','raw','hre2e-raw','kg') RETURNING id");
  final out1 = await c.execute(
      "INSERT INTO fh.items (name, item_type, code, unit) VALUES ('HRE2E Yarim1','semi_finished','hre2e-semi1','kg') RETURNING id");
  final out2 = await c.execute(
      "INSERT INTO fh.items (name, item_type, code, unit) VALUES ('HRE2E Yarim2','semi_finished','hre2e-semi2','kg') RETURNING id");
  final iRaw = (raw.first[0] as num).toInt();
  final iOut1 = (out1.first[0] as num).toInt();
  final iOut2 = (out2.first[0] as num).toInt();

  final bom1 = await c.execute(
      "INSERT INTO fh.boms (name, stage, output_item_id, output_qty_per_batch, output_unit) "
      "VALUES ('HRE2E Mix1', 'mixing', \$1, 5, 'kg') RETURNING id", parameters: [iOut1]);
  final bom2 = await c.execute(
      "INSERT INTO fh.boms (name, stage, output_item_id, output_qty_per_batch, output_unit) "
      "VALUES ('HRE2E Mix2', 'mixing', \$1, 5, 'kg') RETURNING id", parameters: [iOut2]);
  final idBom1 = (bom1.first[0] as num).toInt();
  final idBom2 = (bom2.first[0] as num).toInt();
  await c.execute(
      "INSERT INTO fh.bom_items (bom_id, item_type, ref_id, name_snapshot, unit, qty) "
      "VALUES (\$1, 'raw', \$2, 'HRE2E Xom', 'kg', 2)", parameters: [idBom1, iRaw]);
  await c.execute(
      "INSERT INTO fh.bom_items (bom_id, item_type, ref_id, name_snapshot, unit, qty) "
      "VALUES (\$1, 'raw', \$2, 'HRE2E Xom', 'kg', 2)", parameters: [idBom2, iRaw]);
  await c.execute(
      '''INSERT INTO fh.stock_ledger (warehouse_id, item_type, ref_id, name_snapshot, unit,
           direction, qty, source_type, performed_by, note)
         VALUES (\$1, 'raw', \$2, 'HRE2E Xom', 'kg', 'in', 100, 'manual', \$3, 'HRE2E seed')''',
      parameters: [whProd, iRaw, adminId]);

  // ── XODIMLAR ─────────────────────────────────────────────────────────
  var (s, j) = await call('POST', '/hr/employees', body: {
    'fullName': 'HRE2E Ishbay', 'position': 'Operator', 'payType': 'piece_rate',
  }, tokenStr: adminTok);
  final ePiece = (j['employee'] as Map<String, dynamic>)['id'] as int;
  check('employee POST piece_rate 201', s == 201, 's=$s $j');
  check('employee payType returned', j['employee']?['payType'] == 'piece_rate', '$j');

  (s, j) = await call('POST', '/hr/employees', body: {
    'fullName': 'HRE2E Oylik', 'position': 'Buxgalter', 'payType': 'salary', 'baseSalary': 500000,
  }, tokenStr: adminTok);
  final eSalary = (j['employee'] as Map<String, dynamic>)['id'] as int;
  check('employee POST salary 201', s == 201, 's=$s $j');

  (s, j) = await call('POST', '/hr/employees', body: {
    'fullName': 'HRE2E Aralash', 'position': 'Master', 'payType': 'hybrid', 'baseSalary': 300000,
  }, tokenStr: adminTok);
  final eHybrid = (j['employee'] as Map<String, dynamic>)['id'] as int;
  check('employee POST hybrid 201', s == 201, 's=$s $j');

  (s, j) = await call('GET', '/hr/employees?search=HRE2E', tokenStr: adminTok);
  check('employees GET list ok', s == 200 && (j['employees'] as List).length >= 3, 's=$s');

  (s, j) = await call('POST', '/hr/employees', body: {
    'fullName': 'HRE2E Xato', 'payType': 'soatbay',
  }, tokenStr: adminTok);
  check('invalid payType 400', s == 400, 's=$s');

  // ── STAVKALAR ────────────────────────────────────────────────────────
  (s, j) = await call('POST', '/hr/piece-rates', body: {
    'workType': 'mixing', 'itemId': iOut1, 'ratePerUnit': 2000, 'unit': 'kg',
    'description': 'HRE2E stavka',
  }, tokenStr: adminTok);
  final rateId = (j['rate'] as Map<String, dynamic>?)?['id'] as int?;
  check('piece-rate POST 201', s == 201, 's=$s $j');
  check('piece-rate id', rateId != null, '$j');

  double numOf(Object? v) => double.parse(v.toString().replaceAll(' ', ''));

  (s, j) = await call('GET', '/hr/piece-rates?work_type=mixing', tokenStr: adminTok);
  check('piece-rates GET ok', s == 200, 's=$s');
  check('piece-rates lists ours', (j['rates'] as List).any((r) => numOf(r['ratePerUnit']) == 2000), '$j');

  (s, j) = await call('POST', '/hr/piece-rates', body: {
    'workType': 'boshqa', 'ratePerUnit': 100, 'unit': 'dona',
  }, tokenStr: adminTok);
  check('invalid workType 400', s == 400, 's=$s');

  // ── MIXING: ishbay auto yozuv (stavka bor) ───────────────────────────
  (s, j) = await call('POST', '/production/mixing/start', body: {
    'bom_id': idBom1, 'output_quantity': 10, 'employee_id': ePiece,
  }, tokenStr: adminTok);
  check('mixing start with piece employee 201', s == 201, 's=$s $j');
  check('mixing returns employeeId', j['employeeId'] == ePiece, '$j');
  check('mixing no warning', j['warning'] == null, '$j');

  var wr = await c.execute(
      'SELECT quantity, rate_applied, computed_amount, piece_rate_id, production_batch_id '
      'FROM fh.work_records WHERE employee_id = \$1 AND work_type = \'mixing\'',
      parameters: [ePiece]);
  check('auto work_record created', wr.isNotEmpty, 'wr=$wr');
  if (wr.isNotEmpty) {
    check('wr quantity = output 10', double.parse(wr.first[0].toString()) == 10, '${wr.first[0]}');
    check('wr rate_applied 2000', double.parse(wr.first[1].toString()) == 2000, '${wr.first[1]}');
    check('wr computed = 20000', double.parse(wr.first[2].toString()) == 20000, '${wr.first[2]}');
    check('wr rate_id linked', wr.first[3] == rateId, '${wr.first[3]}');
  }
  final bch = await c.execute(
      'SELECT employee_id FROM fh.production_batches WHERE bom_id = \$1 AND product_barcode LIKE \$2',
      parameters: [idBom1, P]);
  check('production_batch.employee_id set', bch.isNotEmpty && bch.first[0] == ePiece, '$bch');

  // ── MIXING: stavka yo'q -> warning, partiya saqlanadi ─────────────────
  (s, j) = await call('POST', '/production/mixing/start', body: {
    'bom_id': idBom2, 'output_quantity': 10, 'employee_id': ePiece,
  }, tokenStr: adminTok);
  check('mixing without rate 201 + warning', s == 201 && j['warning'] != null, 's=$s $j');
  wr = await c.execute(
      'SELECT COUNT(*) FROM fh.work_records WHERE work_type = \'mixing\' AND note LIKE \$2 AND employee_id = \$1',
      parameters: [ePiece, '%HRE2E Mix2%']);
  check('no auto record when no rate', wr.first[0] == 0, '${wr.first[0]}');

  // ── QO'LDA ISH YOZUVLARI ─────────────────────────────────────────────
  (s, j) = await call('POST', '/hr/work-records', body: {
    'employeeId': eHybrid, 'workType': 'other', 'quantity': 3, 'unit': 'dona',
    'rateApplied': 15000, 'note': 'Qo\'shimcha ish (HRE2E saqlanadi)',
  }, tokenStr: adminTok);
  check('manual work-record 201', s == 201, 's=$s $j');
  check('manual computed 45000', j['computedAmount'] == '45000.00', '$j');

  (s, j) = await call('POST', '/hr/work-records', body: {
    'employeeId': eHybrid, 'workType': 'other', 'quantity': 1, 'unit': 'dona',
    'rateApplied': 15000, 'note': 'HRE2E o\'chiriladi',
  }, tokenStr: adminTok);
  check('manual2 201', s == 201, 's=$s $j');
  final wrId = j['id'] as int?;

  (s, j) = await call('POST', '/hr/work-records', body: {
    'employeeId': eHybrid, 'workType': 'other', 'quantity': 1, 'unit': 'dona',
  }, tokenStr: adminTok);
  check('manual without rate 400', s == 400, 's=$s');

  (s, j) = await call('GET', '/hr/work-records?employee_id=$eHybrid', tokenStr: adminTok);
  check('work-records GET filters employee', s == 200, 's=$s');
  check('work-records has kept manual', (j['records'] as List).any((r) => numOf(r['quantity']) == 3), '$j');

  (s, j) = await call('DELETE', '/hr/work-records/$wrId', tokenStr: adminTok);
  check('work-record DELETE ok', s == 200, 's=$s');
  (s, j) = await call('GET', '/hr/work-records?employee_id=$eHybrid', tokenStr: adminTok);
  check('deleted record gone', !(j['records'] as List).any((r) => r['note'] == 'HRE2E o\'chiriladi'), '$j');

  // ── DAVOMAT + BONUS (oylik ishbay qismi nol bo'lishi uchun) ───────────
  (s, j) = await call('POST', '/hr/attendance', body: {
    'employeeId': eSalary, 'workDate': DateTime.now().toIso8601String().substring(0, 10),
    'status': 'present', 'hoursWorked': 8,
  }, tokenStr: adminTok);
  check('attendance add 201', s == 201, 's=$s $j');

  (s, j) = await call('POST', '/hr/salary-adjustments', body: {
    'employeeId': eSalary, 'adjustmentType': 'bonus', 'amount': 100000,
    'reason': 'HRE2E bonus', 'adjustmentDate': DateTime.now().toIso8601String().substring(0, 10),
  }, tokenStr: adminTok);
  final adjId = (j['adjustment'] as Map<String, dynamic>?)?['id'] as int?;
  check('salary bonus POST 201', s == 201, 's=$s $j');
  (s, j) = await call('PUT', '/hr/salary-adjustments/$adjId/approve', tokenStr: adminTok);
  check('bonus approve 200', s == 200, 's=$s');

  // ── OYLIK HISOBOT ────────────────────────────────────────────────────
  final m = DateTime.now().toIso8601String().substring(0, 7);
  (s, j) = await call('GET', '/hr/reports/monthly?month=$m', tokenStr: adminTok);
  check('monthly report 200', s == 200, 's=$s');
  final rows = (j['rows'] as List?) ?? [];
  check('monthly has 3 employees', rows.length >= 3, '${rows.length}');
  Map<String, dynamic>? rowFor(int eid) =>
      rows.cast<Map<String, dynamic>>().where((r) => r['employeeId'] == eid).firstOrNull;

  final rPiece = rowFor(ePiece);
  check('piece: base 0, piece 20000, net 20000',
      rPiece != null && rPiece['payType'] == 'piece_rate' &&
          numOf(rPiece['baseSalaryComponent']) == 0 &&
          numOf(rPiece['pieceRateComponent']) == 20000 &&
          numOf(rPiece['netAmount']) == 20000,
      '$rPiece');

  final rSalary = rowFor(eSalary);
  check('salary: base 500000, piece 0, net 600000',
      rSalary != null && rSalary['payType'] == 'salary' &&
          numOf(rSalary['baseSalaryComponent']) == 500000 &&
          numOf(rSalary['pieceRateComponent']) == 0 &&
          numOf(rSalary['netAmount']) == 600000,
      '$rSalary');

  final rHybrid = rowFor(eHybrid);
  check('hybrid: base 300000 + piece 45000 = 345000',
      rHybrid != null && rHybrid['payType'] == 'hybrid' &&
          numOf(rHybrid['baseSalaryComponent']) == 300000 &&
          numOf(rHybrid['pieceRateComponent']) == 45000 &&
          numOf(rHybrid['netAmount']) == 345000,
      '$rHybrid');

  // ── XODIMNI USERG A BOG'LASH + AVTO ANIQLASH ─────────────────────────
  final someUser = (await c.execute('SELECT id FROM fh.users WHERE role = \'warehouse_keeper\' LIMIT 1'));
  if (someUser.isNotEmpty) {
    final uid = (someUser.first[0] as num).toInt();
    (s, j) = await call('PUT', '/hr/employees/$ePiece', body: {'userId': uid}, tokenStr: adminTok);
    check('employee PUT userId ok', s == 200 && j['employee']?['userId'] == uid, 's=$s $j');
  }

  await cleanup();
  print('HR HR PAY: PASS=$_pass FAIL=$_fail');
  await c.close();
  if (_fail > 0) exitCode = 1;
}