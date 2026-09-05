import 'dart:convert';
import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:dotenv/dotenv.dart';
import 'package:exim_raw_backend/factoryhub/jwt.dart';

// Legacy item (fh.items da YO'Q, raw_material ref_id) bilan send→confirm→reject.
// Talab: local server 8051 da ishlayapti.

const base = 'http://127.0.0.1:8051/fh';
const SN = 'LEGACY Xom';

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
  String path, [
  Map<String, dynamic>? body,
  String? tokenStr,
]) async {
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

Future<double> ledBal(Connection c, int wh, String refText, String itemType) async {
  final res = await c.execute(
    "SELECT COALESCE(SUM(CASE direction WHEN 'in' THEN qty ELSE -qty END), 0) "
    "FROM fh.stock_ledger WHERE warehouse_id = \$1 AND item_type = \$2 "
    "AND COALESCE(ref_id::text, ref_barcode) = \$3",
    parameters: [wh, itemType, refText],
  );
  return double.parse(res.first[0].toString());
}

Future<void> main() async {
  final c = await connect();
  final users = await c.execute("SELECT id FROM fh.users WHERE role = 'admin' AND is_active ORDER BY id LIMIT 1");
  final adminId = (users.first[0] as num).toInt();
  final tokenStr = FhJwt.generateToken(userId: adminId, email: 'legacy@test.uz', role: 'admin');

  final whs = await c.execute(
    "SELECT id, name FROM fh.warehouses WHERE is_active ORDER BY id LIMIT 2");
  final whA = (whs[0][0] as num).toInt();
  final whB = (whs[1][0] as num).toInt();

  // fh.items da bo'lishi mumkin bo'lmagan ref id.
  final refRow = await c.execute('SELECT COALESCE(MAX(id), 100000) + 1 FROM fh.items');
  final refId = (refRow.first[0] as num).toInt();
  final refText = refId.toString();

  await c.execute("DELETE FROM fh.stock_ledger WHERE name_snapshot = \$1", parameters: [SN]);
  await c.execute(
    "DELETE FROM fh.stock_transfers WHERE item_id = \$1 AND source_warehouse_id IN (\$2, \$3)",
    parameters: [refId, whA, whB]);

  final route = await c.execute(
    'SELECT 1 FROM fh.warehouse_transfer_routes WHERE from_warehouse_id = \$1 AND to_warehouse_id = \$2',
    parameters: [whA, whB]);
  var routeInserted = false;
  if (route.isEmpty) {
    await c.execute(
      'INSERT INTO fh.warehouse_transfer_routes (from_warehouse_id, to_warehouse_id) VALUES (\$1, \$2)',
      parameters: [whA, whB]);
    routeInserted = true;
  }

  await c.execute(
    "INSERT INTO fh.stock_ledger (warehouse_id, item_type, ref_id, ref_barcode, name_snapshot, unit, "
    " direction, qty, source_type, source_ref, performed_by, note) "
    "VALUES (\$1, 'raw_material', \$2, NULL, \$3, 'kg', 'in', 10, 'manual', 'legacy:seed', \$4, 'legacy seed')",
    parameters: [whA, refId, SN, adminId]);

  var ok = true;
  void chk(String name, bool v, [String d = '']) {
    ok = ok && v;
    print('${v ? "PASS" : "FAIL"}  $name  $d');
  }

  var balA = await ledBal(c, whA, refText, 'raw_material');
  chk('seed balance 10', balA == 10, 'bal=$balA');

  var (s, j) = await call('POST', '/transfers/send', {
    'item_id': refId, 'quantity': 2, 'unit': 'kg',
    'source_warehouse_id': whA, 'dest_warehouse_id': whB, 'note': 'legacy test',
  }, tokenStr);
  chk('send legacy item 201', s == 201, 's=$s $j');
  if (s != 201) return;
  final t1 = (j['transferId'] as num).toInt();

  balA = await ledBal(c, whA, refText, 'raw_material');
  chk('source deducted to 8', balA == 8, 'bal=$balA');

  (s, j) = await call('GET', '/transfers/pending?warehouse_id=$whB', null, tokenStr);
  final pend = ((j['transfers'] as List?) ?? []).where((e) => e['id'] == t1).toList();
  chk('pending lists legacy item name', pend.isNotEmpty && pend.first['itemName'] == SN, '$pend');

  (s, j) = await call('POST', '/transfers/$t1/confirm', {}, tokenStr);
  chk('confirm 200', s == 200, 's=$s $j');

  final balB = await ledBal(c, whB, refText, 'raw_material');
  chk('dest received +2', balB == 2, 'bal=$balB');
  balA = await ledBal(c, whA, refText, 'raw_material');
  chk('source still 8', balA == 8, 'bal=$balA');

  // Reject tarmog'i: yana bitta send, rad etish → manba omboriga qaytadi.
  (s, j) = await call('POST', '/transfers/send', {
    'item_id': refId, 'quantity': 3, 'unit': 'kg',
    'source_warehouse_id': whA, 'dest_warehouse_id': whB, 'note': 'legacy reject test',
  }, tokenStr);
  chk('send2 201', s == 201, 's=$s $j');
  final t2 = (j['transferId'] as num).toInt();

  (s, j) = await call('POST', '/transfers/$t2/reject', {'reason': 'noto\'g\'ri miqdor'}, tokenStr);
  chk('reject 200', s == 200, 's=$s $j');

  balA = await ledBal(c, whA, refText, 'raw_material');
  chk('source after reject 8', balA == 8, 'bal=$balA');
  final balB2 = await ledBal(c, whB, refText, 'raw_material');
  chk('dest unchanged 2', balB2 == 2, 'bal=$balB2');

  // Tozalash
  await c.execute("DELETE FROM fh.stock_ledger WHERE name_snapshot = \$1", parameters: [SN]);
  await c.execute(
    "DELETE FROM fh.stock_transfers WHERE item_id = \$1 AND source_warehouse_id IN (\$2, \$3)",
    parameters: [refId, whA, whB]);
  if (routeInserted) {
    await c.execute(
      'DELETE FROM fh.warehouse_transfer_routes WHERE from_warehouse_id = \$1 AND to_warehouse_id = \$2',
      parameters: [whA, whB]);
  }
  await c.close();

  print('\n${ok ? "ALL PASS" : "FAILURES"}');
  if (!ok) exitCode = 1;
}