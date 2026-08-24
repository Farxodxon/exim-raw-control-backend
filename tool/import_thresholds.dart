import 'dart:io';
import 'dart:math';

import 'package:postgres/postgres.dart';
import 'package:spreadsheet_decoder/spreadsheet_decoder.dart';

// Excel qator indeksi (0-based) -> DB barcode
const Map<int, String> rowBarcode = {
  // Стойкая крем-краска 3D *18
  1: '4780023328249', 2: '4780023328256', 3: '4780023328263',
  4: '4780023328287', 5: '4780023328270', 6: '4780023328294',
  7: '4780023328300', 8: '4780023328317', 9: '4780023328331',
  10: '4780023328348', 11: '4780023328355', 12: '4780023328362',
  13: '4780023328379', 14: '4780023328386', 15: '4780023328393',
  16: '4780023328409', 17: '4780023328416', 18: '4780023328430',
  19: '4780023328423', 20: '4780023328447', 21: '4780023328454',
  22: '4780023328324', 23: '4780023328461', 24: '4780023328478',
  25: '4780023328492', 26: '4780023328485', 27: '4780023328508',
  28: '4780023328539', 29: '4780023328515', 30: '4780023328522',
  // Blond
  32: '4780023320649', 33: '4780023322902',
  // Мицеллярная вода 200мл *18
  37: '4780023329239', 38: '4780023329253',
  // ELETT кош краска *30
  41: '4780023326757', 42: '4780023326764',
  // Мицеллярная вода 400мл *12
  45: '4780023329161', 46: '4780023329178',
  47: '4780023329185', 48: '4780023329192',
  // CAREAL *8
  57: '4780023328898', 58: '4780023328881', 59: '4780023328874',
  // Депилятор 125мл *20
  62: '4780023321929', 63: '4780023321912',
  // Крема 44гр *50
  66: '4780023321578', 67: '4780023321660', 68: '4780023321592',
  69: '4780023321707', 70: '4780023321721', 71: '4780023321684',
  72: '4780023321738', 73: '4780023321745', 74: '4780023321769',
  75: '4780023321790',
  // Двухфазный спрей *15
  78: '4780023327709', 79: '4780023327716', 80: '4780023327723',
  81: '4780023327730', 82: '4780023327747',
  // Бальзам SPUMA 500мл *18
  85: '4780023321363', 86: '4780023321370', 87: '4780023321387',
  88: '4780023321394', 89: '4780023321400', 90: '4780023321417',
  // Жидкое мыло 500гр *15
  94: '4780023320458', 95: '4780023320465', 96: '4780023320489',
  97: '4780023320496', 98: '4780023320502',
  // Шампунь 900гр *8 (Авокадо = "для восстановления волос")
  101: '4780023323381',
  102: '4780023323404', 103: '4780023323398',
  104: '4780023325651', 105: '4780023325668',
  // Для мытья посуды Лимон (excel *8, db 500ml*12 — flag!)
  108: '4780023327600',
  // Шампунь Spuma 1000гр *8
  113: '4780023322988', 114: '4780023320021',
  // КРАСКА ШАМПУНЬ 25мл *180
  117: '4780023327693', 118: '4780023329215',
  // Жидкое Порошок 1500гр *4
  121: '4780141190551', 122: '4780141190575', 123: '4780141190537',
  // Бальзам 900гр *8 Авокадо
  126: '4780023326429',
};

const monthCols = [1, 2, 3, 4, 5, 6, 7]; // YANVAR..IYUL

double? _num(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString().replaceAll(',', '.').trim());
}

Future<void> main(List<String> args) async {
  final doWrite = args.contains('--write');
  final bytes =
      File(r'D:\Flutter\factory hub\ЖАМИ РЕГИОНЛАР (3).xlsx').readAsBytesSync();
  final dec = SpreadsheetDecoder.decodeBytes(bytes);
  final sheet = dec.tables['Лист1']!;
  final rows = sheet.rows;

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

  final prodRows = await conn.execute(
      'SELECT barcode, name, pcs_in_box FROM public.products');
  final prodByName = <String, List<dynamic>>{};
  for (final r in prodRows) {
    prodByName[(r[0] as String)] = r.toList();
  }

  stdout.writeln(doWrite ? '=== YOZISH REJIMI ===' : '=== DRY RUN ===');
  stdout.writeln(
      'r | nom | barcode | box | oylar | ort.karobka/oy | ort.dona/oy | chegara(x3)');
  var okCount = 0;
  final pending = <List<dynamic>>[];

  for (var r = 0; r < rows.length; r++) {
    if (!rowBarcode.containsKey(r)) continue;
    final vals = monthCols.map((c) => _num(rows[r][c])).toList();
    final filled = vals.whereType<double>().toList();
    if (filled.isEmpty) {
      stdout.writeln("R$r: MA'LUMOT YO'Q — o'tkazib yuborildi");
      continue;
    }
    final barcode = rowBarcode[r]!;
    final p = prodByName[barcode];
    if (p == null) {
      stdout.writeln('R$r: BARCODE BAZADA TOPILMADI $barcode');
      continue;
    }
    final pcsInBox = (p[2] as int?) ?? 1;
    final avgBoxes = filled.reduce((a, b) => a + b) / filled.length;
    final avgPieces = avgBoxes * pcsInBox;
    final minQty = (avgPieces * 3).ceil();
    okCount++;
    stdout.writeln(
        'R$r | ${(p[1] as String).trim().split('/').first.trim().substring(0, min(40, (p[1] as String).trim().split('/').first.trim().length))}.. | ${p[0]} | x$pcsInBox | ${filled.length} oy | ${avgBoxes.toStringAsFixed(1)} | ${avgPieces.toStringAsFixed(0)} | $minQty');
    pending.add([barcode, minQty]);
  }

  stdout.writeln('\nMos kelgan: $okCount');

  if (doWrite && pending.isNotEmpty) {
    await conn.execute('BEGIN');
    try {
      await conn.execute(
        "DELETE FROM fh.stock_thresholds WHERE item_type = 'product'",
      );
      for (final e in pending) {
        await conn.execute(
          Sql.named(
            "INSERT INTO fh.stock_thresholds "
            "(item_type, ref_id, ref_barcode, warehouse_id, min_qty) "
            "VALUES ('product', NULL, @bc, NULL, @qty)",
          ),
          parameters: {'bc': e[0], 'qty': e[1]},
        );
      }
      await conn.execute('COMMIT');
      stdout.writeln('Yozildi: ${pending.length} chegara.');
    } catch (_) {
      await conn.execute('ROLLBACK');
      rethrow;
    }
  } else if (!doWrite) {
    stdout.writeln('Dry-run: hech narsa yozilmadi (--write bilan yozing).');
  }

  await conn.close();
}
