import 'dart:convert';
import 'dart:io';

import 'package:spreadsheet_decoder/spreadsheet_decoder.dart';

void main(List<String> args) {
  final path = args.isNotEmpty
      ? args[0]
      : r'D:\Flutter\factory hub\ЖАМИ РЕГИОНЛАР (3).xlsx';
  final bytes = File(path).readAsBytesSync();
  final decoder = SpreadsheetDecoder.decodeBytes(bytes);

  stdout.writeln('SHEETS: ${decoder.tables.keys.toList()}');
  for (final name in decoder.tables.keys) {
    final t = decoder.tables[name]!;
    stdout.writeln(
        '\n=== SHEET "$name" rows=${t.maxRows} ===');
    final preview = t.rows.length;
    for (var r = 0; r < preview; r++) {
      final row = t.rows[r];
      final cells = <String>[];
      for (var c = 0; c < row.length && c < 14; c++) {
        var v = row[c];
        if (v == null) v = '';
        cells.add('[$c]$v');
      }
      stdout.writeln('R$r: ${cells.join(' | ')}');
    }
    if (t.rows.length > 12) {
      stdout.writeln('(last row included above)');
    }
  }
}
