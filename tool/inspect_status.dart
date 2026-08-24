import 'package:postgres/postgres.dart';
import 'dart:io';

void main() async {
  var url = Platform.environment['DATABASE_URL']!;
  final uri = Uri.parse(url);
  final ui = uri.userInfo.split(':');
  final conn = await Connection.open(
    Endpoint(
      host: uri.host,
      port: uri.port != 0 ? uri.port : 5432,
      database: uri.pathSegments.first,
      username: ui.first,
      password: ui.length > 1 ? ui.sublist(1).join(':') : null,
    ),
    settings: ConnectionSettings(sslMode: SslMode.require),
  );

  print('=== OMBORLAR ===');
  final wh = await conn.execute(
    'SELECT id, name, type, is_active FROM fh.warehouses ORDER BY id');
  for (final r in wh) {
    print('${r[0]}. ${r[1]} (${r[2]}) ${r[3] == true ? '' : '[FAOL EMAS]'}');
  }

  print('\n=== NORMALAR (product_materials) ===');
  final normTotal = await conn.execute(
      'SELECT COUNT(*) FROM public.product_materials WHERE is_active');
  final normProducts = await conn.execute(
      'SELECT COUNT(DISTINCT product_barcode) FROM public.product_materials WHERE is_active');
  print('Norma yozuvlari: ${normTotal.first[0]}, qamrab olgan mahsulot: ${normProducts.first[0]} / 265');

  final sample = await conn.execute('''
    SELECT pm.product_barcode, p.name, COUNT(*) AS mat_count
    FROM public.product_materials pm
    LEFT JOIN public.products p ON p.barcode = pm.product_barcode
    WHERE pm.is_active
    GROUP BY pm.product_barcode, p.name ORDER BY mat_count DESC LIMIT 5''');
  for (final r in sample) {
    print('${r[0]} ${r[1] ?? "?"} → ${r[2]} xom ashyo');
  }

  print('\n=== THRESHOLD (fh.stock_thresholds) ===');
  final th = await conn.execute('SELECT COUNT(*) FROM fh.stock_thresholds');
  print('Threshold yozuvlari: ${th.first[0]}');

  print('\n=== LEDGER VA BUYURTMALAR ===');
  final lg = await conn.execute('SELECT COUNT(*) FROM fh.stock_ledger');
  final so = await conn.execute(
      "SELECT status, COUNT(*) FROM fh.supplier_orders GROUP BY status");
  final pl =
      await conn.execute("SELECT status, COUNT(*) FROM fh.plans GROUP BY status");
  print('Ledger: ${lg.first[0]}');
  print('Supplier orders: ${so.isEmpty ? "yoq" : so.map((r) => "${r[0]}=${r[1]}").join(", ")}');
  print('Plans: ${pl.isEmpty ? "yoq" : pl.map((r) => "${r[0]}=${r[1]}").join(", ")}');

  print('\n=== XOM ASHYO NAMUNA (birinchi 5) ===');
  final rm = await conn.execute(
    'SELECT id, name, code, unit FROM public.raw_materials ORDER BY id LIMIT 5');
  for (final r in rm) {
    print('${r[0]}. ${r[1]} [${r[2]}] (${r[3]})');
  }

  await conn.close();
}
