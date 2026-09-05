import 'dart:convert';
import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:dotenv/dotenv.dart';
import 'package:exim_raw_backend/factoryhub/jwt.dart';

// BOM PUT (tarkib almashtirish) validatsiyasi. Talab: local server 8051 da ishlayapti.

const base = 'http://127.0.0.1:8051/fh';
const P = 'PUTBOM %';

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

Future<void> main() async {
  final c = await connect();
  final users = await c.execute("SELECT id FROM fh.users WHERE role = 'admin' AND is_active ORDER BY id LIMIT 1");
  final adminId = (users.first[0] as num).toInt();
  final tokenStr = FhJwt.generateToken(userId: adminId, email: 'putbom@test.uz', role: 'admin');

  await c.execute("DELETE FROM fh.bom_items WHERE bom_id IN (SELECT id FROM fh.boms WHERE name LIKE \$1)", parameters: [P]);
  await c.execute("DELETE FROM fh.boms WHERE name LIKE \$1", parameters: [P]);
  await c.execute("DELETE FROM fh.stock_ledger WHERE name_snapshot LIKE \$1", parameters: [P]);
  await c.execute("DELETE FROM fh.items WHERE name LIKE \$1", parameters: [P]);

  final out = await c.execute(
    "INSERT INTO fh.items (name, item_type, code, unit) VALUES ('PUTBOM Chiqish','semi_finished','putbom-out','kg') RETURNING id");
  final ing1 = await c.execute(
    "INSERT INTO fh.items (name, item_type, code, unit) VALUES ('PUTBOM Tarkib1','raw','putbom-ing1','kg') RETURNING id");
  final ing2 = await c.execute(
    "INSERT INTO fh.items (name, item_type, code, unit) VALUES ('PUTBOM Tarkib2','raw','putbom-ing2','kg') RETURNING id");
  final outId = (out.first[0] as num).toInt();
  final ing1Id = (ing1.first[0] as num).toInt();
  final ing2Id = (ing2.first[0] as num).toInt();

  List<Map<String, dynamic>> ingItems(List<int> ids, List<double> qs) => [
        for (var i = 0; i < ids.length; i++)
          {'item_type': 'raw', 'ref_id': ids[i], 'ref_barcode': null, 'name': 'PUTBOM Tarkib', 'unit': 'kg', 'qty': qs[i]},
      ];

  var ok = true;
  void chk(String name, bool v, [String d = '']) {
    ok = ok && v;
    print('${v ? "PASS" : "FAIL"}  $name  $d');
  }

  var (s, j) = await call('POST', '/boms', {
    'name': "$P A", 'stage': 'mixing', 'output_item_id': outId, 'output_qty': 5, 'output_unit': 'kg',
    'items': ingItems([ing1Id], [2.0]),
  }, tokenStr);
  chk('BOM create 201', s == 201, 's=$s $j');
  final bomId = (j['bomId'] as num).toInt();

  (s, j) = await call('PUT', '/boms/$bomId', {
    'name': "$P B", 'output_qty': 7, 'output_unit': 'l', 'items': ingItems([ing1Id, ing2Id], [1.5, 3.5]),
  }, tokenStr);
  chk('BOM PUT update 200', s == 200, 's=$s $j');

  (s, j) = await call('GET', '/boms/$bomId', null, tokenStr);
  final bom = j['bom'] as Map? ?? const {};
  final itemsList = (j['items'] as List?) ?? [];
  chk('name updated', bom['name'] == "$P B", '$bom');
  chk('qty updated 7', (bom['outputQty'] as String? ?? '') == '7.0' || (bom['outputQty'] as String? ?? '') == '7', '$bom');
  chk('unit updated l', (bom['outputUnit'] as String? ?? '') == 'l', '$bom');
  chk('items replaced to 2', itemsList.length == 2, '${itemsList.length}');
  final qtySum = itemsList.fold<double>(0, (a, e) => a + double.tryParse((e['qty'] ?? '').toString())!);
  chk('items qty sum 5.0', qtySum == 5.0, 'qtySum=$qtySum');

  (s, j) = await call('PUT', '/boms/$bomId', {'name': 'x', 'items': <Map>[]}, tokenStr);
  chk('empty items rejected 400', s == 400, 's=$s $j');

  await c.execute("UPDATE fh.boms SET is_active = false WHERE name LIKE \$1", parameters: [P]);
  await c.execute("DELETE FROM fh.bom_items WHERE bom_id IN (SELECT id FROM fh.boms WHERE name LIKE \$1)", parameters: [P]);
  await c.execute("DELETE FROM fh.boms WHERE name LIKE \$1", parameters: [P]);
  await c.execute("DELETE FROM fh.stock_ledger WHERE name_snapshot LIKE \$1", parameters: [P]);
  await c.execute("DELETE FROM fh.items WHERE name LIKE \$1", parameters: [P]);
  await c.close();

  print('\n${ok ? "ALL PASS" : "FAILURES"}');
  if (!ok) exitCode = 1;
}