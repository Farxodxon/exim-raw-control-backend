import 'dart:convert';
import 'dart:typed_data';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:exim_raw_backend/database/connection.dart';
import 'package:exim_raw_backend/factoryhub/jwt.dart';
import 'package:exim_raw_backend/factoryhub/policy.dart';
import 'package:exim_raw_backend/factoryhub/user_storage.dart';
import 'package:excel/excel.dart';

final Router _router = Router().._registerRoutes();

Handler fhHandler = const Pipeline()
    .addMiddleware(_authMiddleware)
    .addHandler(_router.call);

Response _json(Object? body, {int status = 200}) => Response(
      status,
      body: jsonEncode(body),
      headers: {'Content-Type': 'application/json'},
    );

Future<Map<String, dynamic>> _body(Request request) async =>
    jsonDecode(await request.readAsString()) as Map<String, dynamic>;

Map<String, dynamic> _user(Request request) =>
    request.context['fh_user'] as Map<String, dynamic>? ?? {};

String _role(Request request) => (_user(request)['role'] ?? '') as String;

int? _uid(Request request) => _user(request)['user_id'] as int?;

void _buildSheet(Excel excel, String sheetName, List<dynamic> rows, String direction, String from, String to) {
  final sheet = excel[sheetName];

  final headerStyle = CellStyle(
    bold: true,
    backgroundColorHex: ExcelColor.fromHexString('#1A6B3C'),
    fontColorHex: ExcelColor.fromHexString('#FFFFFF'),
    fontSize: 11,
  );

  final headers = ['Sana', 'Ombor', 'Kodi', 'Nomi', 'Birlik', 'Miqdor', 'Izoh', 'Bajarildi'];
  for (var i = 0; i < headers.length; i++) {
    final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
    cell.value = TextCellValue(headers[i]);
    cell.cellStyle = headerStyle;
  }

  var rowIdx = 1;
  for (final r in rows) {
    final d = r[2]?.toString() ?? '';
    if (d != direction) continue;

    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: rowIdx)).value =
        TextCellValue(r[0]?.toString() ?? '');
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: rowIdx)).value =
        TextCellValue(r[1]?.toString() ?? '');
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: rowIdx)).value =
        TextCellValue(r[3]?.toString() ?? '');
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: rowIdx)).value =
        TextCellValue(r[4]?.toString() ?? '');
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: rowIdx)).value =
        TextCellValue(r[5]?.toString() ?? '');
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 5, rowIndex: rowIdx)).value =
        TextCellValue(r[6]?.toString() ?? '');
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 6, rowIndex: rowIdx)).value =
        TextCellValue(r[7]?.toString() ?? '');
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 7, rowIndex: rowIdx)).value =
        TextCellValue(r[8]?.toString() ?? '');
    rowIdx++;
  }
}

Middleware _authMiddleware = (innerHandler) {
  return (request) async {
    if (request.method == 'OPTIONS') return innerHandler(request);

    final path = request.url.path;
    if (path == 'login' || path == 'setup') {
      return innerHandler(request);
    }

    final authHeader =
        request.headers['Authorization'] ?? request.headers['authorization'];
    final payload = FhJwt.getUserFromToken(authHeader);

    if (payload == null) {
      return _json(
        {'error': 'Avtorizatsiya talab qilinadi. Iltimos, qayta kiring.'},
        status: 401,
      );
    }

    return innerHandler(request.change(context: {'fh_user': payload}));
  };
};

extension _FhRoutes on Router {
  void _registerRoutes() {
    // ---------- AUTH ----------
    post('/login', (Request request) async {
      try {
        final body = await _body(request);
        final email = body['email'] as String?;
        final password = body['password'] as String?;

        if (email == null || password == null) {
          return _json({'error': 'email va password majburiy'}, status: 400);
        }

        final user = await FhUserStorage.login(email, password);
        if (user == null) {
          return _json(
            {'error': 'Email yoki parol noto\'g\'ri yoki hisob faol emas'},
            status: 401,
          );
        }

        final token = FhJwt.generateToken(
          userId: user.id,
          email: user.email,
          role: user.role,
        );

        return _json({
          'message': 'Muvaffaqiyatli kirish',
          'token': token,
          'user': user.toJson(),
        });
      } catch (e) {
        return _json({'error': 'Xatolik: $e'}, status: 400);
      }
    });

    post('/setup', (Request request) async {
      try {
        final body = await _body(request);
        final username = body['username'] as String?;
        final email = body['email'] as String?;
        final password = body['password'] as String?;
        final secretKey = body['secret_key'] as String?;

        if (secretKey != FhJwt.setupSecretKey) {
          return _json({'error': 'Maxfiy kalit noto\'g\'ri'}, status: 403);
        }
        if (username == null || email == null || password == null) {
          return _json(
            {'error': 'username, email, password majburiy'},
            status: 400,
          );
        }

        final user = await FhUserStorage.createFirstAdmin(username, email, password);
        if (user == null) {
          return _json({'error': 'Admin allaqachon mavjud'}, status: 409);
        }

        return _json({'message': 'Admin yaratildi', 'user': user.toJson()}, status: 201);
      } catch (e) {
        return _json({'error': 'Xatolik: $e'}, status: 400);
      }
    });

    // ---------- USERS (assign oldin, <id> dan) ----------
    post('/users/assign', (Request request) async {
      if (!Policy.canManageUsers(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      if (request.method != 'POST') {
        return _json({'error': 'Faqat POST'}, status: 405);
      }
      try {
        final body = await _body(request);
        final userId = body['user_id'] as int?;
        final warehouseIds = (body['warehouse_ids'] as List?)
                ?.map((e) => e as int)
                .toList() ??
            [];

        if (userId == null) {
          return _json({'error': 'user_id majburiy'}, status: 400);
        }

        final db = await DatabaseConnection.getConnection();
        await db.execute('BEGIN');
        try {
          await db.execute(
            'DELETE FROM fh.user_warehouses WHERE user_id = \$1',
            parameters: [userId],
          );
          for (final wId in warehouseIds) {
            await db.execute(
              'INSERT INTO fh.user_warehouses (user_id, warehouse_id) VALUES (\$1, \$2) '
              'ON CONFLICT DO NOTHING',
              parameters: [userId, wId],
            );
          }
          await db.execute('COMMIT');
        } catch (_) {
          await db.execute('ROLLBACK');
          rethrow;
        }

        final wareResult = await db.execute(
          '''SELECT w.id, w.name, w.type FROM fh.warehouses w
             JOIN fh.user_warehouses uw ON uw.warehouse_id = w.id
             WHERE uw.user_id = \$1''',
          parameters: [userId],
        );

        return _json({
          'message': 'Biriktirildi',
          'warehouses': wareResult
              .map((r) => {'id': r[0], 'name': r[1], 'type': r[2]})
              .toList(),
        });
      } catch (e) {
        print('assign xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    get('/users', (Request request) async {
      if (!Policy.canManageUsers(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      try {
        final db = await DatabaseConnection.getConnection();
          final result = await db.execute(
            '''SELECT u.id, u.username, u.email, COALESCE(u.role, 'warehouse_keeper'),
             COALESCE(u.is_active, true), u.created_at, COALESCE(u.department, '')
             FROM fh.users u ORDER BY u.id''',
          );

          final users = <Map<String, dynamic>>[];
          for (final row in result) {
            final wareResult = await db.execute(
              '''SELECT w.id, w.name, w.type FROM fh.warehouses w
                 JOIN fh.user_warehouses uw ON uw.warehouse_id = w.id
                 WHERE uw.user_id = \$1''',
              parameters: [row[0]],
            );
            users.add({
              'id': row[0],
              'username': row[1],
              'email': row[2],
              'role': row[3],
              'isActive': row[4],
              'createdAt': row[5]?.toString(),
              'department': row[6],
              'warehouses': wareResult
                  .map((w) => {'id': w[0], 'name': w[1], 'type': w[2]})
                  .toList(),
            });
          }
        return _json({'users': users, 'total': users.length});
      } catch (e) {
        print('users GET xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    post('/users', (Request request) async {
      if (!Policy.canManageUsers(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      try {
        final body = await _body(request);
        final username = body['username'] as String?;
        final email = body['email'] as String?;
        final password = body['password'] as String?;
        final role = body['role'] as String? ?? AppRoles.warehouseKeeper;

        if (username == null || email == null || password == null) {
          return _json(
            {'error': 'username, email, password majburiy'},
            status: 400,
          );
        }
        if (!AppRoles.isValid(role)) {
          return _json({'error': "Rol noto'g'ri"}, status: 400);
        }

        final user = await FhUserStorage.createUser(
          username: username,
          email: email,
          password: password,
          role: role,
          department: body['department'] as String?,
        );
        if (user == null) {
          return _json({'error': 'Email band yoki rol xato'}, status: 409);
        }
        return _json(
          {'message': 'Foydalanuvchi yaratildi', 'user': user.toJson()},
          status: 201,
        );
      } catch (_) {
        return _json({'error': 'Xatolik'}, status: 400);
      }
    });

    get('/users/<id>', (Request request, String id) async {
      final userId = int.tryParse(id);
      if (userId == null) return _json({'error': "Noto'g'ri ID"}, status: 400);

      final callerRole = _role(request);
      final callerId = _uid(request);
      final isSelf = callerId == userId;
      if (!isSelf && !Policy.canManageUsers(callerRole)) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }

      try {
        final db = await DatabaseConnection.getConnection();
        final userResult = await db.execute(
          'SELECT id, username, email, role, COALESCE(is_active, true), COALESCE(department, \'\') '
          'FROM fh.users WHERE id = \$1',
          parameters: [userId],
        );
        if (userResult.isEmpty) {
          return _json({'error': 'Topilmadi'}, status: 404);
        }
        final u = userResult.first;

        final wareResult = await db.execute(
          '''SELECT w.id, w.name, w.type FROM fh.warehouses w
             JOIN fh.user_warehouses uw ON uw.warehouse_id = w.id
             WHERE uw.user_id = \$1''',
          parameters: [userId],
        );

        return _json({
          'user': {
            'id': u[0], 'username': u[1], 'email': u[2],
            'role': u[3], 'isActive': u[4], 'department': u[5],
          },
          'warehouses': wareResult
              .map((r) => {'id': r[0], 'name': r[1], 'type': r[2]})
              .toList(),
        });
      } catch (e) {
        print('users/:id GET xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    put('/users/<id>', (Request request, String id) async {
      final userId = int.tryParse(id);
      if (userId == null) return _json({'error': "Noto'g'ri ID"}, status: 400);

      final callerRole = _role(request);
      final callerId = _uid(request);
      final isSelf = callerId == userId;
      if (!isSelf && !Policy.canManageUsers(callerRole)) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }

      try {
        final body = await _body(request);
        final canManage = Policy.canManageUsers(callerRole);
        final user = await FhUserStorage.update(
          userId,
          username: body['username'] as String?,
          email: canManage ? body['email'] as String? : null,
          password: body['password'] as String?,
          role: canManage ? body['role'] as String? : null,
          isActive: canManage ? body['is_active'] as bool? : null,
          department: canManage ? body['department'] as String? : null,
        );
        if (user == null) {
          return _json(
            {'error': "Yangilanmadi (rol xato bo'lishi mumkin)"},
            status: 400,
          );
        }
        return _json({'message': 'Yangilandi', 'user': user.toJson()});
      } catch (_) {
        return _json({'error': 'Xatolik'}, status: 400);
      }
    });

    delete('/users/<id>', (Request request, String id) async {
      final userId = int.tryParse(id);
      if (userId == null) return _json({'error': "Noto'g'ri ID"}, status: 400);

      final callerRole = _role(request);
      final callerId = _uid(request);
      if (!Policy.canManageUsers(callerRole)) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      if (callerId == userId) {
        return _json({'error': "O'zingizni o'chira olmaysiz"}, status: 400);
      }
      final user = await FhUserStorage.update(userId, isActive: false);
      if (user == null) return _json({'error': 'Topilmadi'}, status: 404);
      return _json({'message': 'Deaktivatsiya qilindi'});
    });

    // ---------- FACTORY SETTINGS ----------
    get('/factory/settings', (Request request) async {
      try {
        final db = await DatabaseConnection.getConnection();
        final result = await db.execute(
          'SELECT name, address, updated_at FROM fh.factory_settings WHERE id = 1',
        );
        if (result.isEmpty) {
          return _json({'error': 'Sozlamalar topilmadi'}, status: 404);
        }
        final row = result.first;
        return _json({
          'factory': {
            'id': 1,
            'name': row[0],
            'address': row[1],
            'updatedAt': row[2]?.toString(),
          },
        });
      } catch (e) {
        print('factory GET xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    put('/factory/settings', (Request request) async {
      if (!Policy.canManageSettings(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      try {
        final body = await _body(request);
        final name = body['name'] as String?;
        final address = body['address'] as String?;

        if (name == null || name.trim().isEmpty) {
          return _json({'error': 'name majburiy'}, status: 400);
        }

        final db = await DatabaseConnection.getConnection();
        await db.execute(
          'UPDATE fh.factory_settings SET name = \$1, '
          'address = COALESCE(\$2, address), updated_at = now() WHERE id = 1',
          parameters: [name.trim(), address],
        );
        return _json({'message': 'Saqlandi'});
      } catch (_) {
        return _json({'error': 'Xatolik'}, status: 400);
      }
    });

    // ---------- CATALOG ----------
    get('/catalog/raw-materials', (Request request) async {
      try {
        final db = await DatabaseConnection.getConnection();
        final result = await db.execute('''
          SELECT rm.id, rm.name, rm.code, rm.unit,
            COALESCE((
              SELECT SUM(CASE l.direction WHEN 'in' THEN l.qty ELSE -l.qty END)
              FROM fh.stock_ledger l
              WHERE l.item_type = 'raw_material' AND l.ref_id = rm.id
            ), 0) AS stock
          FROM public.raw_materials rm
          ORDER BY rm.name
        ''');

        return _json({
          'rawMaterials': result.map((row) => {
            'id': row[0], 'name': row[1], 'code': row[2],
            'unit': row[3], 'stock': row[4]?.toString(),
          }).toList(),
          'total': result.length,
        });
      } catch (e) {
        print('raw-materials xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    get('/catalog/products', (Request request) async {
      try {
        final search = request.url.queryParameters['search']?.trim();

        final db = await DatabaseConnection.getConnection();
        final result = await db.execute(
          '''
          SELECT p.barcode, p.name, p.category, p.pcs_in_box, p.price_usd,
                 p.netto_per_piece,
                 COALESCE((
                   SELECT SUM(CASE l.direction WHEN 'in' THEN l.qty ELSE -l.qty END)
                   FROM fh.stock_ledger l
                   WHERE l.item_type = 'product' AND l.ref_barcode = p.barcode
                 ), 0) AS stock
          FROM public.products p
          WHERE (\$1::varchar IS NULL OR p.name ILIKE '%' || \$1 || '%' OR p.barcode LIKE '%' || \$1 || '%')
          ORDER BY p.name
          ''',
          parameters: [(search == null || search.isEmpty) ? null : search],
        );

        return _json({
          'products': result.map((row) => {
            'barcode': row[0], 'name': row[1], 'category': row[2],
            'pcsInBox': row[3], 'priceUsd': row[4]?.toString(),
            'nettoPerPiece': row[5]?.toString(), 'stock': row[6]?.toString(),
          }).toList(),
          'total': result.length,
        });
      } catch (e) {
        print('products xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    get('/catalog/partners', (Request request) async {
      try {
        final db = await DatabaseConnection.getConnection();
        final result = await db.execute('''
          SELECT id, firma_nomi, firma_turi, shartnoma_raqami, davlati, faolligi
          FROM public.partners
          ORDER BY faolligi DESC, firma_nomi
        ''');

        return _json({
          'partners': result.map((row) => {
            'id': row[0], 'name': row[1], 'type': row[2],
            'contractNumber': row[3], 'country': row[4], 'isActive': row[5],
          }).toList(),
          'total': result.length,
        });
      } catch (e) {
        print('partners xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ---------- WAREHOUSES ----------
    get('/warehouses', (Request request) async {
      final role = _role(request);
      final userId = _uid(request);

      try {
        final db = await DatabaseConnection.getConnection();

        var result;
        if (role == AppRoles.warehouseKeeper && userId != null) {
          result = await db.execute(
            '''SELECT w.id, w.name, w.type, w.is_active, w.created_at,
                     w.can_analyze, w.can_transfer, w.can_income, w.can_expense
               FROM fh.warehouses w
               JOIN fh.user_warehouses uw ON uw.warehouse_id = w.id
               WHERE uw.user_id = \$1
               ORDER BY w.id''',
            parameters: [userId],
          );
        } else {
          result = await db.execute(
            'SELECT id, name, type, is_active, created_at, can_analyze, can_transfer, can_income, can_expense FROM fh.warehouses ORDER BY id',
          );
        }

        final warehouses = <Map<String, dynamic>>[];
        for (final row in result) {
          final id = row[0];
          final countResult = await db.execute(
            "SELECT COUNT(DISTINCT COALESCE(ref_id::text, ref_barcode)) "
            'FROM fh.stock_ledger WHERE warehouse_id = \$1 AND direction IS NOT NULL',
            parameters: [id],
          );
          final routesResult = await db.execute(
            'SELECT to_warehouse_id FROM fh.warehouse_transfer_routes WHERE from_warehouse_id = \$1',
            parameters: [id],
          );
          warehouses.add({
            'id': id,
            'name': row[1],
            'type': row[2],
            'isActive': row[3],
            'createdAt': row[4]?.toString(),
            'canAnalyze': row[5] ?? true,
            'canTransfer': row[6] ?? false,
            'canIncome': row[7] ?? true,
            'canExpense': row[8] ?? true,
            'transferTo': routesResult.map((r) => r[0]).toList(),
            'itemCount': countResult.isNotEmpty ? countResult.first[0] : 0,
          });
        }

        return _json({'warehouses': warehouses, 'total': warehouses.length});
      } catch (e) {
        print('warehouses GET xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    post('/warehouses', (Request request) async {
      if (!Policy.canControlWarehouses(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      try {
        final body = await _body(request);
        final name = body['name'] as String?;
        final type = body['type'] as String?;
        final allowedTypes = [
          'raw', 'finished', 'spare_parts', 'semi_finished', 'sales', 'dealer',
          'production', 'packaging', 'purchased_finished', 'purchased_semi'
        ];

        if (name == null || name.trim().isEmpty || type == null) {
          return _json({'error': 'name va type majburiy'}, status: 400);
        }
        if (!allowedTypes.contains(type)) {
          return _json({'error': "type noto'g'ri"}, status: 400);
        }

        final canAnalyze = body['canAnalyze'] as bool? ?? true;
        final canTransfer = body['canTransfer'] as bool? ?? false;
        final canIncome = body['canIncome'] as bool? ?? true;
        final canExpense = body['canExpense'] as bool? ?? true;
        final transferTo = (body['transferTo'] as List?)?.map((e) => int.tryParse('$e')).whereType<int>().toList() ?? <int>[];

        final db = await DatabaseConnection.getConnection();
        await db.execute('BEGIN');
        final result = await db.execute(
          'INSERT INTO fh.warehouses (name, type, can_analyze, can_transfer, can_income, can_expense) '
          'VALUES (\$1, \$2, \$3, \$4, \$5, \$6) '
          'RETURNING id, name, type, is_active, created_at',
          parameters: [name.trim(), type, canAnalyze, canTransfer, canIncome, canExpense],
        );
        final row = result.first;
        final newId = row[0];

        if (canTransfer && transferTo.isNotEmpty) {
          for (final toId in transferTo) {
            if (toId != newId) {
              await db.execute(
                'INSERT INTO fh.warehouse_transfer_routes (from_warehouse_id, to_warehouse_id) '
                'VALUES (\$1, \$2) ON CONFLICT DO NOTHING',
                parameters: [newId, toId],
              );
            }
          }
        }
        await db.execute('COMMIT');

        return _json({
          'message': 'Ombor yaratildi',
          'warehouse': {
            'id': row[0], 'name': row[1], 'type': row[2], 'isActive': row[3],
            'canAnalyze': canAnalyze, 'canTransfer': canTransfer,
            'canIncome': canIncome, 'canExpense': canExpense,
            'transferTo': transferTo,
          },
        }, status: 201);
      } catch (e) {
        print('warehouses POST xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    put('/warehouses/<id>', (Request request, String id) async {
      if (!Policy.canControlWarehouses(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      final warehouseId = int.tryParse(id);
      if (warehouseId == null) {
        return _json({'error': "Noto'g'ri ID"}, status: 400);
      }
      try {
        final body = await _body(request);
        final db = await DatabaseConnection.getConnection();

        final exists = await db.execute(
          'SELECT 1 FROM fh.warehouses WHERE id = \$1',
          parameters: [warehouseId],
        );
        if (exists.isEmpty) {
          return _json({'error': 'Topilmadi'}, status: 404);
        }

        final canAnalyze = body['canAnalyze'] as bool? ?? true;
        final canTransfer = body['canTransfer'] as bool? ?? false;
        final canIncome = body['canIncome'] as bool? ?? true;
        final canExpense = body['canExpense'] as bool? ?? true;
        final transferTo = (body['transferTo'] as List?)
                ?.map((e) => int.tryParse('$e'))
                .whereType<int>()
                .where((t) => t != warehouseId)
                .toList() ??
            <int>[];

        await db.execute('BEGIN');
        await db.execute(
          'UPDATE fh.warehouses SET can_analyze = \$1, can_transfer = \$2, '
          'can_income = \$3, can_expense = \$4 WHERE id = \$5',
          parameters: [canAnalyze, canTransfer, canIncome, canExpense, warehouseId],
        );
        await db.execute(
          'DELETE FROM fh.warehouse_transfer_routes WHERE from_warehouse_id = \$1',
          parameters: [warehouseId],
        );
        if (canTransfer && transferTo.isNotEmpty) {
          for (final toId in transferTo) {
            final toExists = await db.execute(
              'SELECT 1 FROM fh.warehouses WHERE id = \$1',
              parameters: [toId],
            );
            if (toExists.isNotEmpty) {
              await db.execute(
                'INSERT INTO fh.warehouse_transfer_routes (from_warehouse_id, to_warehouse_id) '
                'VALUES (\$1, \$2) ON CONFLICT DO NOTHING',
                parameters: [warehouseId, toId],
              );
            }
          }
        }
        await db.execute('COMMIT');

        return _json({
          'message': 'Ombor yangilandi',
          'warehouse': {
            'id': warehouseId,
            'canAnalyze': canAnalyze, 'canTransfer': canTransfer,
            'canIncome': canIncome, 'canExpense': canExpense,
            'transferTo': transferTo,
          },
        });
      } catch (e) {
        print('warehouses PUT xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    delete('/warehouses/<id>', (Request request, String id) async {
      if (!Policy.canControlWarehouses(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      final warehouseId = int.tryParse(id);
      if (warehouseId == null) {
        return _json({'error': "Noto'g'ri ID"}, status: 400);
      }
      try {
        final db = await DatabaseConnection.getConnection();
        final exists = await db.execute(
          'SELECT id FROM fh.warehouses WHERE id = \$1',
          parameters: [warehouseId],
        );
        if (exists.isEmpty) {
          return _json({'error': 'Topilmadi'}, status: 404);
        }
        await db.execute('BEGIN');
        await db.execute(
          'DELETE FROM fh.warehouse_transfer_routes WHERE from_warehouse_id = \$1 OR to_warehouse_id = \$1',
          parameters: [warehouseId],
        );
        await db.execute(
          'DELETE FROM fh.stock_writes WHERE warehouse_id = \$1',
          parameters: [warehouseId],
        );
        await db.execute(
          'DELETE FROM fh.transfer_items WHERE transfer_id IN '
          '(SELECT id FROM fh.transfers WHERE from_warehouse_id = \$1 OR to_warehouse_id = \$1)',
          parameters: [warehouseId],
        );
        await db.execute(
          'DELETE FROM fh.transfers WHERE from_warehouse_id = \$1 OR to_warehouse_id = \$1',
          parameters: [warehouseId],
        );
        await db.execute(
          'DELETE FROM fh.production_batches WHERE source_warehouse_id = \$1 OR dest_warehouse_id = \$1',
          parameters: [warehouseId],
        );
        await db.execute(
          'DELETE FROM fh.stock_ledger WHERE warehouse_id = \$1',
          parameters: [warehouseId],
        );
        await db.execute(
          'DELETE FROM fh.product_warehouses WHERE warehouse_id = \$1',
          parameters: [warehouseId],
        );
        await db.execute(
          'DELETE FROM fh.user_warehouses WHERE warehouse_id = \$1',
          parameters: [warehouseId],
        );
        await db.execute(
          'DELETE FROM fh.warehouses WHERE id = \$1',
          parameters: [warehouseId],
        );
        await db.execute('COMMIT');
        return _json({'message': 'Ombor o\'chirildi'});
      } catch (e) {
        print('warehouses/:id DELETE xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    get('/warehouses/<id>', (Request request, String id) async {
      final warehouseId = int.tryParse(id);
      if (warehouseId == null) {
        return _json({'error': "Noto'g'ri ID"}, status: 400);
      }

      final role = _role(request);
      final userId = _uid(request);

      try {
        final db = await DatabaseConnection.getConnection();

        if (role == AppRoles.warehouseKeeper && userId != null) {
          final allowed = await db.execute(
            'SELECT 1 FROM fh.user_warehouses WHERE user_id = \$1 AND warehouse_id = \$2',
            parameters: [userId, warehouseId],
          );
          if (allowed.isEmpty) {
            return _json(
              {'error': 'Bu ombor sizga biriktirilmagan'},
              status: 403,
            );
          }
        }

        final infoResult = await db.execute(
          'SELECT name, type, is_active, created_at, can_analyze, can_transfer, can_income, can_expense '
          'FROM fh.warehouses WHERE id = \$1',
          parameters: [warehouseId],
        );
        if (infoResult.isEmpty) {
          return _json({'error': 'Topilmadi'}, status: 404);
        }
        final info = infoResult.first;

        final routesResult = await db.execute(
          'SELECT to_warehouse_id FROM fh.warehouse_transfer_routes WHERE from_warehouse_id = \$1',
          parameters: [warehouseId],
        );

        final stockResult = await db.execute(
          '''
          SELECT l.item_type,
                 COALESCE(
                   CASE
                     WHEN l.item_type = 'raw_material' THEN rm.code
                     WHEN l.item_type = 'item' AND l.ref_id IS NOT NULL THEN l.ref_id::text
                     ELSE l.ref_barcode
                   END
                 ) AS ref_key,
                 MAX(l.name_snapshot) AS name,
                 MAX(l.unit) AS unit,
                 SUM(CASE l.direction WHEN 'in' THEN l.qty ELSE -l.qty END) AS balance,
                 MAX(l.ref_id) AS ref_id,
                 MAX(l.ref_barcode) AS ref_barcode
          FROM fh.stock_ledger l
          LEFT JOIN public.raw_materials rm ON rm.id = l.ref_id
          WHERE l.warehouse_id = \$1
          GROUP BY l.item_type, COALESCE(
                   CASE
                     WHEN l.item_type = 'raw_material' THEN rm.code
                     WHEN l.item_type = 'item' AND l.ref_id IS NOT NULL THEN l.ref_id::text
                     ELSE l.ref_barcode
                   END
                 )
          HAVING SUM(CASE l.direction WHEN 'in' THEN l.qty ELSE -l.qty END) <> 0
          ORDER BY l.item_type, name
          ''',
          parameters: [warehouseId],
        );

        return _json({
          'warehouse': {
            'id': warehouseId,
            'name': info[0],
            'type': info[1],
            'isActive': info[2],
            'createdAt': info[3]?.toString(),
            'canAnalyze': info[4] ?? true,
            'canTransfer': info[5] ?? false,
            'canIncome': info[6] ?? true,
            'canExpense': info[7] ?? true,
            'transferTo': routesResult.map((r) => r[0]).toList(),
          },
          'stock': stockResult.map((row) => {
            'itemType': row[0], 'refKey': row[1], 'name': row[2],
            'unit': row[3], 'balance': row[4]?.toString(),
            'refId': row[5], 'refBarcode': row[6],
          }).toList(),
        });
      } catch (e) {
        print('warehouse/:id xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ---------- WAREHOUSE TRANSACTIONS HISTORY ----------
    get('/warehouses/<id>/transactions', (Request request, String id) async {
      final warehouseId = int.tryParse(id);
      if (warehouseId == null) return _json({'error': "Noto'g'ri ID"}, status: 400);

      final role = _role(request);
      final userId = _uid(request);

      try {
        final db = await DatabaseConnection.getConnection();

        if (role == AppRoles.warehouseKeeper && userId != null) {
          final allowed = await db.execute(
            'SELECT 1 FROM fh.user_warehouses WHERE user_id = \$1 AND warehouse_id = \$2',
            parameters: [userId, warehouseId],
          );
          if (allowed.isEmpty) {
            return _json({'error': 'Bu ombor sizga biriktirilmagan'}, status: 403);
          }
        }

        final limit = int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 50;
        final result = await db.execute(
          '''
          SELECT l.id, l.item_type, l.ref_id, l.ref_barcode, l.name_snapshot,
                 l.unit, l.direction, l.qty, l.source_type, l.note,
                 l.created_at, u.username,
                 CASE WHEN l.item_type = 'raw_material' THEN rm.code ELSE l.ref_barcode END AS code
          FROM fh.stock_ledger l
          LEFT JOIN fh.users u ON u.id = l.performed_by
          LEFT JOIN public.raw_materials rm ON rm.id = l.ref_id
          WHERE l.warehouse_id = \$1
          ORDER BY l.created_at DESC
          LIMIT \$2
          ''',
          parameters: [warehouseId, limit],
        );

        final transactions = result.map((row) => {
          'id': row[0],
          'itemType': row[1],
          'refId': row[2],
          'refBarcode': row[3],
          'name': row[4],
          'unit': row[5],
          'direction': row[6],
          'qty': row[7]?.toString(),
          'sourceType': row[8],
          'note': row[9],
          'createdAt': row[10]?.toString(),
          'performedBy': row[11],
          'code': row[12],
        }).toList();

        return _json({'transactions': transactions, 'total': transactions.length});
      } catch (e) {
        print('warehouse/:id/transactions xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ---------- STOCK TRANSACTION ----------
    post('/warehouse/transaction', (Request request) async {
      final role = _role(request);
      final userId = _uid(request);

      if (!Policy.canTransactStock(role)) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }

      try {
        final body = await _body(request);
        final warehouseId = body['warehouse_id'] as int?;
        final itemType = body['item_type'] as String?;
        final refId = body['ref_id'] as int?;
        final refBarcode = body['ref_barcode'] as String?;
        final direction = body['direction'] as String?;
        final qty = (body['qty'] as num?)?.toDouble();
        final note = body['note'] as String?;

        final allowedTypes = ['raw_material', 'product', 'spare_part', 'semi_finished', 'item'];
        if (warehouseId == null || itemType == null || direction == null || qty == null) {
          return _json(
            {'error': 'warehouse_id, item_type, direction, qty majburiy'},
            status: 400,
          );
        }
        if (!allowedTypes.contains(itemType) || !['in', 'out'].contains(direction)) {
          return _json(
            {'error': "item_type yoki direction noto'g'ri"},
            status: 400,
          );
        }
        if (qty <= 0) {
          return _json({'error': 'qty > 0 bo\'lishi kerak'}, status: 400);
        }
        if (itemType == 'raw_material' && refId == null) {
          return _json(
            {'error': 'raw_material uchun ref_id majburiy'},
            status: 400,
          );
        }
        if (itemType == 'product' && (refBarcode == null || refBarcode.isEmpty)) {
          return _json(
            {'error': 'product uchun ref_barcode majburiy'},
            status: 400,
          );
        }

        final db = await DatabaseConnection.getConnection();

        final whRow = await db.execute(
          'SELECT id, type, can_income, can_expense FROM fh.warehouses WHERE id = \$1 AND is_active',
          parameters: [warehouseId],
        );
        if (whRow.isEmpty) {
          return _json({'error': 'Ombor topilmadi'}, status: 404);
        }
        final whType = whRow.first[1] as String?;

        // ── Imkoniyatga asoslangan oqim nazorati (qo'lda kirim/chiqim) ──
        final canIncome = whRow.first[2] == true;
        final canExpense = whRow.first[3] == true;
        if (direction == 'in' && !canIncome) {
          return _json({
            'error': 'Bu ombor uchun qo\'lda kirim imkoniyati yoqilmagan',
          }, status: 403);
        }
        if (direction == 'out' && !canExpense) {
          return _json({
            'error': 'Bu ombor uchun qo\'lda chiqim imkoniyati yoqilmagan. Mahsulot faqat ishlab chiqarish yoki transfer orqali chiqadi',
          }, status: 403);
        }

        if (role == AppRoles.warehouseKeeper && userId != null) {
          final allowed = await db.execute(
            'SELECT 1 FROM fh.user_warehouses WHERE user_id = \$1 AND warehouse_id = \$2',
            parameters: [userId, warehouseId],
          );
          if (allowed.isEmpty) {
            return _json(
              {'error': 'Bu ombor sizga biriktirilmagan'},
              status: 403,
            );
          }
        }

        String nameSnapshot;
        String unit;
        if (itemType == 'raw_material') {
          final r = await db.execute(
            'SELECT name, unit FROM public.raw_materials WHERE id = \$1',
            parameters: [refId],
          );
          if (r.isEmpty) {
            return _json({'error': 'Xom ashyo topilmadi'}, status: 404);
          }
          nameSnapshot = r.first[0] as String;
          unit = r.first[1] as String? ?? 'kg';
        } else if (itemType == 'product') {
          final r = await db.execute(
            'SELECT name FROM public.products WHERE barcode = \$1',
            parameters: [refBarcode],
          );
          if (r.isEmpty) {
            return _json({'error': 'Mahsulot topilmadi'}, status: 404);
          }
          nameSnapshot = r.first[0] as String;
          unit = 'dona';
        } else {
          nameSnapshot = (body['name'] as String?) ?? 'Noma\'lum element';
          unit = (body['unit'] as String?) ?? 'dona';
        }

        if (direction == 'out') {
          final balResult = await db.execute(
            '''
            SELECT COALESCE(SUM(CASE direction WHEN 'in' THEN qty ELSE -qty END), 0)
            FROM fh.stock_ledger
            WHERE warehouse_id = \$1 AND item_type = \$2
              AND COALESCE(ref_id::text, ref_barcode) = COALESCE(\$3::int::text, \$4)
            ''',
            parameters: [warehouseId, itemType, refId, refBarcode],
          );
          final balance = double.parse(balResult.first[0].toString());
          if (balance < qty) {
            return _json({
              'error': "Qoldiq yetarli emas. Mavjud: $balance $unit",
            }, status: 409);
          }
        }

        await db.execute(
          '''
          INSERT INTO fh.stock_ledger
            (warehouse_id, item_type, ref_id, ref_barcode, name_snapshot, unit,
             direction, qty, source_type, performed_by, note)
          VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, 'manual', \$9, \$10)
          ''',
          parameters: [
            warehouseId, itemType, refId, refBarcode, nameSnapshot, unit,
            direction, qty, userId, note,
          ],
        );

        return _json({'message': 'Hujjat yozildi'}, status: 201);
      } catch (e) {
        print('transaction xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ---------- STOCK REPORT ----------
    get('/stock', (Request request) async {
      try {
        final warehouseId =
            int.tryParse(request.url.queryParameters['warehouse_id'] ?? '');

        final db = await DatabaseConnection.getConnection();
        final result = await db.execute(
          '''
          SELECT w.id AS warehouse_id, w.name AS warehouse_name, w.type,
                 l.item_type,
                 COALESCE(
                   CASE
                     WHEN l.item_type = 'raw_material' THEN rm.code
                     WHEN l.item_type = 'item' AND l.ref_id IS NOT NULL THEN l.ref_id::text
                     ELSE l.ref_barcode
                   END
                 ) AS ref_key,
                 MAX(l.name_snapshot) AS name,
                 MAX(l.unit) AS unit,
                 SUM(CASE l.direction WHEN 'in' THEN l.qty ELSE -l.qty END) AS balance
          FROM fh.stock_ledger l
          JOIN fh.warehouses w ON w.id = l.warehouse_id
          LEFT JOIN public.raw_materials rm ON rm.id = l.ref_id
          WHERE (\$1::int IS NULL OR w.id = \$1)
          GROUP BY w.id, w.name, w.type, l.item_type, COALESCE(
                   CASE
                     WHEN l.item_type = 'raw_material' THEN rm.code
                     WHEN l.item_type = 'item' AND l.ref_id IS NOT NULL THEN l.ref_id::text
                     ELSE l.ref_barcode
                   END
                 )
          HAVING SUM(CASE l.direction WHEN 'in' THEN l.qty ELSE -l.qty END) > 0
          ORDER BY w.name, l.item_type
          ''',
          parameters: [warehouseId],
        );

        return _json({
          'stock': result.map((row) => {
            'warehouseId': row[0], 'warehouseName': row[1], 'type': row[2],
            'itemType': row[3], 'refKey': row[4], 'name': row[5],
            'unit': row[6], 'balance': row[7]?.toString(),
          }).toList(),
          'total': result.length,
        });
      } catch (e) {
        print('stock xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ---------- TRANSACTION REPORT (Excel) ----------
    get('/reports/transactions', (Request request) async {
      try {
        final from = request.url.queryParameters['from'] ?? '';
        final to = request.url.queryParameters['to'] ?? '';
        final type = request.url.queryParameters['type'] ?? 'all';
        final warehouseId = int.tryParse(request.url.queryParameters['warehouse_id'] ?? '');

        if (from.isEmpty || to.isEmpty) {
          return _json({'error': 'from va to sanalar majburiy (YYYY-MM-DD)'}, status: 400);
        }

        final db = await DatabaseConnection.getConnection();

        var where = 'WHERE l.created_at >= \$1::date AND l.created_at < (\$2::date + INTERVAL \'1 day\')';
        var params = <dynamic>[from, to];
        var idx = 2;

        if (warehouseId != null) {
          idx++;
          where += ' AND l.warehouse_id = \$$idx';
          params.add(warehouseId);
        }
        if (type == 'in' || type == 'out') {
          idx++;
          where += ' AND l.direction = \$$idx';
          params.add(type);
        }

        final result = await db.execute(
          '''
          SELECT l.created_at, w.name AS warehouse_name, l.direction,
                 COALESCE(
                   CASE
                     WHEN l.item_type = 'raw_material' THEN rm.code
                     WHEN l.item_type = 'item' AND l.ref_id IS NOT NULL THEN l.ref_id::text
                     ELSE l.ref_barcode
                   END
                 ) AS ref_key,
                 l.name_snapshot, l.unit, l.qty, l.note, u.username
          FROM fh.stock_ledger l
          JOIN fh.warehouses w ON w.id = l.warehouse_id
          LEFT JOIN fh.users u ON u.id = l.performed_by
          LEFT JOIN public.raw_materials rm ON rm.id = l.ref_id
          $where
          ORDER BY l.created_at DESC
          ''',
          parameters: params,
        );

        final excel = Excel.createExcel();

        if (type == 'all') {
          _buildSheet(excel, 'Kirim', result, 'in', from, to);
          _buildSheet(excel, 'Chiqim', result, 'out', from, to);
          excel.delete(excel.getDefaultSheet()!);
        } else {
          final sheetName = type == 'in' ? 'Kirim' : 'Chiqim';
          _buildSheet(excel, sheetName, result, type, from, to);
          excel.delete(excel.getDefaultSheet()!);
        }

        final bytes = excel.encode();
        if (bytes == null) {
          return _json({'error': 'Excel yaratilmadi'}, status: 500);
        }

        return Response(
          200,
          body: Uint8List.fromList(bytes),
          headers: {
            'Content-Type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            'Content-Disposition': 'attachment; filename="hisobot_${from}_${to}.xlsx"',
          },
        );
      } catch (e) {
        print('report xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ─────────────────────────────────────────────────────────────────────────────
    // PRODUCT ↔ WAREHOUSE ASSIGNMENTS (Many-to-Many)
    // ─────────────────────────────────────────────────────────────────────────────

    get('/product-warehouses', (Request request) async {
      try {
        final db = await DatabaseConnection.getConnection();
        final result = await db.execute(
          'SELECT id, item_type, ref_id, ref_barcode, warehouse_id, created_at '
          'FROM fh.product_warehouses ORDER BY id',
        );
        final list = result.map((r) => {
          'id': r[0], 'itemType': r[1], 'refId': r[2],
          'refBarcode': r[3], 'warehouseId': r[4],
          'createdAt': r[5]?.toString(),
        }).toList();
        return _json({'assignments': list, 'total': list.length});
      } catch (e) {
        print('product-warehouses GET xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    post('/product-warehouses', (Request request) async {
      if (!Policy.canControlWarehouses(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      try {
        final body = await _body(request);
        final itemType = body['item_type'] as String?;
        final refId = body['ref_id'] as int?;
        final refBarcode = body['ref_barcode'] as String?;
        final warehouseIds = body['warehouse_ids'] as List<dynamic>?;
        if (itemType == null || warehouseIds == null || warehouseIds.isEmpty) {
          return _json({'error': 'item_type va warehouse_ids majburiy'}, status: 400);
        }
        final db = await DatabaseConnection.getConnection();
        await db.execute('DELETE FROM fh.product_warehouses WHERE item_type = \$1 '
            'AND COALESCE(ref_id::text, \'\') = COALESCE(\$2::text, \'\') '
            'AND COALESCE(ref_barcode, \'\') = COALESCE(\$3, \'\')',
          parameters: [itemType, refId?.toString(), refBarcode ?? '']);
        for (final wid in warehouseIds) {
          await db.execute(
            'INSERT INTO fh.product_warehouses (item_type, ref_id, ref_barcode, warehouse_id) '
            'VALUES (\$1, \$2, \$3, \$4) ON CONFLICT DO NOTHING',
            parameters: [itemType, refId, refBarcode, wid],
          );
        }
        return _json({'message': 'Omborlar yangilandi', 'count': warehouseIds.length});
      } catch (e) {
        print('product-warehouses POST xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    delete('/product-warehouses', (Request request) async {
      if (!Policy.canControlWarehouses(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      try {
        final body = await _body(request);
        final itemType = body['item_type'] as String?;
        final refId = body['ref_id'] as int?;
        final refBarcode = body['ref_barcode'] as String?;
        if (itemType == null) return _json({'error': 'item_type majburiy'}, status: 400);
        final db = await DatabaseConnection.getConnection();
        await db.execute('DELETE FROM fh.product_warehouses WHERE item_type = \$1 '
            'AND COALESCE(ref_id::text, \'\') = COALESCE(\$2::text, \'\') '
            'AND COALESCE(ref_barcode, \'\') = COALESCE(\$3, \'\')',
          parameters: [itemType, refId?.toString(), refBarcode ?? '']);
        return _json({'message': 'O\'chirildi'});
      } catch (e) {
        print('product-warehouses DELETE xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    get('/product-warehouses/<id>', (Request request, String id) async {
      try {
        final warehouseId = int.tryParse(id);
        if (warehouseId == null) return _json({'error': "Noto'g'ri ID"}, status: 400);
        final db = await DatabaseConnection.getConnection();
        final result = await db.execute(
          'SELECT id, item_type, ref_id, ref_barcode, warehouse_id '
          'FROM fh.product_warehouses WHERE warehouse_id = \$1',
          parameters: [warehouseId],
        );
        final list = result.map((r) => {
          'id': r[0], 'itemType': r[1], 'refId': r[2],
          'refBarcode': r[3], 'warehouseId': r[4],
        }).toList();
        return _json({'assignments': list});
      } catch (e) {
        print('product-warehouses/:id GET xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ─────────────────────────────────────────────────────────────────────────────
    // INTER-WAREHOUSE TRANSFERS
    // ─────────────────────────────────────────────────────────────────────────────

    get('/transfers', (Request request) async {
      try {
        final db = await DatabaseConnection.getConnection();
        final result = await db.execute('''
          SELECT t.id, fw.name AS from_name, tw.name AS to_name,
                 t.status, t.note, u.username, t.created_at, t.completed_at,
                 (SELECT COUNT(*) FROM fh.transfer_items ti WHERE ti.transfer_id = t.id) AS item_count,
                 t.is_sale
          FROM fh.transfers t
          JOIN fh.warehouses fw ON fw.id = t.from_warehouse_id
          JOIN fh.warehouses tw ON tw.id = t.to_warehouse_id
          LEFT JOIN fh.users u ON u.id = t.created_by
          ORDER BY t.created_at DESC LIMIT 100
        ''');
        final list = result.map((r) => {
          'id': r[0], 'fromWarehouse': r[1], 'toWarehouse': r[2],
          'status': r[3], 'note': r[4], 'createdBy': r[5],
          'createdAt': r[6]?.toString(), 'completedAt': r[7]?.toString(),
          'itemCount': r[8], 'isSale': r[9] ?? false,
        }).toList();
        return _json({'transfers': list, 'total': list.length});
      } catch (e) {
        print('transfers GET xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    get('/transfers/<id>', (Request request, String id) async {
      try {
        final transferId = int.tryParse(id);
        if (transferId == null) return _json({'error': "Noto'g'ri ID"}, status: 400);
        final db = await DatabaseConnection.getConnection();
        final info = await db.execute('''
          SELECT t.id, t.from_warehouse_id, fw.name, t.to_warehouse_id, tw.name,
                 t.status, t.note, u.username, t.created_at, t.completed_at, t.is_sale
          FROM fh.transfers t
          JOIN fh.warehouses fw ON fw.id = t.from_warehouse_id
          JOIN fh.warehouses tw ON tw.id = t.to_warehouse_id
          LEFT JOIN fh.users u ON u.id = t.created_by
          WHERE t.id = \$1
        ''', parameters: [transferId]);
        if (info.isEmpty) return _json({'error': 'Topilmadi'}, status: 404);
        final r = info.first;
        final items = await db.execute('''
          SELECT id, item_type, ref_id, ref_barcode, name_snapshot, unit, qty
          FROM fh.transfer_items WHERE transfer_id = \$1 ORDER BY id
        ''', parameters: [transferId]);
        return _json({
          'transfer': {
            'id': r[0], 'fromWarehouseId': r[1], 'fromWarehouse': r[2],
            'toWarehouseId': r[3], 'toWarehouse': r[4],
            'status': r[5], 'note': r[6], 'createdBy': r[7],
            'createdAt': r[8]?.toString(), 'completedAt': r[9]?.toString(),
            'isSale': r[10] ?? false,
          },
          'items': items.map((i) => {
            'id': i[0], 'itemType': i[1], 'refId': i[2],
            'refBarcode': i[3], 'name': i[4], 'unit': i[5], 'qty': i[6]?.toString(),
          }).toList(),
        });
      } catch (e) {
        print('transfers/:id GET xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    post('/transfers', (Request request) async {
      final role = _role(request);
      if (!Policy.canTransactStock(role)) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      try {
        final body = await _body(request);
        final fromId = body['from_warehouse_id'] as int?;
        final toId = body['to_warehouse_id'] as int?;
        final items = body['items'] as List<dynamic>?;
        final note = body['note'] as String?;
        if (fromId == null || toId == null || items == null || items.isEmpty) {
          return _json({'error': 'from_warehouse_id, to_warehouse_id, items majburiy'}, status: 400);
        }
        if (fromId == toId) return _json({'error': 'Jo\'natuvchi va qabul qiluvchi ombor bir xil'}, status: 400);
        final userId = _uid(request);
        final db = await DatabaseConnection.getConnection();

        // ── Imkoniyatga asoslangan oqim nazorati (transfer) ──
        final whTypesRow = await db.execute(
          'SELECT id, type, can_transfer FROM fh.warehouses WHERE id IN (\$1, \$2)',
          parameters: [fromId, toId],
        );
        final Map<int, String?> whTypes = {
          for (final r in whTypesRow) r[0] as int: r[1] as String?,
        };
        final Map<int, bool> whCanTransfer = {
          for (final r in whTypesRow) r[0] as int: (r[2] ?? false) == true,
        };
        final fromType = whTypes[fromId];
        final toType = whTypes[toId];
        if (fromType == null || toType == null) {
          return _json({'error': 'Ombor topilmadi'}, status: 404);
        }
        // Jo'natuvchi ombor uchun transfer imkoniyati yoqilgan bo'lishi kerak.
        if (!(whCanTransfer[fromId] ?? false)) {
          return _json({
            'error': 'Bu ombor uchun transfer imkoniyati yoqilmagan',
          }, status: 403);
        }
        // Ruxsat etilgan yo'nalish (warehouse_transfer_routes) mavjud bo'lishi shart.
        final route = await db.execute(
          'SELECT 1 FROM fh.warehouse_transfer_routes '
          'WHERE from_warehouse_id = \$1 AND to_warehouse_id = \$2',
          parameters: [fromId, toId],
        );
        if (route.isEmpty) {
          return _json({
            'error': 'Bu yo\'nalishga transfer ruxsat etilmagan. Ombor sozlamalarida transfer yo\'nalishini qo\'shing',
          }, status: 403);
        }
        final bool isSale = toType == 'dealer';

        await db.execute('BEGIN');
        try {
          final tr = await db.execute(
            'INSERT INTO fh.transfers (from_warehouse_id, to_warehouse_id, note, created_by, is_sale) '
            'VALUES (\$1, \$2, \$3, \$4, \$5) RETURNING id',
            parameters: [fromId, toId, note, userId, isSale],
          );
          final transferId = tr.first[0];

          for (final item in items) {
            final itemType = item['item_type'] as String?;
            final refId = item['ref_id'] as int?;
            final refBarcode = item['ref_barcode'] as String?;
            final nameSnapshot = item['name'] as String?;
            final unit = item['unit'] as String?;
            final qty = (item['qty'] as num?)?.toDouble();
            if (itemType == null || qty == null || qty <= 0) continue;

            await db.execute(
              'INSERT INTO fh.transfer_items (transfer_id, item_type, ref_id, ref_barcode, name_snapshot, unit, qty) '
              'VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7)',
              parameters: [transferId, itemType, refId, refBarcode, nameSnapshot, unit, qty],
            );

            if (role == AppRoles.warehouseKeeper && userId != null) {
              final allowedFrom = await db.execute(
                'SELECT 1 FROM fh.user_warehouses WHERE user_id = \$1 AND warehouse_id = \$2',
                parameters: [userId, fromId],
              );
              if (allowedFrom.isEmpty) {
                await db.execute('ROLLBACK');
                return _json({'error': 'Jo\'natuvchi omborga ruxsat yoq'}, status: 403);
              }
            }

            await db.execute(
              'INSERT INTO fh.stock_ledger (warehouse_id, item_type, ref_id, ref_barcode, name_snapshot, unit, direction, qty, source_type, source_ref, performed_by, note) '
              'VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \'out\', \$7, \'transfer_out\', \$8::text, \$9, \$10)',
              parameters: [fromId, itemType, refId, refBarcode, nameSnapshot, unit, qty, transferId, userId, 'Transfer #$transferId'],
            );

            await db.execute(
              'INSERT INTO fh.stock_ledger (warehouse_id, item_type, ref_id, ref_barcode, name_snapshot, unit, direction, qty, source_type, source_ref, performed_by, note) '
              'VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \'in\', \$7, \'transfer_in\', \$8::text, \$9, \$10)',
              parameters: [toId, itemType, refId, refBarcode, nameSnapshot, unit, qty, transferId, userId, 'Transfer #$transferId'],
            );
          }

          await db.execute(
            'UPDATE fh.transfers SET status = \'completed\', completed_at = NOW() WHERE id = \$1',
            parameters: [transferId],
          );
          await db.execute('COMMIT');
          return _json({'message': 'Transfer bajarildi', 'transfer_id': transferId}, status: 201);
        } catch (e) {
          await db.execute('ROLLBACK');
          rethrow;
        }
      } catch (e) {
        print('transfers POST xato: $e');
        return _json({'error': "Transfer bajarilmadi: $e"}, status: 500);
      }
    });

    // ─────────────────────────────────────────────────────────────────────────────
    // WAREHOUSE REPORT (detailed per-warehouse)
    // ─────────────────────────────────────────────────────────────────────────────

    get('/reports/warehouse', (Request request) async {
      try {
        final warehouseId = int.tryParse(request.url.queryParameters['warehouse_id'] ?? '');
        final from = request.url.queryParameters['from'] ?? '';
        final to = request.url.queryParameters['to'] ?? '';
        if (warehouseId == null) return _json({'error': 'warehouse_id majburiy'}, status: 400);

        final db = await DatabaseConnection.getConnection();

        final whResult = await db.execute(
          'SELECT id, name, type FROM fh.warehouses WHERE id = \$1',
          parameters: [warehouseId],
        );
        if (whResult.isEmpty) return _json({'error': 'Ombor topilmadi'}, status: 404);
        final wh = whResult.first;

        final currentBalance = await db.execute(
          '''
          SELECT COALESCE(
                   CASE
                     WHEN l.item_type = \'raw_material\' THEN rm.code
                     WHEN l.item_type = \'item\' AND l.ref_id IS NOT NULL THEN l.ref_id::text
                     ELSE l.ref_barcode
                   END
                 ) AS ref_key,
                 MAX(l.name_snapshot) AS name, MAX(l.unit) AS unit, l.item_type,
                 SUM(CASE l.direction WHEN \'in\' THEN l.qty ELSE -l.qty END) AS balance
          FROM fh.stock_ledger l
          LEFT JOIN public.raw_materials rm ON rm.id = l.ref_id
          WHERE l.warehouse_id = \$1
          GROUP BY l.item_type, COALESCE(
                   CASE
                     WHEN l.item_type = \'raw_material\' THEN rm.code
                     WHEN l.item_type = \'item\' AND l.ref_id IS NOT NULL THEN l.ref_id::text
                     ELSE l.ref_barcode
                   END
                 )
          HAVING SUM(CASE l.direction WHEN \'in\' THEN l.qty ELSE -l.qty END) <> 0
          ORDER BY l.item_type, name
          ''',
          parameters: [warehouseId],
        );

        var dateFilter = '';
        var params = <dynamic>[warehouseId];
        var idx = 1;
        if (from.isNotEmpty && to.isNotEmpty) {
          idx++;
          dateFilter = 'AND l.created_at >= \$$idx::date AND l.created_at < (\$${idx+1}::date + INTERVAL \'1 day\')';
          params.addAll([from, to]);
          idx += 1;
        }

        final incomeResult = await db.execute(
          'SELECT COALESCE(SUM(l.qty), 0) FROM fh.stock_ledger l WHERE l.warehouse_id = \$1 AND l.direction = \'in\' $dateFilter',
          parameters: params,
        );
        final expenseResult = await db.execute(
          'SELECT COALESCE(SUM(l.qty), 0) FROM fh.stock_ledger l WHERE l.warehouse_id = \$1 AND l.direction = \'out\' $dateFilter',
          parameters: params,
        );

        final transferOut = await db.execute(
          'SELECT COALESCE(SUM(ti.qty), 0) FROM fh.transfer_items ti '
          'JOIN fh.transfers t ON t.id = ti.transfer_id '
          'WHERE t.from_warehouse_id = \$1 AND t.status = \'completed\' $dateFilter',
          parameters: params,
        );
        final transferIn = await db.execute(
          'SELECT COALESCE(SUM(ti.qty), 0) FROM fh.transfer_items ti '
          'JOIN fh.transfers t ON t.id = ti.transfer_id '
          'WHERE t.to_warehouse_id = \$1 AND t.status = \'completed\' $dateFilter',
          parameters: params,
        );

        return _json({
          'warehouse': {'id': wh[0], 'name': wh[1], 'type': wh[2]},
          'balance': currentBalance.map((r) => {
            'refKey': r[0], 'name': r[1], 'unit': r[2], 'itemType': r[3],
            'balance': r[4]?.toString(),
          }).toList(),
          'summary': {
            'totalIncome': incomeResult.first[0]?.toString(),
            'totalExpense': expenseResult.first[0]?.toString(),
            'transferOut': transferOut.first[0]?.toString(),
            'transferIn': transferIn.first[0]?.toString(),
          },
        });
      } catch (e) {
        print('reports/warehouse xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ---------- PLANS ----------
    get('/plans', (Request request) async {
      try {
        final status = request.url.queryParameters['status'];
        final db = await DatabaseConnection.getConnection();
        final result = await db.execute(
          '''
          SELECT p.id, p.title, p.description, p.product_barcode, pr.name AS product_name,
                 p.order_id, p.target_qty, p.produced_qty, p.due_date, p.status,
                 u.username AS created_by_name, p.created_at
          FROM fh.plans p
          LEFT JOIN public.products pr ON pr.barcode = p.product_barcode
          LEFT JOIN fh.users u ON u.id = p.created_by
          WHERE (\$1::varchar IS NULL OR p.status = \$1)
          ORDER BY
            CASE p.status WHEN 'in_progress' THEN 0 WHEN 'planned' THEN 1 ELSE 2 END,
            p.created_at DESC
          LIMIT 200
          ''',
          parameters: [status],
        );

        return _json({
          'plans': result.map((row) => {
            'id': row[0], 'title': row[1], 'description': row[2],
            'barcode': row[3], 'productName': row[4], 'orderId': row[5],
            'targetQty': row[6], 'producedQty': row[7],
            'dueDate': row[8]?.toString(), 'status': row[9],
            'createdBy': row[10], 'createdAt': row[11]?.toString(),
          }).toList(),
        });
      } catch (e) {
        print('plans GET xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    post('/plans', (Request request) async {
      if (!Policy.canPlan(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      try {
        final body = await _body(request);
        final title = body['title'] as String?;
        final description = body['description'] as String?;
        final barcode = body['barcode'] as String?;
        final targetQty = (body['target_qty'] as num?)?.toInt();
        final orderId = body['order_id'] as int?;
        final dueDate = body['due_date'] as String?;

        if (title == null ||
            title.trim().isEmpty ||
            targetQty == null ||
            targetQty <= 0) {
          return _json(
            {'error': 'title va target_qty (>0) majburiy'},
            status: 400,
          );
        }

        final db = await DatabaseConnection.getConnection();
        await db.execute(
          '''
          INSERT INTO fh.plans
            (title, description, product_barcode, order_id, target_qty, due_date, created_by)
          VALUES (\$1, \$2, \$3, \$4, \$5, \$6::date, \$7)
          ''',
          parameters: [
            title.trim(), description, barcode, orderId, targetQty, dueDate, _uid(request),
          ],
        );

        return _json({'message': 'Reja yaratildi'}, status: 201);
      } catch (_) {
        return _json({'error': 'Xatolik'}, status: 400);
      }
    });

    put('/plans/<id>', (Request request, String id) async {
      final planId = int.tryParse(id);
      if (planId == null) return _json({'error': "Noto'g'ri ID"}, status: 400);

      if (!Policy.canPlan(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }

      try {
        final body = await _body(request);
        final db = await DatabaseConnection.getConnection();

        final hasFields = body.containsKey('title') || body.containsKey('target_qty') ||
            body.containsKey('due_date') || body.containsKey('barcode') ||
            body.containsKey('description');

        if (hasFields) {
          final title = body['title'] as String?;
          final description = body['description'] as String?;
          final barcode = body['barcode'] as String?;
          final targetQty = (body['target_qty'] as num?)?.toInt();
          final dueDate = body['due_date'] as String?;

          final sets = <String>[];
          final params = <dynamic>[];
          var idx = 1;
          if (title != null) { sets.add('title = \$$idx'); params.add(title.trim()); idx++; }
          if (description != null) { sets.add('description = \$$idx'); params.add(description); idx++; }
          if (barcode != null) { sets.add('product_barcode = \$$idx'); params.add(barcode); idx++; }
          if (targetQty != null && targetQty > 0) { sets.add('target_qty = \$$idx'); params.add(targetQty); idx++; }
          if (dueDate != null) { sets.add('due_date = \$$idx::date'); params.add(dueDate); idx++; }

          if (sets.isEmpty) {
            return _json({'error': 'O\'zgartirish ko\'rsatilmadi'}, status: 400);
          }

          params.add(planId);
          final result = await db.execute(
            'UPDATE fh.plans SET ${sets.join(", ")} WHERE id = \$$idx RETURNING id',
            parameters: params,
          );
          if (result.isEmpty) {
            return _json({'error': 'Reja topilmadi'}, status: 404);
          }
          return _json({'message': 'Yangilandi'});
        }

        final status = body['status'] as String?;
        final allowed = ['planned', 'in_progress', 'done', 'cancelled'];

        if (status == null || !allowed.contains(status)) {
          return _json({'error': 'status: $allowed'}, status: 400);
        }

        final result = await db.execute(
          'UPDATE fh.plans SET status = \$2 WHERE id = \$1 RETURNING id',
          parameters: [planId, status],
        );
        if (result.isEmpty) {
          return _json({'error': 'Reja topilmadi'}, status: 404);
        }

        return _json({'message': 'Yangilandi'});
      } catch (e) {
        print('plans/:id xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ---------- SUPPLIER ORDERS ----------
    get('/supplier-orders', (Request request) async {
      try {
        final status = request.url.queryParameters['status'];
        final db = await DatabaseConnection.getConnection();
        final result = await db.execute(
          '''
          SELECT s.id, s.supplier_name, s.raw_material_id, rm.name AS material_name,
                 s.qty, s.unit, s.ordered_at, s.expected_at, s.received_at,
                 s.status,
                 CASE
                   WHEN s.status IN ('ordered','in_transit') AND s.expected_at < CURRENT_DATE
                     THEN true ELSE false
                 END AS is_late
          FROM fh.supplier_orders s
          LEFT JOIN public.raw_materials rm ON rm.id = s.raw_material_id
          WHERE (\$1::varchar IS NULL OR s.status = \$1)
          ORDER BY s.status, s.expected_at NULLS LAST, s.id DESC
          LIMIT 200
          ''',
          parameters: [status],
        );

        return _json({
          'orders': result.map((row) => {
            'id': row[0], 'supplierName': row[1], 'rawMaterialId': row[2],
            'materialName': row[3], 'qty': row[4]?.toString(), 'unit': row[5],
            'orderedAt': row[6]?.toString(), 'expectedAt': row[7]?.toString(),
            'receivedAt': row[8]?.toString(), 'status': row[9], 'isLate': row[10],
          }).toList(),
        });
      } catch (e) {
        print('supplier-orders GET xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    post('/supplier-orders', (Request request) async {
      if (!Policy.canControlWarehouses(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      try {
        final body = await _body(request);
        final supplierName = body['supplier_name'] as String?;
        final rawMaterialId = body['raw_material_id'] as int?;
        final qty = (body['qty'] as num?)?.toDouble();
        final unit = body['unit'] as String? ?? 'kg';
        final expectedAt = body['expected_at'] as String?;

        if (supplierName == null || rawMaterialId == null || qty == null || qty <= 0) {
          return _json({
            'error': 'supplier_name, raw_material_id va qty (>0) majburiy',
          }, status: 400);
        }

        final db = await DatabaseConnection.getConnection();
        await db.execute(
          '''
          INSERT INTO fh.supplier_orders
            (supplier_name, raw_material_id, qty, unit, expected_at, created_by)
          VALUES (\$1, \$2, \$3, \$4, \$5::date, \$6)
          ''',
          parameters: [supplierName, rawMaterialId, qty, unit, expectedAt, _uid(request)],
        );

        return _json({'message': "Buyurtma qo'shildi"}, status: 201);
      } catch (_) {
        return _json({'error': 'Xatolik'}, status: 400);
      }
    });

    put('/supplier-orders/<id>', (Request request, String id) async {
      final orderId = int.tryParse(id);
      if (orderId == null) return _json({'error': "Noto'g'ri ID"}, status: 400);

      if (!Policy.canControlWarehouses(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }

      try {
        final body = await _body(request);
        final status = body['status'] as String?;
        final allowed = ['ordered', 'in_transit', 'received', 'cancelled'];

        if (status == null || !allowed.contains(status)) {
          return _json({'error': 'status: $allowed'}, status: 400);
        }

        final db = await DatabaseConnection.getConnection();
        final result = await db.execute(
          '''
          UPDATE fh.supplier_orders
          SET status = \$2,
              received_at = CASE WHEN \$2 = 'received' THEN CURRENT_DATE ELSE received_at END
          WHERE id = \$1
          RETURNING id
          ''',
          parameters: [orderId, status],
        );
        if (result.isEmpty) {
          return _json({'error': 'Topilmadi'}, status: 404);
        }

        return _json({'message': 'Yangilandi'});
      } catch (e) {
        print('supplier-orders/:id xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ---------- PRODUCTION (norms/start oldin, umumiy <id> keyin) ----------
    get('/production/norms/<barcode>', (Request request, String barcode) async {
      try {
        final db = await DatabaseConnection.getConnection();
        final result = await db.execute(
          '''
          SELECT rm.id, rm.name, rm.code, pm.grams_per_unit,
            COALESCE((
              SELECT SUM(CASE l.direction WHEN 'in' THEN l.qty ELSE -l.qty END)
              FROM fh.stock_ledger l
              WHERE l.item_type = 'raw_material' AND l.ref_id = rm.id
            ), 0) AS total_stock
          FROM public.product_materials pm
          JOIN public.raw_materials rm ON rm.id = pm.raw_material_id
          WHERE pm.product_barcode = \$1 AND pm.is_active
          ''',
          parameters: [barcode],
        );

        return _json({
          'norms': result.map((row) => {
            'rawMaterialId': row[0], 'name': row[1], 'code': row[2],
            'gramsPerUnit': row[3]?.toString(), 'totalStock': row[4]?.toString(),
          }).toList(),
        });
      } catch (e) {
        print('norms xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    post('/production/start', (Request request) async {
      if (!Policy.canPlan(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }

      try {
        final body = await _body(request);
        final barcode = body['barcode'] as String?;
        final qty = (body['qty'] as num?)?.toInt();
        final rawWarehouseId = body['raw_warehouse_id'] as int?;
        final finishedWarehouseId = body['finished_warehouse_id'] as int?;
        final planId = body['plan_id'] as int?;
        final orderId = body['order_id'] as int?;

        if (barcode == null ||
            qty == null ||
            qty <= 0 ||
            rawWarehouseId == null ||
            finishedWarehouseId == null) {
          return _json({
            'error': 'barcode, qty, raw_warehouse_id, finished_warehouse_id majburiy',
          }, status: 400);
        }

        final db = await DatabaseConnection.getConnection();

        final product = await db.execute(
          'SELECT name FROM public.products WHERE barcode = \$1',
          parameters: [barcode],
        );
        if (product.isEmpty) {
          return _json({'error': 'Mahsulot topilmadi'}, status: 404);
        }
        final productName = product.first[0] as String;

        final norms = await db.execute(
          '''
          SELECT rm.id, rm.name, rm.unit, pm.grams_per_unit
          FROM public.product_materials pm
          JOIN public.raw_materials rm ON rm.id = pm.raw_material_id
          WHERE pm.product_barcode = \$1 AND pm.is_active
          ''',
          parameters: [barcode],
        );
        await db.execute('BEGIN');
        try {
          for (final norm in norms) {
            final rawId = norm[0] as int;
            final grams = double.parse(norm[3].toString());
            final needKg = grams * qty / 1000.0;

            final balResult = await db.execute(
              '''
              SELECT COALESCE(SUM(CASE direction WHEN 'in' THEN qty ELSE -qty END), 0)
              FROM fh.stock_ledger
              WHERE warehouse_id = \$1 AND item_type = 'raw_material' AND ref_id = \$2
              FOR UPDATE
              ''',
              parameters: [rawWarehouseId, rawId],
            );
            final balance = double.parse(balResult.first[0].toString());

            if (balance < needKg) {
              await db.execute('ROLLBACK');
              return _json({
                'error':
                    "Xom ashyo yetarli emas: ${norm[1]} â€” kerak ${needKg.toStringAsFixed(3)} ${norm[2]}, mavjud $balance",
              }, status: 409);
            }

            await db.execute(
              '''
              INSERT INTO fh.stock_ledger
                (warehouse_id, item_type, ref_id, name_snapshot, unit,
                 direction, qty, source_type, source_ref, performed_by)
              VALUES (\$1, 'raw_material', \$2, \$3, \$4, 'out', \$5, 'production_out', \$6, \$7)
              ''',
              parameters: [
                rawWarehouseId, rawId, norm[1], norm[2],
                needKg, barcode, _uid(request),
              ],
            );
          }

          final batchResult = await db.execute(
            '''
            INSERT INTO fh.production_batches
              (product_barcode, plan_id, order_id, planned_qty, started_by)
            VALUES (\$1, \$2, \$3, \$4, \$5)
            RETURNING id
            ''',
            parameters: [barcode, planId, orderId, qty, _uid(request)],
          );
          final batchId = batchResult.first[0];

          if (planId != null) {
            await db.execute(
              "UPDATE fh.plans SET status = 'in_progress' WHERE id = \$1 AND status = 'planned'",
              parameters: [planId],
            );
          }

          await db.execute('COMMIT');

          return _json({
            'message': 'Ishlab chiqarish boshlandi',
            'batchId': batchId,
            'product': productName,
            'plannedQty': qty,
            'rawConsumed': norms.length,
          }, status: 201);
        } catch (_) {
          await db.execute('ROLLBACK');
          rethrow;
        }
      } catch (e) {
        print('production/start xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ─────────────────────────────────────────────────────────────────────────
    //  UNIFIED ITEMS CATALOG (raw, semi, finished, packaging)
    // ─────────────────────────────────────────────────────────────────────────
    get('/items', (Request request) async {
      try {
        final db = await DatabaseConnection.getConnection();
        final result = await db.execute(
          "SELECT id, name, item_type, code, unit, content_ml FROM fh.items WHERE is_active ORDER BY item_type, name"
        );
        final list = result.map((r) => {
          'id': r[0], 'name': r[1], 'itemType': r[2], 'code': r[3],
          'unit': r[4], 'contentMl': r[5]?.toString(),
        }).toList();
        return _json({'items': list});
      } catch (e) {
        print('items GET xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    post('/items', (Request request) async {
      if (!Policy.canControlWarehouses(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      try {
        final body = await _body(request);
        final name = body['name'] as String?;
        final itemType = body['item_type'] as String?;
        final code = body['code'] as String?;
        final unit = body['unit'] as String? ?? 'dona';
        final contentMl = body['content_ml'] as num?;
        if (name == null || name.trim().isEmpty || itemType == null) {
          return _json({'error': 'name va item_type majburiy'}, status: 400);
        }
        final db = await DatabaseConnection.getConnection();
        final result = await db.execute(
          "INSERT INTO fh.items (name, item_type, code, unit, content_ml) VALUES (\$1, \$2, \$3, \$4, \$5) RETURNING id, name, item_type, code, unit",
          parameters: [name.trim(), itemType, code, unit, contentMl?.toString()],
        );
        final r = result.first;
        return _json({
          'message': "Mahsulot yaratildi",
          'item': {'id': r[0], 'name': r[1], 'itemType': r[2], 'code': r[3], 'unit': r[4]},
        }, status: 201);
      } catch (e) {
        print('items POST xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ─────────────────────────────────────────────────────────────────────────
    //  BOM / RECEPT (retsept) CRUD — stage: mixing | packaging
    // ─────────────────────────────────────────────────────────────────────────
    get('/boms', (Request request) async {
      try {
        final db = await DatabaseConnection.getConnection();
        final result = await db.execute('''
          SELECT b.id, b.name, b.stage,
                 i.id AS out_item_id, i.name AS out_name, i.unit AS out_unit,
                 b.output_qty_per_batch, b.output_unit
          FROM fh.boms b
          LEFT JOIN fh.items i ON i.id = b.output_item_id
          WHERE b.is_active
          ORDER BY b.stage, b.name
        ''');
        final list = result.map((r) => {
          'id': r[0], 'name': r[1], 'stage': r[2],
          'outputItemId': r[3], 'outputName': r[4], 'outputUnit': r[5],
          'outputQtyPerBatch': r[6]?.toString(), 'outputUnitLabel': r[7],
        }).toList();
        return _json({'boms': list});
      } catch (e) {
        print('boms GET xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    get('/boms/<id>', (Request request, String id) async {
      try {
        final bomId = int.tryParse(id);
        if (bomId == null) return _json({'error': "Noto'g'ri ID"}, status: 400);
        final db = await DatabaseConnection.getConnection();
        final bom = await db.execute(
          'SELECT id, name, stage, output_item_id, output_qty_per_batch, output_unit FROM fh.boms WHERE id = \$1',
          parameters: [bomId],
        );
        if (bom.isEmpty) return _json({'error': 'Retsept topilmadi'}, status: 404);
        final items = await db.execute(
          'SELECT item_type, ref_id, ref_barcode, name_snapshot, unit, qty FROM fh.bom_items WHERE bom_id = \$1 ORDER BY id',
          parameters: [bomId],
        );
        final r = bom.first;
        return _json({
          'bom': {
            'id': r[0], 'name': r[1], 'stage': r[2], 'outputItemId': r[3],
            'outputQty': r[4]?.toString(), 'outputUnit': r[5],
          },
          'items': items.map((i) => {
            'itemType': i[0], 'refId': i[1], 'refBarcode': i[2],
            'name': i[3], 'unit': i[4], 'qty': i[5]?.toString(),
          }).toList(),
        });
      } catch (e) {
        print('boms/<id> xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    post('/boms', (Request request) async {
      if (!Policy.canControlWarehouses(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      try {
        final body = await _body(request);
        final name = body['name'] as String?;
        final stage = body['stage'] as String?;
        final outputItemId = body['output_item_id'] as int?;
        final outputQty = (body['output_qty'] as num?)?.toDouble();
        final outputUnit = body['output_unit'] as String? ?? 'dona';
        final items = body['items'] as List<dynamic>?;
        if (name == null || name.trim().isEmpty ||
            !['mixing', 'packaging'].contains(stage) ||
            outputItemId == null || outputQty == null || outputQty <= 0 ||
            items == null || items.isEmpty) {
          return _json({
            'error': 'name, stage, output_item_id, output_qty (>0), items majburiy'
          }, status: 400);
        }
        final db = await DatabaseConnection.getConnection();
        await db.execute('BEGIN');
        try {
          final bomResult = await db.execute(
            'INSERT INTO fh.boms (name, stage, output_item_id, output_qty_per_batch, output_unit) '
            'VALUES (\$1, \$2, \$3, \$4, \$5) RETURNING id',
            parameters: [name.trim(), stage, outputItemId, outputQty, outputUnit],
          );
          final bomId = bomResult.first[0];
          for (final it in items) {
            final itemType = it['item_type'] as String?;
            final refId = it['ref_id'] as int?;
            final refBarcode = it['ref_barcode'] as String?;
            final nameSnapshot = it['name'] as String? ?? '';
            final unit = it['unit'] as String? ?? 'dona';
            final qty = (it['qty'] as num?)?.toDouble();
            if (itemType == null || qty == null || qty <= 0) continue;
            await db.execute(
              'INSERT INTO fh.bom_items (bom_id, item_type, ref_id, ref_barcode, name_snapshot, unit, qty) '
              'VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7)',
              parameters: [bomId, itemType, refId, refBarcode, nameSnapshot, unit, qty],
            );
          }
          await db.execute('COMMIT');
          return _json({'message': 'Retsept yaratildi', 'bomId': bomId}, status: 201);
        } catch (_) {
          await db.execute('ROLLBACK');
          rethrow;
        }
      } catch (e) {
        print('boms POST xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    put('/boms/<id>', (Request request, String id) async {
      if (!Policy.canControlWarehouses(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      final bomId = int.tryParse(id);
      if (bomId == null) return _json({'error': "Noto'g'ri ID"}, status: 400);
      try {
        final body = await _body(request);
        final active = body['is_active'] as bool?;
        final name = body['name'] as String?;
        final outputQty = (body['output_qty'] as num?)?.toDouble();
        if (active != null) {
          final db = await DatabaseConnection.getConnection();
          await db.execute('UPDATE fh.boms SET is_active = \$1 WHERE id = \$2',
            parameters: [active, bomId]);
          return _json({'message': 'Yangilandi'});
        }
        if (name != null || outputQty != null) {
          final db = await DatabaseConnection.getConnection();
          if (name != null) {
            await db.execute('UPDATE fh.boms SET name = \$1 WHERE id = \$2',
              parameters: [name, bomId]);
          }
          if (outputQty != null) {
            await db.execute('UPDATE fh.boms SET output_qty_per_batch = \$1 WHERE id = \$2',
              parameters: [outputQty, bomId]);
          }
          return _json({'message': 'Yangilandi'});
        }
        return _json({'error': 'Yangilanadigan maydon topilmadi'}, status: 400);
      } catch (e) {
        print('boms/<id> PUT xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ─────────────────────────────────────────────────────────────────────────
    //  MULTI-STAGE PRODUCTION via BOM (mixing + packaging)
    // ─────────────────────────────────────────────────────────────────────────
    // POST /production/bom/start
    //   body: { bom_id, batches, source_warehouse_id, dest_warehouse_id, note? }
    //   Consumes BOM items from source_warehouse_id and inserts output into
    //   dest_warehouse_id. Uses stock_ledger 'production_out' + 'production_in'.
    post('/production/bom/start', (Request request) async {
      if (!Policy.canPlan(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      try {
        final body = await _body(request);
        final bomId = body['bom_id'] as int?;
        final batches = (body['batches'] as num?)?.toInt();
        final sourceWarehouseId = body['source_warehouse_id'] as int?;
        final destWarehouseId = body['dest_warehouse_id'] as int?;
        final note = body['note'] as String?;
        if (bomId == null || batches == null || batches <= 0 ||
            sourceWarehouseId == null || destWarehouseId == null) {
          return _json({
            'error': 'bom_id, batches (>0), source_warehouse_id, dest_warehouse_id majburiy'
          }, status: 400);
        }

        final db = await DatabaseConnection.getConnection();

        final bom = await db.execute(
          'SELECT id, name, stage, output_item_id, output_qty_per_batch, output_unit FROM fh.boms WHERE id = \$1 AND is_active',
          parameters: [bomId],
        );
        if (bom.isEmpty) return _json({'error': 'Retsept topilmadi'}, status: 404);
        final bomRow = bom.first;
        final bomName = bomRow[1] as String;
        final stage = bomRow[2] as String;
        final outputItemId = bomRow[3] as int?;
        final outputQtyPerBatch = double.parse(bomRow[4].toString());
        final outputUnit = bomRow[5] as String? ?? 'dona';

        final outItem = await db.execute(
          'SELECT name, unit FROM fh.items WHERE id = \$1',
          parameters: [outputItemId],
        );
        if (outItem.isEmpty) return _json({'error': 'Chiqish mahsuloti topilmadi'}, status: 404);
        final outName = outItem.first[0] as String;
        final outUnit = outItem.first[1] as String? ?? outputUnit;

        final bomItems = await db.execute(
          'SELECT item_type, ref_id, ref_barcode, name_snapshot, unit, qty FROM fh.bom_items WHERE bom_id = \$1 ORDER BY id',
          parameters: [bomId],
        );
        if (bomItems.isEmpty) return _json({'error': 'Retsept bo\'sh'}, status: 400);

        final totalOutQty = outputQtyPerBatch * batches;

        await db.execute('BEGIN');
        try {
          // 1) Consume each BOM item (multiply per-batch qty by batch count)
          for (final item in bomItems) {
            final itemType = item[0] as String;
            final refId = item[1] as int?;
            final refBarcode = item[2] as String?;
            final nameSnapshot = item[3] as String? ?? '';
            final unit = item[4] as String? ?? 'dona';
            final perBatch = double.parse(item[5].toString());
            final needQty = perBatch * batches;

            final balResult = await db.execute(
              '''
              SELECT COALESCE(SUM(CASE direction WHEN 'in' THEN qty ELSE -qty END), 0)
              FROM fh.stock_ledger
              WHERE warehouse_id = \$1 AND item_type = \$2
                AND (\$3::int IS NULL OR ref_id = \$3)
                AND (\$4::text IS NULL OR ref_barcode = \$4)
              FOR UPDATE
              ''',
              parameters: [sourceWarehouseId, itemType, refId, refBarcode],
            );
            final balance = double.parse(balResult.first[0].toString());
            if (balance < needQty - 0.0001) {
              await db.execute('ROLLBACK');
              return _json({
                'error': "Yetarli emas: $nameSnapshot — kerak ${needQty.toStringAsFixed(3)} $unit, mavjud ${balance.toStringAsFixed(3)}",
              }, status: 409);
            }
            await db.execute(
              '''
              INSERT INTO fh.stock_ledger
                (warehouse_id, item_type, ref_id, ref_barcode, name_snapshot, unit,
                 direction, qty, source_type, source_ref, performed_by, note)
              VALUES (\$1, \$2, \$3, \$4, \$5, \$6, 'out', \$7, 'production_out', \$8, \$9, \$10)
              ''',
              parameters: [
                sourceWarehouseId, itemType, refId, refBarcode, nameSnapshot, unit,
                needQty, '$stage:$bomId', _uid(request),
                note ?? '$bomName ($batches x)',
              ],
            );
          }

          // 2) Insert output into dest warehouse
          await db.execute(
            '''
            INSERT INTO fh.stock_ledger
              (warehouse_id, item_type, ref_id, ref_barcode, name_snapshot, unit,
               direction, qty, source_type, source_ref, performed_by, note)
            VALUES (\$1, 'item', \$2, NULL, \$3, \$4, 'in', \$5, 'production_in', \$6, \$7, \$8)
            ''',
            parameters: [
              destWarehouseId, outputItemId, outName, outUnit,
              totalOutQty, '$stage:$bomId', _uid(request),
              note ?? '$bomName ($batches x)',
            ],
          );

          // 3) Record production batch
          final batchResult = await db.execute(
            '''
            INSERT INTO fh.production_batches
              (product_barcode, bom_id, stage, planned_qty, produced_qty, status,
               source_warehouse_id, dest_warehouse_id, started_by, completed_at)
            VALUES (\$1, \$2, \$3, \$4, \$4, 'completed', \$5, \$6, \$7, now())
            RETURNING id
            ''',
            parameters: [
              outName, bomId, stage, batches,
              sourceWarehouseId, destWarehouseId, _uid(request),
            ],
          );
          final batchId = batchResult.first[0];

          await db.execute('COMMIT');
          return _json({
            'message': 'Ishlab chiqarish bajarildi',
            'batchId': batchId,
            'stage': stage,
            'output': outName,
            'outputQty': totalOutQty,
            'outputUnit': outUnit,
          }, status: 201);
        } catch (_) {
          await db.execute('ROLLBACK');
          rethrow;
        }
      } catch (e) {
        print('production/bom/start xato: $e');
        return _json({'error': 'Server xatosi: $e'}, status: 500);
      }
    });

    // ─────────────────────────────────────────────────────────────────────────
    //  LOSS / WRITE-OFF
    // ─────────────────────────────────────────────────────────────────────────
    // POST /stock/write-off
    //   body: { warehouse_id, item_type, ref_id?, ref_barcode?, name?, unit?, qty, reason, note? }
    post('/stock/write-off', (Request request) async {
      if (!Policy.canTransactStock(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      try {
        final body = await _body(request);
        final warehouseId = body['warehouse_id'] as int?;
        final itemType = body['item_type'] as String?;
        final refId = body['ref_id'] as int?;
        final refBarcode = body['ref_barcode'] as String?;
        final name = body['name'] as String?;
        final unit = body['unit'] as String? ?? 'dona';
        final qty = (body['qty'] as num?)?.toDouble();
        final reason = body['reason'] as String?;
        final note = body['note'] as String?;
        if (warehouseId == null || itemType == null || qty == null || qty <= 0 ||
            reason == null || reason.trim().isEmpty) {
          return _json({
            'error': 'warehouse_id, item_type, qty (>0), reason majburiy'
          }, status: 400);
        }

        final db = await DatabaseConnection.getConnection();
        final whRow = await db.execute(
          'SELECT id FROM fh.warehouses WHERE id = \$1 AND is_active',
          parameters: [warehouseId],
        );
        if (whRow.isEmpty) return _json({'error': 'Ombor topilmadi'}, status: 404);

        final balResult = await db.execute(
          '''
          SELECT COALESCE(SUM(CASE direction WHEN 'in' THEN qty ELSE -qty END), 0)
          FROM fh.stock_ledger
          WHERE warehouse_id = \$1 AND item_type = \$2
            AND (\$3::int IS NULL OR ref_id = \$3)
            AND (\$4::text IS NULL OR ref_barcode = \$4)
          FOR UPDATE
          ''',
          parameters: [warehouseId, itemType, refId, refBarcode],
        );
        final balance = double.parse(balResult.first[0].toString());
        if (balance < qty - 0.0001) {
          return _json({
            'error': "Mavjud emas: kerak $qty, omborda ${balance.toStringAsFixed(3)}"
          }, status: 409);
        }
        final nameSnapshot = name ?? (refBarcode ?? 'Mahsulot');

        await db.execute('BEGIN');
        try {
          await db.execute(
            '''
            INSERT INTO fh.stock_ledger
              (warehouse_id, item_type, ref_id, ref_barcode, name_snapshot, unit,
               direction, qty, source_type, source_ref, performed_by, note)
            VALUES (\$1, \$2, \$3, \$4, \$5, \$6, 'out', \$7, 'write_off', \$8, \$9, \$10)
            ''',
            parameters: [
              warehouseId, itemType, refId, refBarcode, nameSnapshot, unit,
              qty, reason, _uid(request), note,
            ],
          );
          await db.execute(
            '''
            INSERT INTO fh.stock_writes
              (warehouse_id, item_type, ref_id, ref_barcode, name_snapshot, unit,
               qty, reason, note, performed_by)
            VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10)
            ''',
            parameters: [
              warehouseId, itemType, refId, refBarcode, nameSnapshot, unit,
              qty, reason, note, _uid(request),
            ],
          );
          await db.execute('COMMIT');
          return _json({'message': 'Mahsulot hisobdan chiqarildi (yo\'qotish)'}, status: 201);
        } catch (_) {
          await db.execute('ROLLBACK');
          rethrow;
        }
      } catch (e) {
        print('write-off xato: $e');
        return _json({'error': 'Server xatosi: $e'}, status: 500);
      }
    });

    put('/production/<id>', (Request request, String id) async {
      final batchId = int.tryParse(id);
      if (batchId == null) return _json({'error': "Noto'g'ri ID"}, status: 400);

      if (!Policy.canPlan(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }

      try {
        final body = await _body(request);
        final action = body['action'] as String?;
        final finishedWarehouseId = body['finished_warehouse_id'] as int?;
        final producedQty = (body['produced_qty'] as num?)?.toInt();

        if (action == null || !['complete', 'cancel'].contains(action)) {
          return _json({'error': 'action: complete|cancel'}, status: 400);
        }
        if (action == 'complete' &&
            (finishedWarehouseId == null ||
                producedQty == null ||
                producedQty <= 0)) {
          return _json({
            'error': 'complete uchun finished_warehouse_id va produced_qty majburiy',
          }, status: 400);
        }

        final db = await DatabaseConnection.getConnection();

        final batchResult = await db.execute(
          'SELECT product_barcode, status FROM fh.production_batches WHERE id = \$1',
          parameters: [batchId],
        );
        if (batchResult.isEmpty) {
          return _json({'error': 'Partiya topilmadi'}, status: 404);
        }
        final batch = batchResult.first;
        if (batch[1] != 'in_progress') {
          return _json(
            {'error': 'Partiya allaqachon yakunlangan'},
            status: 409,
          );
        }

        final barcode = batch[0] as String;

        await db.execute('BEGIN');
        try {
          if (action == 'complete') {
            final product = await db.execute(
              'SELECT name FROM public.products WHERE barcode = \$1',
              parameters: [barcode],
            );
            final productName =
                product.isNotEmpty ? product.first[0] as String : barcode;

            await db.execute(
              '''
              INSERT INTO fh.stock_ledger
                (warehouse_id, item_type, ref_barcode, name_snapshot, unit,
                 direction, qty, source_type, source_ref, performed_by)
              VALUES (\$1, 'product', \$2, \$3, 'dona', 'in', \$4, 'production_in', \$5, \$6)
              ''',
              parameters: [
                finishedWarehouseId, barcode, productName,
                producedQty!.toDouble(), batchId.toString(), _uid(request),
              ],
            );

            await db.execute(
              '''
              UPDATE fh.production_batches
              SET status = 'completed', produced_qty = \$2, completed_at = now()
              WHERE id = \$1
              ''',
              parameters: [batchId, producedQty],
            );

            await db.execute(
              '''
              UPDATE fh.plans p SET produced_qty = p.produced_qty + \$2,
                     status = CASE WHEN p.produced_qty + \$2 >= p.target_qty THEN 'done' ELSE 'in_progress' END
              WHERE p.id = (SELECT plan_id FROM fh.production_batches WHERE id = \$1 AND plan_id IS NOT NULL)
              ''',
              parameters: [batchId, producedQty],
            );
          } else {
            await db.execute(
              "UPDATE fh.production_batches SET status = 'cancelled', completed_at = now() "
              'WHERE id = \$1',
              parameters: [batchId],
            );
          }

          await db.execute('COMMIT');
          return _json({
            'message': action == 'complete' ? 'Yakunlandi' : 'Bekor qilindi'
          });
        } catch (_) {
          await db.execute('ROLLBACK');
          rethrow;
        }
      } catch (e) {
        print('production/:id xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ---------- REPORTS ----------
    get('/reports/production', (Request request) async {
      try {
        final status = request.url.queryParameters['status'];
        final db = await DatabaseConnection.getConnection();
        final result = await db.execute(
          '''
          SELECT b.id, b.product_barcode, p.name AS product_name,
                 b.planned_qty, b.produced_qty, b.status,
                 u.username AS started_by, b.created_at, b.completed_at
          FROM fh.production_batches b
          LEFT JOIN public.products p ON p.barcode = b.product_barcode
          LEFT JOIN fh.users u ON u.id = b.started_by
          WHERE (\$1::varchar IS NULL OR b.status = \$1)
          ORDER BY b.created_at DESC
          LIMIT 200
          ''',
          parameters: [status],
        );

        return _json({
          'batches': result.map((row) => {
            'id': row[0], 'barcode': row[1], 'productName': row[2],
            'plannedQty': row[3], 'producedQty': row[4], 'status': row[5],
            'startedBy': row[6], 'createdAt': row[7]?.toString(),
            'completedAt': row[8]?.toString(),
          }).toList(),
          'total': result.length,
        });
      } catch (e) {
        print('reports/production xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ---------- DASHBOARD & ALERTS ----------
    get('/dashboard/summary', (Request request) async {
      final role = _role(request);

      try {
        final db = await DatabaseConnection.getConnection();

        final counts = await db.execute('''
          SELECT
            (SELECT COUNT(*) FROM fh.users WHERE is_active),
            (SELECT COUNT(*) FROM fh.warehouses WHERE is_active),
            (SELECT COUNT(*) FROM fh.plans WHERE status IN ('planned','in_progress')),
            (SELECT COUNT(*) FROM fh.production_batches WHERE status = 'in_progress'),
            (SELECT COUNT(*) FROM fh.supplier_orders WHERE status IN ('ordered','in_transit')),
            (SELECT COUNT(*) FROM public.partners WHERE faolligi),
            (SELECT COUNT(*) FROM public.products),
            (SELECT COUNT(*) FROM public.raw_materials)
        ''');
        final c = counts.first;

        final lowStock = await db.execute('''
          SELECT t.item_type,
                 COALESCE(t.ref_id::text, t.ref_barcode) AS ref_key,
                 MAX(COALESCE(l.name_snapshot, '?')) AS name,
                 t.min_qty,
                 SUM(CASE l.direction WHEN 'in' THEN l.qty ELSE -l.qty END) AS balance
          FROM fh.stock_thresholds t
          LEFT JOIN fh.stock_ledger l
            ON l.item_type = t.item_type
           AND ((t.ref_id IS NOT NULL AND l.ref_id = t.ref_id)
             OR (t.ref_barcode IS NOT NULL AND l.ref_barcode = t.ref_barcode))
          GROUP BY t.item_type, COALESCE(t.ref_id::text, t.ref_barcode), t.min_qty
          HAVING SUM(CASE l.direction WHEN 'in' THEN l.qty ELSE -l.qty END) < t.min_qty
        ''');

        late var lateOrders;
        if (Policy.canControlWarehouses(role) || Policy.canManageSettings(role)) {
          lateOrders = await db.execute(
            "SELECT COUNT(*) FROM fh.supplier_orders "
            "WHERE status IN ('ordered','in_transit') AND expected_at < CURRENT_DATE",
          );
        } else {
          lateOrders = [[0]];
        }

        return _json({
          'stats': {
            'activeUsers': c[0],
            'activeWarehouses': c[1],
            'openPlans': c[2],
            'batchesInProgress': c[3],
            'pendingSupplierOrders': c[4],
            'activePartners': c[5],
            'totalProducts': c[6],
            'totalRawMaterials': c[7],
          },
          'lowStockCount': lowStock.length,
          'lowStock': lowStock.map((row) => {
            'itemType': row[0], 'refKey': row[1], 'name': row[2],
            'minQty': row[3]?.toString(), 'balance': row[4]?.toString(),
          }).toList(),
          'lateSupplierOrders': lateOrders.first[0],
        });
      } catch (e) {
        print('dashboard xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    get('/alerts', (Request request) async {
      try {
        final db = await DatabaseConnection.getConnection();

        final lowStock = await db.execute('''
          SELECT t.item_type,
                 COALESCE(t.ref_id::text, t.ref_barcode) AS ref_key,
                 MAX(COALESCE(l.name_snapshot, '?')) AS name,
                 t.min_qty,
                 SUM(CASE l.direction WHEN 'in' THEN l.qty ELSE -l.qty END) AS balance
          FROM fh.stock_thresholds t
          LEFT JOIN fh.stock_ledger l
            ON l.item_type = t.item_type
           AND ((t.ref_id IS NOT NULL AND l.ref_id = t.ref_id)
             OR (t.ref_barcode IS NOT NULL AND l.ref_barcode = t.ref_barcode))
          GROUP BY t.item_type, COALESCE(t.ref_id::text, t.ref_barcode), t.min_qty
          HAVING SUM(CASE l.direction WHEN 'in' THEN l.qty ELSE -l.qty END) < t.min_qty
          ORDER BY name
        ''');

        final lateOrders = await db.execute('''
          SELECT s.id, s.supplier_name, rm.name AS material_name, s.expected_at,
                 CURRENT_DATE - s.expected_at AS days_late
          FROM fh.supplier_orders s
          LEFT JOIN public.raw_materials rm ON rm.id = s.raw_material_id
          WHERE s.status IN ('ordered','in_transit') AND s.expected_at < CURRENT_DATE
          ORDER BY days_late DESC
        ''');

        final overduePlans = await db.execute('''
          SELECT id, title, due_date, target_qty - produced_qty AS remaining
          FROM fh.plans
          WHERE status IN ('planned','in_progress') AND due_date < CURRENT_DATE
          ORDER BY due_date
        ''');

        return _json({
          'lowStock': lowStock.map((row) => {
            'itemType': row[0], 'refKey': row[1], 'name': row[2],
            'minQty': row[3]?.toString(), 'balance': row[4]?.toString(),
          }).toList(),
          'lateSupplierOrders': lateOrders.map((row) => {
            'id': row[0], 'supplierName': row[1], 'materialName': row[2],
            'expectedAt': row[3]?.toString(), 'daysLate': row[4],
          }).toList(),
          'overduePlans': overduePlans.map((row) => {
            'id': row[0], 'title': row[1], 'dueDate': row[2]?.toString(),
            'remaining': row[3],
          }).toList(),
        });
      } catch (e) {
        print('alerts xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ---------- CRITICAL LEVELS (THRESHOLDS) ----------
    get('/thresholds', (Request request) async {
      final role = _role(request);
      if (!Policy.canManageSettings(role)) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      try {
        final db = await DatabaseConnection.getConnection();
        final typeParam = request.url.queryParameters['type'];
        final rows = await db.execute(
          '''
          SELECT t.id,
                 t.item_type,
                 COALESCE(t.ref_barcode, t.ref_id::text) AS ref_key,
                 COALESCE(p.name, rm.name) AS name,
                 t.min_qty,
                 COALESCE(bal.balance, 0) AS balance
          FROM fh.stock_thresholds t
          LEFT JOIN public.products p
            ON t.item_type = 'product' AND p.barcode = t.ref_barcode
          LEFT JOIN public.raw_materials rm
            ON t.item_type = 'raw_material' AND rm.id = t.ref_id
          LEFT JOIN (
            SELECT item_type,
                   COALESCE(ref_barcode, ref_id::text) AS ref_key,
                   SUM(CASE direction WHEN 'in' THEN qty ELSE -qty END) AS balance
            FROM fh.stock_ledger
            GROUP BY item_type, COALESCE(ref_barcode, ref_id::text)
          ) bal ON bal.item_type = t.item_type AND bal.ref_key = COALESCE(t.ref_barcode, t.ref_id::text)
          WHERE (\$1::text IS NULL OR t.item_type = \$1)
          ORDER BY (COALESCE(bal.balance, 0) < t.min_qty) DESC, name NULLS LAST
        ''',
          parameters: [typeParam],
        );
        return _json({
          'thresholds': rows.map((r) => {
                'id': r[0],
                'itemType': r[1],
                'refKey': r[2],
                'name': r[3] ?? r[2],
                'minQty': r[4]?.toString(),
                'balance': r[5]?.toString(),
              }).toList(),
        });
      } catch (e) {
        print('thresholds GET xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    put('/thresholds', (Request request) async {
      final role = _role(request);
      if (!Policy.canManageSettings(role)) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      try {
        final body = await _body(request);
        final id = body['id'] as int?;
        final minQty = (body['min_qty'] as num?)?.toDouble();
        if (id == null || minQty == null || minQty < 0) {
          return _json(
              {'error': "id va min_qty (>=0) majburiy"}, status: 400);
        }
        final db = await DatabaseConnection.getConnection();
        final res = await db.execute(
          'UPDATE fh.stock_thresholds SET min_qty = \$1 WHERE id = \$2',
          parameters: [minQty, id],
        );
        if (res.affectedRows == 0) {
          return _json({'error': 'Topilmadi'}, status: 404);
        }
        return _json({'ok': true});
      } catch (e) {
        print('thresholds PUT xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });
  }
}
