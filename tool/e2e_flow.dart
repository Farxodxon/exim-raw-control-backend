import 'dart:convert';
import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:dotenv/dotenv.dart';
import 'package:exim_raw_backend/factoryhub/jwt.dart';

// E2E: soddalashtirilgan ishlab chiqarish/qadoqlash oqimi (004).
// Talab: local server 8051 da ishlayapti; 004 migratsiya bajarilgan.

const base = 'http://127.0.0.1:8051/fh';
const P = 'E2E %';

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
    FhJwt.generateToken(userId: userId, email: 'e2e@test.uz', role: role);

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

Future<double> balance(Connection c, int wh, String itemType, int? refId) async {
  final r = await c.execute(
    '''
    SELECT COALESCE(SUM(CASE direction WHEN 'in' THEN qty ELSE -qty END), 0)
    FROM fh.stock_ledger
    WHERE warehouse_id = \$1 AND item_type = \$2 AND (\$3::int IS NULL OR ref_id = \$3)
    ''',
    parameters: [wh, itemType, refId],
  );
  return double.parse(r.first[0].toString());
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

  var adminId = 0, opsId = 0;
  var whProd = 0, whSemi = 0, whPkg = 0, whRaw = 0, whDef = 0, whQuar = 0, whFin = 0;

  // Umumiy taqsimlash
  void useDefs(int prod, int semi, int pkg, int raw, int def, int quar, int fin) {
    whProd = prod; whSemi = semi; whPkg = pkg; whRaw = raw; whDef = def; whQuar = quar; whFin = fin;
  }

  final users = await c.execute('SELECT id, role FROM fh.users WHERE is_active ORDER BY id');
  final warehouses = await c.execute(
      'SELECT id, type, is_default FROM fh.warehouses WHERE is_active ORDER BY id');
  final defs = <String, int>{};
  final firsts = <String, int>{};
  for (final r in warehouses) {
    final id = (r[0] as num).toInt();
    final type = r[1] as String;
    final isDefault = r[2] as bool;
    firsts.putIfAbsent(type, () => id);
    if (isDefault) defs[type] = id;
  }
  int whFor(String type) => (defs[type] ?? firsts[type])!;

  for (final r in users) {
    final id = (r[0] as num).toInt();
    final role = r[1] as String;
    if (role == 'admin') adminId = id;
    if (role == 'operations_manager') opsId = id;
  }
  useDefs(whFor('production'), whFor('semi_finished'), whFor('packaging'),
      whFor('raw'), whFor('defective'), whFor('quarantine'), whFor('finished'));
  final whSales = whFor('sales');

  final adminTok = token(userId: adminId, role: 'admin');
  final opsTok = token(userId: opsId, role: 'operations_manager');

  int? keeperId;
  // Xohish: xodim (keeper) va modul/ombor grantlari uchun temp user
  var keeperToken = '';
  var opsGrantedByTest = false;

  // ── TOZALASH ───────────────────────────────────────────────────────────
  Future<void> cleanup() async {
    await c.execute('''
      DELETE FROM fh.inspections WHERE item_id IN
        (SELECT id FROM fh.items WHERE name LIKE \$1)
    ''', parameters: [P]);
    // FK tsikli: batches.transfer_id -> transfers, transfers.production_batch_id -> batches.
    await c.execute('UPDATE fh.production_batches SET transfer_id = NULL WHERE product_barcode LIKE \$1',
        parameters: [P]);
    await c.execute('''
      DELETE FROM fh.stock_transfers WHERE item_id IN
        (SELECT id FROM fh.items WHERE name LIKE \$1)
    ''', parameters: [P]);
    await c.execute('DELETE FROM fh.production_batches WHERE product_barcode LIKE \$1', parameters: [P]);
    await c.execute('DELETE FROM fh.bom_items WHERE bom_id IN (SELECT id FROM fh.boms WHERE name LIKE \$1)',
        parameters: [P]);
    await c.execute('DELETE FROM fh.boms WHERE name LIKE \$1', parameters: [P]);
    await c.execute('DELETE FROM fh.stock_ledger WHERE name_snapshot LIKE \$1', parameters: [P]);
    await c.execute('DELETE FROM fh.items WHERE name LIKE \$1', parameters: [P]);
    if (keeperId != null) {
      await c.execute('DELETE FROM fh.user_modules WHERE user_id = \$1', parameters: [keeperId]);
      await c.execute('DELETE FROM fh.user_warehouses WHERE user_id = \$1', parameters: [keeperId]);
      await c.execute('DELETE FROM fh.users WHERE id = \$1', parameters: [keeperId]);
    }
    if (opsGrantedByTest) {
      await c.execute(
          "DELETE FROM fh.user_modules WHERE user_id = \$1 AND module_key = 'production'",
          parameters: [opsId]);
    }
  }

  await cleanup();

  // ── TEST DATA ──────────────────────────────────────────────────────────
  final rawItem = await c.execute(
      "INSERT INTO fh.items (name, item_type, code, unit) VALUES ('E2E Xom ashyo','raw','e2e-raw','kg') RETURNING id");
  final semiItem = await c.execute(
      "INSERT INTO fh.items (name, item_type, code, unit) VALUES ('E2E Yarim tayyor','semi_finished','e2e-semi','paket') RETURNING id");
  final pkgItem = await c.execute(
      "INSERT INTO fh.items (name, item_type, code, unit) VALUES ('E2E Qop','packaging','e2e-pkg','dona') RETURNING id");
  final finItem = await c.execute(
      "INSERT INTO fh.items (name, item_type, code, unit) VALUES ('E2E Tayyor','finished','e2e-fin','dona') RETURNING id");
  final iRaw = (rawItem.first[0] as num).toInt();
  final iSemi = (semiItem.first[0] as num).toInt();
  final iPkg = (pkgItem.first[0] as num).toInt();
  final iFin = (finItem.first[0] as num).toInt();

  final bomMx = await c.execute(
      "INSERT INTO fh.boms (name, stage, output_item_id, output_qty_per_batch, output_unit) "
      "VALUES ('E2E Mixing', 'mixing', \$1, 5, 'paket') RETURNING id", parameters: [iSemi]);
  final bomPk = await c.execute(
      "INSERT INTO fh.boms (name, stage, output_item_id, output_qty_per_batch, output_unit) "
      "VALUES ('E2E Qadoqlash', 'packaging', \$1, 5, 'dona') RETURNING id", parameters: [iFin]);
  final idBomMx = (bomMx.first[0] as num).toInt();
  final idBomPk = (bomPk.first[0] as num).toInt();

  await c.execute(
      "INSERT INTO fh.bom_items (bom_id, item_type, ref_id, name_snapshot, unit, qty) "
      "VALUES (\$1, 'raw', \$2, 'E2E Xom ashyo', 'kg', 2)", parameters: [idBomMx, iRaw]);
  await c.execute(
      "INSERT INTO fh.bom_items (bom_id, item_type, ref_id, name_snapshot, unit, qty) "
      "VALUES (\$1, 'semi_finished', \$2, 'E2E Yarim tayyor', 'paket', 1)", parameters: [idBomPk, iSemi]);
  await c.execute(
      "INSERT INTO fh.bom_items (bom_id, item_type, ref_id, name_snapshot, unit, qty) "
      "VALUES (\$1, 'packaging', \$2, 'E2E Qop', 'dona', 1)", parameters: [idBomPk, iPkg]);

  // Boshlang'ich qoldiqlar
  Future<void> seed(int wh, int itemId, String type, double qty) async {
    await c.execute(
      '''
      INSERT INTO fh.stock_ledger (warehouse_id, item_type, ref_id, name_snapshot, unit,
                                   direction, qty, source_type, performed_by, note)
      VALUES (\$1, \$2, \$3, \$4, \$5, 'in', \$6, 'manual', \$7, 'E2E seed')
      ''',
      parameters: [wh, type, itemId,
          'E2E ${type == 'raw' ? 'Xom ashyo' : type == 'packaging' ? 'Qop' : 'Yarim tayyor'}',
          type == 'raw' ? 'kg' : 'paket', qty, adminId]);
  }

  await seed(whProd, iRaw, 'raw', 100);
  await seed(whPkg, iPkg, 'packaging', 50);
  await seed(whSemi, iSemi, 'semi_finished', 50);

  // ── 1. MIXING PREVIEW ──────────────────────────────────────────────────
  var (s, j) = await call('GET',
      '/production/mixing/preview?bom_id=$idBomMx&output_quantity=10', tokenStr: adminTok);
  check('mixing preview ok 200', s == 200, 'status=$s $j');
  check('mixing preview result ok', j['result'] == 'ok' && j['stage'] == 'mixing', '$j');
  check('mixing preview src prod', j['sourceWarehouse']['id'] == whProd, '$j');
  check('mixing preview dst semi', j['destWarehouse']['id'] == whSemi, '$j');
  check('mixing preview scale 2', (j['scale'] as num) == 2, '$j');
  final req0 = j['required'] as List;
  check('mixing preview required 1', req0.length == 1, '$j');
  if (req0.isNotEmpty) {
    check('mixing preview need 4', (req0.first['needed'] as num) == 4, '$j');
    check('mixing preview avail 100', (req0.first['available'] as num) == 100, '$j');
  }

  (s, j) = await call('GET',
      '/production/mixing/preview?bom_id=$idBomMx&output_quantity=100000', tokenStr: adminTok);
  check('mixing preview shortage 200', s == 200, 'status=$s');
  check('mixing preview shortage flag', j['result'] == 'shortage', '$j');
  check('mixing preview shortages nonempty', (j['shortages'] as List).isNotEmpty, '$j');

  // ── 2. MIXING START + CONFIRM ─────────────────────────────────────────
  (s, j) = await call('POST', '/production/mixing/start',
      body: {'bom_id': idBomMx, 'output_quantity': 10}, tokenStr: adminTok);
  check('mixing start 201', s == 201, 'status=$s $j');
  check('mixing start pending', j['pending'] == true, '$j');
  final t1 = (j['transferId'] as num?)?.toInt();
  final b1 = (j['batchId'] as num?)?.toInt();
  check('mixing start has ids', t1 != null && b1 != null, '$j');

  var rawBal = await balance(c, whProd, 'raw', iRaw);
  var semiBal = await balance(c, whSemi, 'semi_finished', iSemi);
  check('mixing consume raw 100->96', rawBal == 96, 'raw=$rawBal');
  check('semi unchanged before confirm', semiBal == 50, 'semi=$semiBal');

  (s, j) = await call('GET', '/transfers/pending?warehouse_id=$whSemi', tokenStr: adminTok);
  check('pending list 200', s == 200, 'status=$s');
  var pend = (j['transfers'] as List);
  final t1Row = pend.where((e) => (e as Map)['id'] == t1).toList();
  check('pending has t1', t1Row.isNotEmpty, '$pend');
  if (t1Row.isNotEmpty) {
    final m = t1Row.first as Map;
    check('t1 source is production wh', (m['sourceWarehouseId'] as num?)?.toInt() == whProd, '$m');
    check('t1 qty 10', (m['quantity'] as String) == '10' || double.parse(m['quantity'] as String) == 10, '$m');
    check('t1 dest whSemi', m['destWarehouseId'] == whSemi, '$m');
  }
  final trSrc1 = await c.execute(
      'SELECT source_warehouse_id FROM fh.stock_transfers WHERE id = \$1', parameters: [t1]);
  check('mixing transfer source=production (filled)', trSrc1.isNotEmpty && (trSrc1.first[0] as num).toInt() == whProd, '$trSrc1');

  (s, j) = await call('POST', '/transfers/$t1/confirm', tokenStr: adminTok);
  check('confirm t1 200', s == 200, 'status=$s $j');
  semiBal = await balance(c, whSemi, 'semi_finished', iSemi);
  check('confirm adds semi 50->60', semiBal == 60, 'semi=$semiBal');
  final batch1stat = await c.execute(
      'SELECT status FROM fh.production_batches WHERE id = \$1', parameters: [b1]);
  check('batch1 completed', batch1stat.isNotEmpty && batch1stat.first[0] == 'completed', '$batch1stat');

  (s, _) = await call('POST', '/transfers/$t1/confirm', tokenStr: adminTok);
  check('double confirm 409', s == 409, 'status=$s');

  // ── 3. REJECT (source=null -> defective) ───────────────────────────────
  (s, j) = await call('POST', '/production/mixing/start',
      body: {'bom_id': idBomMx, 'output_quantity': 10}, tokenStr: adminTok);
  final t2 = (j['transferId'] as num?)?.toInt();
  final b2 = (j['batchId'] as num?)?.toInt();
  rawBal = await balance(c, whProd, 'raw', iRaw);
  check('mixing2 raw 96->92', rawBal == 92, 'raw=$rawBal');

  (s, _) = await call('POST', '/transfers/$t2/reject',
      body: {'reason': '   '}, tokenStr: adminTok);
  check('reject empty reason 400', s == 400, 'status=$s');

  (s, _) = await call('POST', '/transfers/$t2/reject',
      body: {'reason': 'Test sifatsiz'}, tokenStr: adminTok);
  check('reject t2 200', s == 200, 'status=$s');
  final defSemi = await balance(c, whDef, 'semi_finished', iSemi);
  check('reject to defective +10', defSemi == 10, 'defective=$defSemi');
  final batch2stat = await c.execute(
      'SELECT status FROM fh.production_batches WHERE id = \$1', parameters: [b2]);
  check('batch2 cancelled', batch2stat.isNotEmpty && batch2stat.first[0] == 'cancelled', '$batch2stat');
  (s, _) = await call('POST', '/transfers/$t2/reject',
      body: {'reason': 'yana'}, tokenStr: adminTok);
  check('reject t2 again 409', s == 409, 'status=$s');

  // ── 4. PACKAGING ────────────────────────────────────────────────────────
  (s, j) = await call('GET',
      '/production/packaging/preview?bom_id=$idBomPk&output_quantity=10', tokenStr: adminTok);
  check('packaging preview ok 200', s == 200, 'status=$s $j');
  check('packaging preview result ok', j['result'] == 'ok' && j['stage'] == 'packaging', '$j');
  check('packaging semi source', j['sourceSemi']['id'] == whSemi, '$j');
  check('packaging pkg source', j['sourcePackaging']['id'] == whPkg, '$j');
  check('packaging finished list', (j['finishedWarehouses'] as List).any((e) => (e as Map)['id'] == whFin), '$j');
  final reqP = j['required'] as List;
  check('packaging required 2 (semi+pkg)', reqP.length == 2, '$j');
  if (reqP.length == 2) {
    check('packaging semi group', reqP.any((e) => (e['group'] as String) == 'semi_finished' && (e['needed'] as num) == 2), '$j');
    check('packaging pkg group', reqP.any((e) => (e['group'] as String) == 'packaging' && (e['needed'] as num) == 2), '$j');
  }

  (s, j) = await call('GET',
      '/production/packaging/preview?bom_id=$idBomPk&output_quantity=1000', tokenStr: adminTok);
  check('packaging shortage', j['result'] == 'shortage', '$j');

  (s, j) = await call('POST', '/production/packaging/start',
      body: {'bom_id': idBomPk, 'output_quantity': 10, 'dest_warehouse_id': whFin},
      tokenStr: adminTok);
  check('packaging start 201', s == 201, 'status=$s $j');
  final t3 = (j['transferId'] as num?)?.toInt();
  check('packaging start dest fin', j['destWarehouseName'] != null, '$j');

  semiBal = await balance(c, whSemi, 'semi_finished', iSemi);
  final pkgBal = await balance(c, whPkg, 'packaging', iPkg);
  final finBal1 = await balance(c, whFin, 'finished', iFin);
  check('packaging consume semi 60->58', semiBal == 58, 'semi=$semiBal');
  check('packaging consume pkg 50->48', pkgBal == 48, 'pkg=$pkgBal');
  check('fin added immediately 0->10', finBal1 == 10, 'fin=$finBal1');

  final trSrc3 = await c.execute(
      'SELECT source_warehouse_id, status FROM fh.stock_transfers WHERE id = \$1', parameters: [t3]);
  check('packaging transfer source=semi (filled)', trSrc3.isNotEmpty && (trSrc3.first[0] as num).toInt() == whSemi, '$trSrc3');
  check('packaging transfer auto-confirmed', trSrc3.isNotEmpty && trSrc3.first[1] == 'confirmed', '$trSrc3');

  final batchPack = await c.execute(
      'SELECT status FROM fh.production_batches WHERE transfer_id = \$1', parameters: [t3]);
  check('packaging batch completed', batchPack.isNotEmpty && batchPack.first[0] == 'completed', '$batchPack');

  // ── 5. REJECT with source -> reverse ────────────────────────────────────
  final trS = await c.execute(
      "INSERT INTO fh.stock_transfers (item_id, quantity, unit, source_warehouse_id, dest_warehouse_id, status, created_by) "
      "VALUES (\$1, 5, 'paket', \$2, \$3, 'pending', \$4) RETURNING id",
      parameters: [iSemi, whSemi, whQuar, adminId]);
  final tS = (trS.first[0] as num).toInt();
  // Eski qoidalar bilan yuborilgan o'tkazmalar send paytida manba chiqimini
  // yozgan edi — rad etilganda manbaga qaytishini simulyatsiya qilamiz.
  await c.execute(
      "INSERT INTO fh.stock_ledger (warehouse_id, item_type, ref_id, name_snapshot, unit, "
      "direction, qty, source_type, source_ref, performed_by, note) "
      "VALUES (\$1, 'semi_finished', \$2, 'E2E Yarim tayyor', 'paket', 'out', 5, 'transfer_out', \$3::text, \$4, 'Transfer #\$3')",
      parameters: [whSemi, iSemi, tS, adminId]);
  semiBal = await balance(c, whSemi, 'semi_finished', iSemi);
  check('semi before reverse 53', semiBal == 53, 'semi=$semiBal');
  (s, _) = await call('POST', '/transfers/$tS/reject',
      body: {'reason': 'Qaytarildi'}, tokenStr: adminTok);
  check('reverse reject 200', s == 200, 'status=$s');
  semiBal = await balance(c, whSemi, 'semi_finished', iSemi);
  check('ledger chiqim +5 qaytadi 53->58', semiBal == 58, 'semi=$semiBal');

  // ── 6. INSPECTIONS ──────────────────────────────────────────────────────
  (s, j) = await call('POST', '/inspections/receive',
      body: {'item_id': iRaw, 'quantity': 5, 'unit': 'kg', 'quarantine_warehouse_id': whQuar},
      tokenStr: adminTok);
  check('inspection receive 201', s == 201, 'status=$s $j');
  final insp1 = (j['inspectionId'] as num?)?.toInt();
  var quarBal = await balance(c, whQuar, 'raw', iRaw);
  check('quarantine raw +5', quarBal == 5, 'q=$quarBal');

  (s, _) = await call('POST', '/inspections/receive',
      body: {'item_id': iRaw, 'quantity': 2, 'quarantine_warehouse_id': whRaw},
      tokenStr: adminTok);
  check('receive non-quarantine 400', s == 400, 'status=$s');

  (s, j) = await call('GET', '/inspections/pending?warehouse_id=$whQuar', tokenStr: adminTok);
  check('inspections pending 200', s == 200, 'status=$s');
  var insps = (j['inspections'] as List);
  check('pending has insp1', insps.any((e) => (e as Map)['id'] == insp1 && e['itemName'] == 'E2E Xom ashyo'), '$insps');

  (s, j) = await call('POST', '/inspections/$insp1/decide',
      body: {'result': 'approved', 'note': 'Sifat ok'}, tokenStr: adminTok);
  check('decide approved 200', s == 200, 'status=$s $j');
  quarBal = await balance(c, whQuar, 'raw', iRaw);
  final rawBal23 = await balance(c, whRaw, 'raw', iRaw);
  check('quarantine out ->0', quarBal == 0, 'q=$quarBal');
  check('raw wh +5', rawBal23 == 5, 'raw=$rawBal23');
  check('decide dest whRaw', j['destWarehouseId'] == whRaw, '$j');

  (s, j) = await call('POST', '/inspections/receive',
      body: {'item_id': iRaw, 'quantity': 3, 'quarantine_warehouse_id': whQuar},
      tokenStr: adminTok);
  final insp2 = (j['inspectionId'] as num?)?.toInt();
  (s, _) = await call('POST', '/inspections/$insp2/decide',
      body: {'result': 'rejected', 'note': 'Brak'}, tokenStr: adminTok);
  check('decide rejected 200', s == 200, 'status=$s');
  final defRaw = await balance(c, whDef, 'raw', iRaw);
  check('defective raw +3', defRaw == 3, 'defRaw=$defRaw');

  (s, _) = await call('POST', '/inspections/$insp2/decide',
      body: {'result': 'approved'}, tokenStr: adminTok);
  check('decide again 409', s == 409, 'status=$s');

  // ── 7. PERMISSION-LAR (keeper) ──────────────────────────────────────────
  // Qoldiq tozalash (avval uzilgan runlardan)
  await c.execute("DELETE FROM fh.users WHERE email = 'e2e_keeper@test.uz'");
  keeperId = (await c.execute(
      "INSERT INTO fh.users (username, email, password, role, is_active) "
      "VALUES ('e2e_keeper', 'e2e_keeper@test.uz', 'x', 'warehouse_keeper', true) RETURNING id"
  )).first[0] as int;
  keeperToken = token(userId: keeperId, role: 'warehouse_keeper');

  (s, _) = await call('GET',
      '/production/mixing/preview?bom_id=$idBomMx&output_quantity=10', tokenStr: keeperToken);
  check('keeper preview 403 (no module)', s == 403, 'status=$s');
  (s, _) = await call('POST', '/inspections/receive',
      body: {'item_id': iRaw, 'quantity': 2, 'quarantine_warehouse_id': whQuar},
      tokenStr: keeperToken);
  check('keeper receive 403 (no module)', s == 403, 'status=$s');

  // OMBOR granti BOR, modul YO'Q bo'lsa ham qabul tasdiqlash ko'rinadi
  // (modul talab olib tashlangan — nazorat berilgan har kimga ochiq).
  await c.execute(
      'INSERT INTO fh.user_warehouses (user_id, warehouse_id) VALUES (\$1, \$2),(\$1, \$3)',
      parameters: [keeperId, whSemi, whQuar]);

  (s, _) = await call('GET', '/transfers/pending?warehouse_id=$whSemi', tokenStr: keeperToken);
  check('keeper pending 200 (ombor granti, modulsiz)', s == 200, 'status=$s');

  await c.execute(
      "INSERT INTO fh.user_modules (user_id, module_key) VALUES (\$1, 'production'),(\$1, 'inspection')",
      parameters: [keeperId]);

  (s, _) = await call('GET',
      '/production/mixing/preview?bom_id=$idBomMx&output_quantity=10', tokenStr: keeperToken);
  check('keeper preview 200 (module+grant)', s == 200, 'status=$s');
  (s, _) = await call('POST', '/production/mixing/start',
      body: {'bom_id': idBomMx, 'output_quantity': 10}, tokenStr: keeperToken);
  check('keeper mixing start 403 (canPlan false)', s == 403, 'status=$s');
  (s, _) = await call('GET', '/transfers/pending?warehouse_id=$whFin', tokenStr: keeperToken);
  check('keeper pending whFin 403 (not granted)', s == 403, 'status=$s');

  (s, j) = await call('POST', '/production/mixing/start',
      body: {'bom_id': idBomMx, 'output_quantity': 10}, tokenStr: adminTok);
  final t4 = (j['transferId'] as num?)?.toInt();
  (s, j) = await call('GET', '/transfers/pending?warehouse_id=$whSemi', tokenStr: keeperToken);
  check('keeper pending whSemi 200', s == 200, 'status=$s');
  pend = (j['transfers'] as List);
  check('keeper pending has t4', pend.any((e) => (e as Map)['id'] == t4), '$pend');
  (s, _) = await call('POST', '/transfers/$t4/confirm', tokenStr: keeperToken);
  check('keeper confirm t4 200', s == 200, 'status=$s');
  semiBal = await balance(c, whSemi, 'semi_finished', iSemi);
  check('keeper confirm added semi 58->68', semiBal == 68, 'semi=$semiBal');
  (s, _) = await call('POST', '/transfers/$t4/confirm', tokenStr: keeperToken);
  check('keeper confirm again 409', s == 409, 'status=$s');

  (s, j) = await call('POST', '/inspections/receive',
      body: {'item_id': iRaw, 'quantity': 2, 'quarantine_warehouse_id': whQuar},
      tokenStr: keeperToken);
  check('keeper receive 201 (quar grant)', s == 201, 'status=$s $j');
  final insp3 = (j['inspectionId'] as num?)?.toInt();
  (s, _) = await call('POST', '/inspections/$insp3/decide',
      body: {'result': 'rejected'}, tokenStr: keeperToken);
  check('keeper decide rejected 200', s == 200, 'status=$s');
  final defRaw2 = await balance(c, whDef, 'raw', iRaw);
  check('defective raw 3->5', defRaw2 == 5, 'defRaw=$defRaw2');

  // ── 8. OPS canPlan ──────────────────────────────────────────────────────
  final opsGranted = await c.execute(
      "SELECT 1 FROM fh.user_modules WHERE user_id = \$1 AND module_key = 'production'",
      parameters: [opsId]);
  if (opsGranted.isEmpty) {
    await c.execute(
        "INSERT INTO fh.user_modules (user_id, module_key) VALUES (\$1, 'production')",
        parameters: [opsId]);
    opsGrantedByTest = true;
  }
  (s, j) = await call('POST', '/production/mixing/start',
      body: {'bom_id': idBomMx, 'output_quantity': 10}, tokenStr: opsTok);
  check('ops mixing start 201 (canPlan)', s == 201, 'status=$s $j');
  final t5 = (j['transferId'] as num?)?.toInt();
  (s, _) = await call('POST', '/transfers/$t5/confirm', tokenStr: adminTok);
  check('confirm ops-batch 200', s == 200, 'status=$s');

  // ── 9. QO'LDA YUBORISH (POST /transfers/send) + zanjir yo'llari ─────
  // 1-bo'g'in: Xom-ashyo ombori -> Ishlab chiqarish ombori
  await c.execute(
    '''
    INSERT INTO fh.stock_ledger (warehouse_id, item_type, ref_id, name_snapshot, unit,
                                 direction, qty, source_type, performed_by, note)
    VALUES (\$1, 'raw', \$2, 'E2E Xom ashyo', 'kg', 'in', 40, 'manual', \$3, 'E2E seed')
    ''',
    parameters: [whRaw, iRaw, adminId],
  );
  var rawBalRaw = await balance(c, whRaw, 'raw', iRaw);
  check('manual seed raw 45', rawBalRaw == 45, 'raw=$rawBalRaw');

  (s, j) = await call('POST', '/transfers/send',
      body: {
        'item_id': iRaw, 'quantity': 10, 'unit': 'kg',
        'source_warehouse_id': whRaw, 'dest_warehouse_id': whProd,
      },
      tokenStr: adminTok);
  check('manual send 201', s == 201, 'status=$s $j');
  final tS1 = (j['transferId'] as num?)?.toInt();
  check('manual send pending flag', j['pending'] == true, '$j');
  final srcRow = await c.execute(
      'SELECT source_warehouse_id FROM fh.stock_transfers WHERE id = \$1', parameters: [tS1]);
  check('manual source filled', srcRow.isNotEmpty && (srcRow.first[0] as num).toInt() == whRaw, '$srcRow');

  rawBalRaw = await balance(c, whRaw, 'raw', iRaw);
  check('raw senddan keyin o\'zgarmaydi 45 (confirm kutiladi)', rawBalRaw == 45, 'raw=$rawBalRaw');
  var prodBal = await balance(c, whProd, 'raw', iRaw);
  check('prod o\'zgarishsiz 84 (confirm kutiladi)', prodBal == 84, 'prod=$prodBal');

  (s, j) = await call('GET', '/transfers/pending?warehouse_id=$whProd', tokenStr: adminTok);
  pend = (j['transfers'] as List);
  final s1row = pend.where((e) => (e as Map)['id'] == tS1).toList();
  check('pending has manual tS1', s1row.isNotEmpty, '$pend');
  if (s1row.isNotEmpty) {
    final m = s1row.first as Map;
    check('manual source raw', m['sourceWarehouseId'] == whRaw, '$m');
    check('manual dest prod', m['destWarehouseId'] == whProd, '$m');
  }

  (s, _) = await call('POST', '/transfers/$tS1/confirm', tokenStr: adminTok);
  check('manual confirm 200', s == 200, 'status=$s');
  prodBal = await balance(c, whProd, 'raw', iRaw);
  check('prod raw +10 confirm 84->94', prodBal == 94, 'prod=$prodBal');
  rawBalRaw = await balance(c, whRaw, 'raw', iRaw);
  check('raw confirmda kamayadi 45->35', rawBalRaw == 35, 'raw=$rawBalRaw');

  // Ruxsat etilmagan yo'nalish (Xom-ashyo -> Sotuv)
  (s, j) = await call('POST', '/transfers/send',
      body: {
        'item_id': iRaw, 'quantity': 1,
        'source_warehouse_id': whRaw, 'dest_warehouse_id': whSales,
      },
      tokenStr: adminTok);
  check('raw->sales route 403', s == 403, 'status=$s $j');

  // Rad etish -> manbaga qaytadi
  (s, j) = await call('POST', '/transfers/send',
      body: {
        'item_id': iRaw, 'quantity': 5, 'unit': 'kg',
        'source_warehouse_id': whRaw, 'dest_warehouse_id': whProd,
      },
      tokenStr: adminTok);
  final tS2 = (j['transferId'] as num?)?.toInt();
  rawBalRaw = await balance(c, whRaw, 'raw', iRaw);
  check('raw send2 o\'zgarmaydi 35', rawBalRaw == 35, 'raw=$rawBalRaw');
  (s, _) = await call('POST', '/transfers/$tS2/reject',
      body: {'reason': 'Farqi bor'}, tokenStr: adminTok);
  check('manual reject 200', s == 200, 'status=$s');
  rawBalRaw = await balance(c, whRaw, 'raw', iRaw);
  check('raw rejectdan keyin ham 35', rawBalRaw == 35, 'raw=$rawBalRaw');

  // Etarli emas
  (s, j) = await call('POST', '/transfers/send',
      body: {
        'item_id': iRaw, 'quantity': 9999,
        'source_warehouse_id': whRaw, 'dest_warehouse_id': whProd,
      },
      tokenStr: adminTok);
  check('manual shortage 422', s == 422, 'status=$s $j');

  // Yetishmayotgan field
  (s, _) = await call('POST', '/transfers/send',
      body: {'item_id': iRaw, 'quantity': 1, 'source_warehouse_id': whRaw},
      tokenStr: adminTok);
  check('manual missing dest 400', s == 400, 'status=$s');

  // Keeper: ruxsat berilmagan manbadan yuborish -> 403
  (s, _) = await call('POST', '/transfers/send',
      body: {
        'item_id': iRaw, 'quantity': 1,
        'source_warehouse_id': whRaw, 'dest_warehouse_id': whProd,
      },
      tokenStr: keeperToken);
  check('keeper send un-granted src 403', s == 403, 'status=$s');

  // Keeper: grant berilgan ombordan (semi) yuborish -> 201, admin confirm qiladi.
  (s, j) = await call('POST', '/transfers/send',
      body: {
        'item_id': iSemi, 'quantity': 5, 'unit': 'paket',
        'source_warehouse_id': whSemi, 'dest_warehouse_id': whFin,
      },
      tokenStr: keeperToken);
  check('keeper send granted src 201', s == 201, 'status=$s $j');
  final tS3 = (j['transferId'] as num?)?.toInt();
  semiBal = await balance(c, whSemi, 'semi_finished', iSemi);
  check('keeper send semi o\'zgarmaydi 78', semiBal == 78, 'semi=$semiBal');
  (s, _) = await call('POST', '/transfers/$tS3/confirm', tokenStr: adminTok);
  check('confirm keeper-sent 200', s == 200, 'status=$s');
  final semiAtFin = await balance(c, whFin, 'semi_finished', iSemi);
  check('semi +5 to whFin on confirm (keeper sent)', semiAtFin == 5, 'semiAtFin=$semiAtFin');
  semiBal = await balance(c, whSemi, 'semi_finished', iSemi);
  check('semi confirmda 78->73', semiBal == 73, 'semi=$semiBal');

  // ── 10. QAT'IY TRANSFER YO'NALISh (fixed route) ────────────────────────
  // whSemi sozlamalari (PUT uchun mavjud qiymatlar)
  (s, j) = await call('GET', '/warehouses/$whSemi', tokenStr: adminTok);
  check('fixed: wh detail 200', s == 200, 'status=$s $j');
  final whDetailPre = j['warehouse'] as Map;
  final curAnalyze = whDetailPre['canAnalyze'] == true;
  final curIncome = whDetailPre['canIncome'] == true;
  final curExpense = whDetailPre['canExpense'] == true;

  // whSemi -> whFin qat'iy tayinlanadi
  (s, j) = await call('PUT', '/warehouses/$whSemi', body: {
    'canAnalyze': curAnalyze, 'canTransfer': true, 'canIncome': curIncome,
    'canExpense': curExpense, 'transferTo': [whFin], 'fixedTransferTo': whFin,
  }, tokenStr: adminTok);
  check('fixed: set route PUT 200', s == 200, 'status=$s $j');
  check('fixed: PUT echoed fixedTransferTo', (j['warehouse'] as Map)['fixedTransferTo'] == whFin, '$j');

  (s, j) = await call('GET', '/warehouses/$whSemi', tokenStr: adminTok);
  final dFixed = j['warehouse'] as Map;
  check('fixed: detail fixedTransferTo', dFixed['fixedTransferTo'] == whFin, '$j');
  check('fixed: detail fixed name', (dFixed['fixedTransferToWarehouse'] as String?)?.isNotEmpty ?? false, '$j');
  check('fixed: detail routes faqat fin', (dFixed['transferToWarehouses'] as List).length == 1
      && (dFixed['transferToWarehouses'] as List).first['id'] == whFin, '$j');

  (s, j) = await call('GET', '/warehouses', tokenStr: adminTok);
  final whRow = (j['warehouses'] as List).where((e) => (e as Map)['id'] == whSemi).toList();
  check('fixed: warehouses list fixedTransferTo', whRow.isNotEmpty
      && (whRow.first as Map)['fixedTransferTo'] == whFin, '$j');

  // /transfers/send: qat'iy belgidan boshqa manzilga 403
  (s, j) = await call('POST', '/transfers/send', body: {
    'item_id': iSemi, 'quantity': 1, 'unit': 'paket',
    'source_warehouse_id': whSemi, 'dest_warehouse_id': whQuar,
  }, tokenStr: adminTok);
  check('fixed: send not-fixed dest 403', s == 403, 'status=$s $j');
  // Qat'iy manzilga 201 + confirm
  (s, j) = await call('POST', '/transfers/send', body: {
    'item_id': iSemi, 'quantity': 1, 'unit': 'paket',
    'source_warehouse_id': whSemi, 'dest_warehouse_id': whFin,
  }, tokenStr: adminTok);
  check('fixed: send fixed dest 201', s == 201, 'status=$s $j');
  final tFixed = (j['transferId'] as num?)?.toInt();
  (s, _) = await call('POST', '/transfers/$tFixed/confirm', tokenStr: adminTok);
  check('fixed: send confirm 200', s == 200, 'status=$s');

  // Legacy POST /transfers ham qat'iy yo'nalishga bo'ysunadi
  (s, j) = await call('POST', '/transfers', body: {
    'from_warehouse_id': whSemi, 'to_warehouse_id': whQuar,
    'items': [{'item_type': 'semi_finished', 'ref_id': iSemi,
               'name': 'E2E Yarim tayyor', 'unit': 'paket', 'qty': 1}],
  }, tokenStr: adminTok);
  check('fixed: legacy wrong dest 403', s == 403, 'status=$s $j');

  // Packaging preview — finishedWarehouses qat'iy/routes bo'yicha cheklanadi
  (s, j) = await call('GET', '/production/packaging/preview?bom_id=$idBomPk&output_quantity=10',
      tokenStr: adminTok);
  var finListP = (j['finishedWarehouses'] as List);
  check('fixed: packaging preview faqat qat\'iy fin', finListP.length == 1
      && (finListP.first as Map)['id'] == whFin, '$j');

  // Qat'iy olib tashlanadi; routes'da faqat whFin qoladi -> preview hali ham [fin]
  (s, j) = await call('PUT', '/warehouses/$whSemi', body: {
    'canAnalyze': curAnalyze, 'canTransfer': true, 'canIncome': curIncome,
    'canExpense': curExpense, 'transferTo': [whFin], 'fixedTransferTo': null,
  }, tokenStr: adminTok);
  check('fixed: clear fixed PUT 200', s == 200, 'status=$s $j');
  (s, j) = await call('GET', '/production/packaging/preview?bom_id=$idBomPk&output_quantity=10',
      tokenStr: adminTok);
  finListP = (j['finishedWarehouses'] as List);
  check('fixed: preview routes-only [fin]', finListP.length == 1
      && (finListP.first as Map)['id'] == whFin, '$j');

  // Tayinlangan manzilga packaging start ishlaydi
  (s, j) = await call('POST', '/production/packaging/start', body: {
    'bom_id': idBomPk, 'output_quantity': 10, 'dest_warehouse_id': whFin,
  }, tokenStr: adminTok);
  check('fixed: packaging start designated dest 201', s == 201, 'status=$s $j');

  // Tayinlanmagan (yangicha yaratilgan) finished omboriga start -> 403
  (s, j) = await call('POST', '/warehouses', body: {
    'name': 'E2E % Vaqtinchalik Fin', 'type': 'finished',
    'canAnalyze': true, 'canTransfer': false, 'canIncome': true, 'canExpense': true,
    'transferTo': <int>[],
  }, tokenStr: adminTok);
  check('fixed: temp fin wh created 201', s == 201, 'status=$s $j');
  final tempFin = (j['warehouse']['id'] as num?)?.toInt();
  check('fixed: temp fin id', tempFin != null, '$j');
  if (tempFin != null) {
    (s, j) = await call('POST', '/production/packaging/start', body: {
      'bom_id': idBomPk, 'output_quantity': 10, 'dest_warehouse_id': tempFin,
    }, tokenStr: adminTok);
    check('fixed: packaging start not-designated 403', s == 403, 'status=$s $j');
    (s, _) = await call('DELETE', '/warehouses/$tempFin', tokenStr: adminTok);
    check('fixed: temp fin deleted', s == 200, 'status=$s');
  }

  // transferTo tarkibida bo'lmagan ombor qat'iy tanlansa — bekor qilinadi
  (s, j) = await call('PUT', '/warehouses/$whSemi', body: {
    'canAnalyze': curAnalyze, 'canTransfer': true, 'canIncome': curIncome,
    'canExpense': curExpense, 'transferTo': [whFin], 'fixedTransferTo': whSales,
  }, tokenStr: adminTok);
  check('fixed: invalid fixed dropped', (j['warehouse'] as Map)['fixedTransferTo'] == null, '$j');
  (s, j) = await call('GET', '/warehouses/$whSemi', tokenStr: adminTok);
  check('fixed: invalid fixed cleared in detail', (j['warehouse'] as Map)['fixedTransferTo'] == null, '$j');

  // ── 11. DEALERS (Sotuv dillerlari moduli) ─────────────────────────────
  // Diller yaratilganda ombor avtomatik yaratiladi + qaytarish uchun
  // dealer->finished yo'nalishi qo'shiladi (agar finished mavjud bo'lsa).
  (s, j) = await call('GET', '/dealers', tokenStr: opsTok);
  check('dealers: ops list allowed 200', s == 200, 'status=$s $j');

  (s, j) = await call('POST', '/dealers', body: {}, tokenStr: adminTok);
  check('dealers: empty body 400', s == 400, 'status=$s $j');
  (s, j) = await call('POST', '/dealers',
      body: {'name': 'E2E Diller B', 'marketType': 'bad'}, tokenStr: adminTok);
  check('dealers: bad marketType 400', s == 400, 'status=$s $j');

  (s, j) = await call('POST', '/dealers', body: {
    'name': 'E2E Diller B', 'marketType': 'domestic',
    'phone': '+998901234567', 'contactPerson': 'Ali',
  }, tokenStr: adminTok);
  check('dealers: create 201', s == 201, 'status=$s $j');
  final d1 = j['dealer'] as Map;
  final d1Id = (d1['id'] as num?)?.toInt();
  final d1Wh = (d1['warehouseId'] as num?)?.toInt();
  check('dealers: created id + warehouseId', d1Id != null && d1Wh != null, '$j');

  // Avtomatik yaratilgan ombor tekshiruvi.
  (s, j) = await call('GET', '/warehouses/$d1Wh', tokenStr: adminTok);
  check('dealers: auto warehouse detail 200', s == 200, 'status=$s $j');
  final dWh = j['warehouse'] as Map;
  check('dealers: wh type dealer', dWh['type'] == 'dealer', '$j');
  check('dealers: wh name = dealer name', dWh['name'] == 'E2E Diller B', '$j');
  check('dealers: wh canTransfer true', dWh['canTransfer'] == true, '$j');
  final dRoutes = (dWh['transferToWarehouses'] as List);
  check('dealers: auto route -> finished',
      dRoutes.any((e) => (e as Map)['id'] == whFin), '$j');

  // Ro'yxatda segment filtr + bo'sh qoldiq.
  (s, j) = await call('GET', '/dealers?market_type=domestic', tokenStr: adminTok);
  var dlrDom = (j['dealers'] as List).where((e) => (e as Map)['id'] == d1Id).toList();
  check('dealers: domestic list contains', dlrDom.isNotEmpty, '$j');
  check('dealers: empty balance itemCount',
      dlrDom.isNotEmpty && (dlrDom.first as Map)['itemCount'] == 0, '$j');
  (s, j) = await call('GET', '/dealers?market_type=export', tokenStr: adminTok);
  check('dealers: export filter excludes', s == 200
      && (j['dealers'] as List).where((e) => (e as Map)['id'] == d1Id).isEmpty, '$j');

  // Qoldiq paydo bo'lgach balans aks etadi (N+1 emas — aggregatsiya bilan).
  await c.execute(
    "INSERT INTO fh.stock_ledger (warehouse_id, item_type, ref_id, name_snapshot, unit, "
    "direction, qty, source_type, performed_by, note) "
    "VALUES (\$1, 'finished', \$2, 'E2E Tayyor', 'dona', 'in', 10, 'manual', \$3, 'E2E dealer seed')",
    parameters: [d1Wh, iFin, adminId]);
  (s, j) = await call('GET', '/dealers?market_type=domestic', tokenStr: adminTok);
  dlrDom = (j['dealers'] as List).where((e) => (e as Map)['id'] == d1Id).toList();
  check('dealers: balance itemCount 1',
      dlrDom.isNotEmpty && (dlrDom.first as Map)['itemCount'] == 1, '$j');
  check('dealers: balance totalQty 10', dlrDom.isNotEmpty
      && double.parse((dlrDom.first as Map)['totalQty'].toString()) == 10.0, '$j');

  // Detail + to'liq ombor qoldig'i.
  (s, j) = await call('GET', '/dealers/$d1Id', tokenStr: opsTok);
  check('dealers: detail 200', s == 200, 'status=$s $j');
  check('dealers: detail stock 1', (j['stock'] as List).length == 1, '$j');
  check('dealers: detail balance 10',
      double.parse((j['stock'] as List).first['balance'].toString()) == 10.0, '$j');

  // Omborda qoldiq bor — o'chirib bo'lmaydi.
  (s, j) = await call('DELETE', '/dealers/$d1Id', tokenStr: adminTok);
  check('dealers: delete non-empty 409', s == 409
      && (j['error'] as String? ?? '').contains("bo'sh emas"), 'status=$s $j');

  // Qoldiq tozalanib o'chiriladi (ombor ham o'chadi).
  await c.execute('DELETE FROM fh.stock_ledger WHERE warehouse_id = \$1', parameters: [d1Wh]);
  (s, j) = await call('DELETE', '/dealers/$d1Id', tokenStr: adminTok);
  check('dealers: delete empty 200', s == 200, 'status=$s $j');
  (s, _) = await call('GET', '/warehouses/$d1Wh', tokenStr: adminTok);
  check('dealers: warehouse removed with dealer', s == 404, 'status=$s');

  // PUT — ombor nomi diller nomi bilan sinxron yangilanadi.
  (s, j) = await call('POST', '/dealers',
      body: {'name': 'E2E Exporter', 'marketType': 'export'}, tokenStr: adminTok);
  check('dealers: export create 201', s == 201, 'status=$s $j');
  final d2 = j['dealer'] as Map;
  final d2Id = (d2['id'] as num?)?.toInt();
  final d2Wh = (d2['warehouseId'] as num?)?.toInt();
  (s, j) = await call('PUT', '/dealers/$d2Id', body: {
    'name': 'E2E Exporter 2', 'marketType': 'export',
    'phone': null, 'address': null, 'contactPerson': null, 'isActive': true,
  }, tokenStr: adminTok);
  check('dealers: put 200', s == 200, 'status=$s $j');
  (s, j) = await call('GET', '/dealers/$d2Id', tokenStr: adminTok);
  check('dealers: put name reflect', s == 200 && (j['dealer'] as Map)['name'] == 'E2E Exporter 2', '$j');
  (s, j) = await call('GET', '/warehouses/$d2Wh', tokenStr: adminTok);
  check('dealers: warehouse name synced',
      s == 200 && (j['warehouse'] as Map)['name'] == 'E2E Exporter 2', '$j');
  (s, _) = await call('DELETE', '/dealers/$d2Id', tokenStr: adminTok);
  check('dealers: export delete empty', s == 200, 'status=$s');

  // ── GPS / SELF-CHECKIN / AUDIT / UNMARKED ──────────────────────────────────

  // GPS joylashuvi: "Asosiy ofis" (41.311081, 69.240562, radius=200).
  // /hr/attendance/me — bog'lanmagan user uchun 403 (xodim talab qilinadi).
  (s, j) = await call('GET', '/hr/attendance/me', tokenStr: adminTok);
  check('gps: /hr/attendance/me no-employee 403', s == 403, 'status=$s $j');

  // Xodim yaratish va linklash (employee role bilan).
  final empUser = await c.execute(
    "INSERT INTO fh.users (username, email, password, role) "
    "VALUES ('e2e_gps_test', 'e2e_gps@test.uz', 'pass123', 'employee') "
    "RETURNING id",
  );
  final empUserId = (empUser.first[0] as num).toInt();

  // Xodim yaratish + link.
  final empRow = await c.execute(
    "INSERT INTO fh.employees (full_name, position, department, phone, pay_type, base_salary, user_id, status) "
    "VALUES ('GPS Test Xodim', 'Test', 'Test', '999999999', 'salary', 100000, \$1, 'active') "
    "RETURNING id",
    parameters: [empUserId],
  );
  final empId = (empRow.first[0] as num).toInt();
  final empTok = token(userId: empUserId, role: 'employee');

  // Xodim uchun 'hr' moduli granti.
  await c.execute(
    "INSERT INTO fh.user_modules (user_id, module_key) VALUES (\$1, 'hr') ON CONFLICT DO NOTHING",
    parameters: [empUserId],
  );

  // Self-checkin (in) — GPS radius ichida: 41.311081, 69.240562 (radius 200m).
  (s, j) = await call('POST', '/hr/attendance/self-checkin', body: {
    'type': 'in',
    'lat': 41.311081,
    'lng': 69.240562,
  }, tokenStr: empTok);
  check('self-checkin: in within radius 200', s == 200, 'status=$s $j');

  // Self-checkin (in) yana — 409 (allaqachon belgilangan).
  (s, j) = await call('POST', '/hr/attendance/self-checkin', body: {
    'type': 'in',
    'lat': 41.311081,
    'lng': 69.240562,
  }, tokenStr: empTok);
  check('self-checkin: in duplicate 409', s == 409, 'status=$s $j');

  // Self-checkin (out) — GPS radius ichida.
  (s, j) = await call('POST', '/hr/attendance/self-checkin', body: {
    'type': 'out',
    'lat': 41.311081,
    'lng': 69.240562,
  }, tokenStr: empTok);
  check('self-checkin: out within radius 200', s == 200, 'status=$s $j');

  // Self-checkin (in) — GPS radius tashqarida (~1.1km: +0.01 lat ≈ 1.1km).
  (s, j) = await call('POST', '/hr/attendance/self-checkin', body: {
    'type': 'in',
    'lat': 41.321081,  // ~1.1km shimolda
    'lng': 69.240562,
  }, tokenStr: empTok);
  check('self-checkin: in outside radius 400',
      s == 400 && (j['error'] as String? ?? '').contains("ofis hududida emas"),
      'status=$s $j');

  // Unmarked: hali davomat kiritilmagan xodimlar.
  final today = DateTime.now().toIso8601String().substring(0, 10);
  (s, j) = await call('GET', '/hr/attendance/unmarked?date=$today', tokenStr: adminTok);
  check('unmarked: 200 + has selfMarked', s == 200
      && (j['selfMarked'] as List).isNotEmpty, 'status=$s $j');

  // /hr/attendance/me — xodimning o'z holati.
  (s, j) = await call('GET', '/hr/attendance/me', tokenStr: empTok);
  check('me: 200 + attendance not null', s == 200
      && j['attendance'] != null
      && j['attendance']['markedBy'] == 'self', 'status=$s $j');

  // GET /hr/attendance — admin ko'radi; employee faqat o'zini.
  (s, j) = await call('GET', '/hr/attendance', tokenStr: adminTok);
  final adminAttCount = (j['attendance'] as List).length;
  check('admin: attendance list 200', s == 200 && adminAttCount > 0, 'status=$s $j');

  (s, j) = await call('GET', '/hr/attendance', tokenStr: empTok);
  check('employee: own attendance 200 + count=1', s == 200
      && (j['attendance'] as List).length == 1, 'status=$s $j');

  // Audit log: avval PUT bilan status o'zgartiramiz.
  final attRow = await c.execute(
    "SELECT id FROM fh.attendance WHERE employee_id = \$1 AND work_date = CURRENT_DATE LIMIT 1",
    parameters: [empId],
  );
  final testAttId = (attRow.first[0] as num).toInt();

  (s, j) = await call('PUT', '/hr/attendance/$testAttId', body: {
    'status': 'late',
  }, tokenStr: adminTok);
  check('attendance PUT audit: 200', s == 200, 'status=$s $j');
  check('attendance PUT audit: isEarlyLeave computed',
      (j['attendance'] as Map)['isEarlyLeave'] == true, '$j');

  // Audit log tekshirish.
  (s, j) = await call('GET', '/hr/attendance/$testAttId/audit', tokenStr: adminTok);
  check('audit: 200 + has entries', s == 200
      && (j['audit'] as List).isNotEmpty
      && (j['audit'] as List).first['fieldName'] == 'status', 'status=$s $j');

  // Employee o'z auditini ko'radi.
  (s, j) = await call('GET', '/hr/attendance/$testAttId/audit', tokenStr: empTok);
  check('employee: own audit 200', s == 200, 'status=$s $j');

  // Monthly report: daysEarlyLeave mavjud.
  (s, j) = await call('GET', '/hr/reports/monthly', tokenStr: adminTok);
  final monthRows = (j['rows'] as List);
  check('monthly: has rows', s == 200 && monthRows.isNotEmpty, 'status=$s $j');

  // Tozalash: test xodimlarini o'chirish.
  await c.execute('DELETE FROM fh.attendance_audit_log WHERE attendance_id IN '
      '(SELECT id FROM fh.attendance WHERE employee_id = \$1)', parameters: [empId]);
  await c.execute('DELETE FROM fh.attendance WHERE employee_id = \$1', parameters: [empId]);
  await c.execute('DELETE FROM fh.user_modules WHERE user_id = \$1', parameters: [empUserId]);
  await c.execute('DELETE FROM fh.employees WHERE id = \$1', parameters: [empId]);
  await c.execute('DELETE FROM fh.users WHERE id = \$1', parameters: [empUserId]);

  // ── FINAL ──────────────────────────────────────────────────────────────
  await cleanup();

  print('\n================ RESULT ================');
  print('PASS: $_pass  FAIL: $_fail');
  await c.close();
  if (_fail > 0) exitCode = 1;
}