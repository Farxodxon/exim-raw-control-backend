import 'dart:convert';
import 'dart:typed_data';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:postgres/postgres.dart';
import 'package:exim_raw_backend/database/connection.dart';
import 'package:exim_raw_backend/factoryhub/jwt.dart';
import 'package:exim_raw_backend/factoryhub/policy.dart';
import 'package:exim_raw_backend/factoryhub/user_storage.dart';
import 'package:exim_raw_backend/factoryhub/hr_models.dart';
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

bool _fullAccess(String role) => Policy.canViewAllWarehouses(role);

// Foydalanuvchiga biriktirilgan omborlar (admin/director uchun ishlatilmaydi).
Future<Set<int>> _grantedWarehouseIds(int uid) async {
  if (uid <= 0) return <int>{};
  final db = await DatabaseConnection.getConnection();
  final res = await db.execute(
    'SELECT warehouse_id FROM fh.user_warehouses WHERE user_id = \$1',
    parameters: [uid],
  );
  return res.map((r) => (r[0] as num).toInt()).toSet();
}

// Foydalanuvchiga biriktirilgan modullar (admin/director uchun ishlatilmaydi).
Future<Set<String>> _grantedModuleKeys(int uid) async {
  if (uid <= 0) return <String>{};
  final db = await DatabaseConnection.getConnection();
  final res = await db.execute(
    'SELECT module_key FROM fh.user_modules WHERE user_id = \$1',
    parameters: [uid],
  );
  return res.map((r) => r[0] as String).toSet();
}

// Path prefiksinga mos keluvchi modul kaliti.
String? _moduleKeyForPath(String path) {
  if (path.startsWith('production/mixing')) return 'production';
  if (path.startsWith('production/packaging')) return 'packaging';
  if (path.startsWith('production/')) return 'production';
  if (path == 'transfers/pending' ||
      RegExp(r'^transfers/\d+/(confirm|reject)$').hasMatch(path)) {
    return 'transfer_confirmations';
  }
  if (path.startsWith('inspections/')) return 'inspection';
  if (path.startsWith('hr/')) return 'hr';
  if (path.startsWith('plans')) return 'planning';
  if (path.startsWith('supplier-orders')) return 'supplier_orders';
  if (path.startsWith('users') || path.startsWith('admin/')) return 'user_management';
  if (path.startsWith('thresholds')) return 'admin_settings';
  return null;
}

// Restricted foydalanuvchi uchun omborga ruxsat bormi?
bool _grantedWhContains(Request request, int id) {
  if (_fullAccess(_role(request))) return true;
  return ((request.context['fh_wh'] as Set<int>?) ?? <int>{}).contains(id);
}

// Tur bo'yicha default ombor id (bitta zavod; is_default yo'q bo'lsa birinchisi).
Future<int?> _defaultWarehouseId(Connection db, String type) async {
  final res = await db.execute(
    'SELECT id FROM fh.warehouses WHERE type = \$1 AND is_active '
    'ORDER BY is_default DESC, id LIMIT 1',
    parameters: [type],
  );
  return res.isEmpty ? null : (res.first[0] as num).toInt();
}

// Ombordagi item balansi (amount type/id bo'yicha).
Future<double> _stockBalance(
    Connection db, int warehouseId, String itemType, int? refId, String? refBarcode) async {
  final res = await db.execute(
    '''
    SELECT COALESCE(SUM(CASE direction WHEN 'in' THEN qty ELSE -qty END), 0)
    FROM fh.stock_ledger
    WHERE warehouse_id = \$1 AND item_type = \$2
      AND (\$3::int IS NULL OR ref_id = \$3)
      AND (\$4::text IS NULL OR ref_barcode = \$4)
    ''',
    parameters: [warehouseId, itemType, refId, refBarcode],
  );
  return double.parse(res.first[0].toString());
}

Future<Map<String, dynamic>?> _itemBrief(Connection db, int? id) async {
  if (id == null) return null;
  final res = await db.execute(
    'SELECT id, name, item_type, code, unit FROM fh.items WHERE id = \$1',
    parameters: [id],
  );
  if (res.isEmpty) return null;
  final r = res.first;
  return {'id': r[0], 'name': r[1], 'itemType': r[2], 'code': r[3], 'unit': r[4]};
}

// Transfer sodir bo'layotgan item haqida ma'lumot: avval manba ombor qoldig'idan
// (legacy raw_material/product'lar fh.items da yo'q), shu topilmasa fh.items dan.
Future<Map<String, dynamic>?> _resolveItem(
    Connection db, int? itemId, int? srcWhId) async {
  if (srcWhId != null && itemId != null) {
    final res = await db.execute(
      '''
      SELECT item_type, MAX(name_snapshot), MAX(unit), MAX(ref_id), MAX(ref_barcode)
      FROM fh.stock_ledger
      WHERE warehouse_id = \$1 AND COALESCE(ref_id::text, ref_barcode) = \$2::int::text
      GROUP BY item_type
      ''',
      parameters: [srcWhId, itemId],
    );
    if (res.isNotEmpty) {
      return {
        'itemType': res.first[0],
        'name': res.first[1],
        'unit': res.first[2],
        'refId': res.first[3],
        'refBarcode': res.first[4],
      };
    }
  }
  return _itemBrief(db, itemId);
}

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

    final role = payload['role'] as String? ?? '';
    final uid = payload['user_id'] as int?;

    // Modul-va-omborga asoslangan ruxsatlar.
    // Admin/director — to'liq kirish; qolganlar faqat biriktirilgan
    // omborlar (user_warehouses) va modullar (user_modules) bo'yicha.
    if (role != AppRoles.admin &&
        role != AppRoles.director &&
        uid != null &&
        path != 'auth/my-access') {
      final whGranted = await _grantedWarehouseIds(uid);
      final modGranted = await _grantedModuleKeys(uid);

      // warehouse_id query parametri — biriktirilgan omborda bo'lishi shart.
      final qwh = int.tryParse(request.url.queryParameters['warehouse_id'] ?? '');
      if (qwh != null && !whGranted.contains(qwh)) {
        return _json({'error': 'Bu omborga kirish ruxsati yo\'q'}, status: 403);
      }

      // /warehouses/<id>... — path'dagi ombor ID sini tekshirish.
      final whPath = RegExp(r'^warehouses/(\d+)').firstMatch(path);
      if (whPath != null) {
        final wid = int.tryParse(whPath.group(1)!);
        if (wid == null || !whGranted.contains(wid)) {
          return _json({'error': 'Bu omborga kirish ruxsati yo\'q'}, status: 403);
        }
      }

      // Modul path'lar — grant bo'lishi shart.
      final mk = _moduleKeyForPath(path);
      if (mk != null && !modGranted.contains(mk)) {
        return _json({'error': 'Bu bo\'limga kirish ruxsati yo\'q'}, status: 403);
      }

      // Hisobotlar ombor bilan bog'liq — ombori bo'lmagan foydalanuvchiga yopiq.
      if (path.startsWith('reports/') && whGranted.isEmpty) {
        return _json({'error': 'Ruxsat yo\'q'}, status: 403);
      }

      return innerHandler(request.change(context: {
        'fh_user': payload,
        'fh_wh': whGranted,
        'fh_modules': modGranted,
      }));
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

    // ---------- MY ACCESS ----------
    // Joriy foydalanuvchining omborlar va modullar bo'yicha kirish ma'lumoti.
    get('/auth/my-access', (Request request) async {
      try {
        final role = _role(request);
        final uid = _uid(request);
        final db = await DatabaseConnection.getConnection();
        final full = _fullAccess(role);

        if (full) {
          final wh = await db.execute(
            'SELECT id, name, type FROM fh.warehouses WHERE is_active = true ORDER BY id');
          final md = await db.execute(
            'SELECT module_key, name_uz, category FROM fh.app_modules '
            'WHERE is_active = true ORDER BY sort_order');
          return _json({
            'role': role,
            'is_full_access': true,
            'warehouses': wh
                .map((r) => {'id': r[0], 'name': r[1], 'type': r[2]})
                .toList(),
            'modules': md
                .map((r) => {'module_key': r[0], 'name_uz': r[1], 'category': r[2]})
                .toList(),
          });
        }

        final wh = uid == null
            ? <Map<String, dynamic>>[]
            : await db.execute(
                  'SELECT w.id, w.name, w.type FROM fh.user_warehouses uw '
                  'JOIN fh.warehouses w ON w.id = uw.warehouse_id '
                  'WHERE uw.user_id = \$1 AND w.is_active = true ORDER BY w.id',
                  parameters: [uid],
                );
        final md = uid == null
            ? <Map<String, dynamic>>[]
            : await db.execute(
                  'SELECT m.module_key, m.name_uz, m.category FROM fh.user_modules um '
                  'JOIN fh.app_modules m ON m.module_key = um.module_key '
                  'WHERE um.user_id = \$1 AND m.is_active = true ORDER BY m.sort_order',
                  parameters: [uid],
                );
        return _json({
          'role': role,
          'is_full_access': false,
          'warehouses': (wh as List)
              .map((r) => {'id': r[0], 'name': r[1], 'type': r[2]})
              .toList(),
          'modules': (md as List)
              .map((r) => {'module_key': r[0], 'name_uz': r[1], 'category': r[2]})
              .toList(),
        });
      } catch (e) {
        print('my-access xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ---------- ADMIN: foydalanuvchi kirish huquqlarini boshqarish ----------
    get('/admin/modules', (Request request) async {
      if (!Policy.canManageUsers(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      try {
        final db = await DatabaseConnection.getConnection();
        final md = await db.execute(
          'SELECT module_key, name_uz, category, sort_order, is_active '
          'FROM fh.app_modules ORDER BY sort_order');
        return _json({
          'modules': md
              .map((r) => {
                'module_key': r[0],
                'name_uz': r[1],
                'category': r[2],
                'sort_order': r[3],
                'is_active': r[4],
              })
              .toList(),
        });
      } catch (e) {
        print('admin/modules xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    get('/admin/users/<id>/access', (Request request, String id) async {
      if (!Policy.canManageUsers(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      final userId = int.tryParse(id);
      if (userId == null) return _json({'error': "Noto'g'ri ID"}, status: 400);
      try {
        final db = await DatabaseConnection.getConnection();
        final wh = await db.execute(
          'SELECT w.id, w.name, w.type FROM fh.user_warehouses uw '
          'JOIN fh.warehouses w ON w.id = uw.warehouse_id '
          'WHERE uw.user_id = \$1 ORDER BY w.id',
          parameters: [userId],
        );
        final md = await db.execute(
          'SELECT m.module_key, m.name_uz, m.category FROM fh.user_modules um '
          'JOIN fh.app_modules m ON m.module_key = um.module_key '
          'WHERE um.user_id = \$1 ORDER BY m.sort_order',
          parameters: [userId],
        );
        return _json({
          'warehouses': wh
              .map((r) => {'id': r[0], 'name': r[1], 'type': r[2]})
              .toList(),
          'modules': md
              .map((r) => {'module_key': r[0], 'name_uz': r[1], 'category': r[2]})
              .toList(),
        });
      } catch (e) {
        print('admin/users/access GET xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    post('/admin/users/<id>/warehouses', (Request request, String id) async {
      if (!Policy.canManageUsers(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      final userId = int.tryParse(id);
      if (userId == null) return _json({'error': "Noto'g'ri ID"}, status: 400);
      try {
        final body = await _body(request);
        final warehouseId = body['warehouse_id'] as int?;
        if (warehouseId == null) {
          return _json({'error': 'warehouse_id majburiy'}, status: 400);
        }
        final db = await DatabaseConnection.getConnection();
        final exists = await db.execute(
          'SELECT 1 FROM fh.warehouses WHERE id = \$1', parameters: [warehouseId]);
        if (exists.isEmpty) {
          return _json({'error': 'Ombor topilmadi'}, status: 404);
        }
        await db.execute(
          'INSERT INTO fh.user_warehouses (user_id, warehouse_id, granted_by) '
          'VALUES (\$1, \$2, \$3) ON CONFLICT (user_id, warehouse_id) DO NOTHING',
          parameters: [userId, warehouseId, _uid(request)],
        );
        return _json({'message': 'Ombor biriktirildi'}, status: 201);
      } catch (e) {
        print('admin/users/warehouses POST xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    delete('/admin/users/<id>/warehouses/<wid>',
        (Request request, String id, String wid) async {
      if (!Policy.canManageUsers(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      final userId = int.tryParse(id);
      final warehouseId = int.tryParse(wid);
      if (userId == null || warehouseId == null) {
        return _json({'error': "Noto'g'ri ID"}, status: 400);
      }
      try {
        final db = await DatabaseConnection.getConnection();
        await db.execute(
          'DELETE FROM fh.user_warehouses WHERE user_id = \$1 AND warehouse_id = \$2',
          parameters: [userId, warehouseId],
        );
        return _json({'message': 'Ombor ajratildi'});
      } catch (e) {
        print('admin/users/warehouses DELETE xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    post('/admin/users/<id>/modules', (Request request, String id) async {
      if (!Policy.canManageUsers(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      final userId = int.tryParse(id);
      if (userId == null) return _json({'error': "Noto'g'ri ID"}, status: 400);
      try {
        final body = await _body(request);
        final moduleKey = body['module_key'] as String?;
        if (moduleKey == null || moduleKey.trim().isEmpty) {
          return _json({'error': 'module_key majburiy'}, status: 400);
        }
        final db = await DatabaseConnection.getConnection();
        final exists = await db.execute(
          'SELECT 1 FROM fh.app_modules WHERE module_key = \$1',
          parameters: [moduleKey]);
        if (exists.isEmpty) {
          return _json({'error': 'Modul topilmadi'}, status: 404);
        }
        await db.execute(
          'INSERT INTO fh.user_modules (user_id, module_key, granted_by) '
          'VALUES (\$1, \$2, \$3) ON CONFLICT (user_id, module_key) DO NOTHING',
          parameters: [userId, moduleKey, _uid(request)],
        );
        return _json({'message': 'Modul biriktirildi'}, status: 201);
      } catch (e) {
        print('admin/users/modules POST xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    delete('/admin/users/<id>/modules/<mk>',
        (Request request, String id, String mk) async {
      if (!Policy.canManageUsers(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      final userId = int.tryParse(id);
      if (userId == null) return _json({'error': "Noto'g'ri ID"}, status: 400);
      try {
        final db = await DatabaseConnection.getConnection();
        await db.execute(
          'DELETE FROM fh.user_modules WHERE user_id = \$1 AND module_key = \$2',
          parameters: [userId, mk],
        );
        return _json({'message': 'Modul ajratildi'});
      } catch (e) {
        print('admin/users/modules DELETE xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
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
        if (!_fullAccess(role) && userId != null) {
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
          'raw', 'production', 'semi_finished', 'packaging', 'finished',
          'purchased_finished', 'purchased_semi', 'spare_parts', 'sales', 'dealer',
          'quarantine', 'defective', 'returned', 'retain_sample',
          'empty_container', 'other'
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
        return _json({'error': 'Server xatosi: $e'}, status: 500);
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
        final isRegime51 = body['is_regime_51'] as bool? ?? false;

        final allowedTypes = ['raw_material', 'product', 'spare_part', 'semi_finished', 'item'];
        if (warehouseId == null || itemType == null || direction == null || qty == null) {
          return _json(
            {'error': 'warehouse_id, item_type, direction, qty majburiy'},
            status: 400,
          );
        }
if (!_grantedWhContains(request, warehouseId)) {
          return _json({'error': 'Bu omborga kirish ruxsati yo\'q'}, status: 403);
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
             direction, qty, source_type, performed_by, note, is_regime_51)
          VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, 'manual', \$9, \$10, \$11)
          ''',
          parameters: [
            warehouseId, itemType, refId, refBarcode, nameSnapshot, unit,
            direction, qty, userId, note, isRegime51,
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
        final restricted = !_fullAccess(_role(request));
        final grantedWh =
            restricted ? (request.context['fh_wh'] as Set<int>?) ?? <int>{} : null;
        if (restricted && grantedWh != null && grantedWh.isEmpty) {
          return _json({'stock': <dynamic>[], 'total': 0});
        }
        var where = '(\$1::int IS NULL OR w.id = \$1)';
        final params = <dynamic>[warehouseId];
        if (restricted) {
          where += ' AND w.id = ANY(\$2)';
          params.add(grantedWh!.toList());
        }
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
          WHERE $where
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
          parameters: params,
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
        if (!_fullAccess(_role(request))) {
          final grantedWh =
              (request.context['fh_wh'] as Set<int>?) ?? <int>{};
          if (grantedWh.isEmpty) {
            return _json({'error': 'Ruxsat yo\'q'}, status: 403);
          }
          idx++;
          where += ' AND l.warehouse_id = ANY(\$$idx)';
          params.add(grantedWh.toList());
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
        final restricted = !_fullAccess(_role(request));
        final grantedWh =
            restricted ? (request.context['fh_wh'] as Set<int>?) ?? <int>{} : null;
        var query = '''
          SELECT t.id, fw.name AS from_name, tw.name AS to_name,
                 t.status, t.note, u.username, t.created_at, t.completed_at,
                 (SELECT COUNT(*) FROM fh.transfer_items ti WHERE ti.transfer_id = t.id) AS item_count,
                 t.is_sale
          FROM fh.transfers t
          JOIN fh.warehouses fw ON fw.id = t.from_warehouse_id
          JOIN fh.warehouses tw ON tw.id = t.to_warehouse_id
          LEFT JOIN fh.users u ON u.id = t.created_by
        ''';
        final params = <dynamic>[];
        if (restricted) {
          query += ' WHERE t.from_warehouse_id = ANY(\$1) OR t.to_warehouse_id = ANY(\$1)';
          params.add(grantedWh!.toList());
        }
        query += ' ORDER BY t.created_at DESC LIMIT 100';
        final result = await db.execute(query, parameters: params);
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

    // POST /transfers/send — qo'lda yuborish (qabul qiluvchi tasdiqlashini kutadi).
    //   body: { item_id, quantity, unit?, source_warehouse_id, dest_warehouse_id, note? }
    // Manba ombor qoldig'idan DARHOL ayiriladi, qabul qiluvchi omborga esa
    // faqat "Qabul qildim" bosilgach qo'shiladi. Yo'nalish fh.warehouse_transfer_routes
    // orqali tekshiriladi.
    post('/transfers/send', (Request request) async {
      final role = _role(request);
      if (!Policy.canTransactStock(role)) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      try {
        final body = await _body(request);
        final itemId = body['item_id'] as int?;
        final qty = (body['quantity'] as num?)?.toDouble();
        final unit = body['unit'] as String?;
        final srcId = body['source_warehouse_id'] as int?;
        final destId = body['dest_warehouse_id'] as int?;
        if (itemId == null || qty == null || qty <= 0 || srcId == null || destId == null) {
          return _json({
            'error': 'item_id, quantity (>0), source_warehouse_id, dest_warehouse_id majburiy'
          }, status: 400);
        }
        if (srcId == destId) {
          return _json({'error': "Jo'natuvchi va qabul qiluvchi ombor bir xil"}, status: 400);
        }
        final uid = _uid(request);

        if (!_grantedWhContains(request, srcId)) {
          return _json({'error': "Jo'natuvchi omborga kirish ruxsati yo'q"}, status: 403);
        }

        final db = await DatabaseConnection.getConnection();
        final wh = await db.execute(
          'SELECT id, name, type FROM fh.warehouses WHERE id IN (\$1, \$2) AND is_active',
          parameters: [srcId, destId],
        );
        if (wh.length < 2) return _json({'error': 'Ombor topilmadi'}, status: 404);
        String whName(int id) {
          for (final r in wh) {
            if (r[0] == id) return (r[1] as String?) ?? '';
          }
          return '';
        }

        // Ruxsat etilgan yo'nalish (warehouse_transfer_routes).
        final route = await db.execute(
          'SELECT 1 FROM fh.warehouse_transfer_routes '
          'WHERE from_warehouse_id = \$1 AND to_warehouse_id = \$2',
          parameters: [srcId, destId],
        );
        if (route.isEmpty) {
          return _json({
            'error': 'Bu yo\'nalishga transfer ruxsat etilmagan. Ombor sozlamalarida transfer yo\'nalishini qo\'shing'
          }, status: 403);
        }

        final item = await _resolveItem(db, itemId, srcId);
        if (item == null) return _json({'error': 'Mahsulot topilmadi'}, status: 404);
        final itemType = (item['itemType'] as String?) ?? 'item';
        final useUnit = (unit == null || unit.isEmpty)
            ? ((item['unit'] as String?) ?? 'dona')
            : unit;

        // Yetarlilik (qo'lda chiqim nazorati bilan bir xil aniqlik).
        final balRow = await db.execute(
          '''
          SELECT COALESCE(SUM(CASE direction WHEN 'in' THEN qty ELSE -qty END), 0)
          FROM fh.stock_ledger
          WHERE warehouse_id = \$1 AND item_type = \$2
            AND COALESCE(ref_id::text, ref_barcode) = \$3::int::text
          ''',
          parameters: [srcId, itemType, itemId],
        );
        final available = double.parse(balRow.first[0].toString());
        if (available < qty - 0.0001) {
          return _json({
            'error': 'Omborda yetarli qoldiq yo\'q',
            'available': available,
          }, status: 422);
        }

        await db.execute('BEGIN');
        try {
          final tr = await db.execute(
            'INSERT INTO fh.stock_transfers '
            '(item_id, quantity, unit, source_warehouse_id, dest_warehouse_id, '
            ' status, created_by) '
            'VALUES (\$1, \$2, \$3, \$4, \$5, \'pending\', \$6) RETURNING id',
            parameters: [itemId, qty, useUnit, srcId, destId, uid],
          );
          final transferId = tr.first[0];

          // Chiqim YOZILMAYDI — manba ombor qoldig'i faqat qabul qiluvchi
          // ombor "Qabul qildim" (confirm) bosganda kamayadi. Pending paytida
          // ikkala ombor ham o'zgarmaydi.

          await db.execute('COMMIT');
          return _json({
            'message': 'Yuborildi. Qabul qiluvchi ombor tasdiqlashini kutmoqda.',
            'transferId': transferId,
            'pending': true,
            'sourceWarehouseName': whName(srcId),
            'destWarehouseName': whName(destId),
          }, status: 201);
        } catch (e) {
          await db.execute('ROLLBACK');
          rethrow;
        }
      } catch (e) {
        print('transfers/send xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // GET /transfers/pending — qabul qiluvchi ombor bo'yicha kutilayotgan o'tkazmalar
    get('/transfers/pending', (Request request) async {
      try {
        final warehouseId =
            int.tryParse(request.url.queryParameters['warehouse_id'] ?? '');
        if (warehouseId == null) {
          return _json({'error': 'warehouse_id majburiy'}, status: 400);
        }
        final db = await DatabaseConnection.getConnection();
        final result = await db.execute(
          '''
          SELECT t.id, t.item_id,
                 COALESCE(i.name, (
                   SELECT MAX(l.name_snapshot) FROM fh.stock_ledger l
                   WHERE COALESCE(l.ref_id::text, l.ref_barcode) = t.item_id::text
                     AND l.warehouse_id = t.source_warehouse_id
                 ), ('Mahsulot #' || t.item_id)) AS item_name,
                 t.unit, t.quantity,
                 t.source_warehouse_id, sw.name AS source_name,
                 t.dest_warehouse_id, dw.name AS dest_name,
                 t.production_batch_id, t.created_by, u.username, t.created_at, t.status
          FROM fh.stock_transfers t
          LEFT JOIN fh.items i ON i.id = t.item_id
          LEFT JOIN fh.warehouses sw ON sw.id = t.source_warehouse_id
          JOIN fh.warehouses dw ON dw.id = t.dest_warehouse_id
          LEFT JOIN fh.users u ON u.id = t.created_by
          WHERE t.dest_warehouse_id = \$1 AND t.status = 'pending'
          ORDER BY t.created_at DESC
          ''',
          parameters: [warehouseId],
        );
        return _json({
          'transfers': result.map((r) => {
            'id': r[0], 'itemId': r[1], 'itemName': r[2], 'unit': r[3],
            'quantity': r[4]?.toString(),
            'sourceWarehouseId': r[5], 'sourceName': r[6] ?? 'Ishlab chiqarishdan',
            'destWarehouseId': r[7], 'destName': r[8],
            'productionBatchId': r[9], 'createdBy': r[10], 'createdByName': r[11],
            'createdAt': r[12]?.toString(), 'status': r[13],
          }).toList(),
        });
      } catch (e) {
        print('transfers/pending xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // GET /transfers/pending/summary — har bir ombor uchun kutilayotgan
    // qabul soni (omborlar ro'yxatida badge ko'rsatish uchun).
    get('/transfers/pending/summary', (Request request) async {
      try {
        final db = await DatabaseConnection.getConnection();
        final result = await db.execute(
          "SELECT dest_warehouse_id, COUNT(*) FROM fh.stock_transfers "
          "WHERE status = 'pending' GROUP BY dest_warehouse_id",
        );
        return _json({
          'counts': result.map((r) => {'warehouseId': r[0], 'count': r[1]}).toList(),
        });
      } catch (e) {
        print('transfers/pending/summary xato: $e');
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
        if (!_fullAccess(_role(request))) {
          final grantedWh =
              (request.context['fh_wh'] as Set<int>?) ?? <int>{};
          final fromId = (r[1] as num).toInt();
          final toId = (r[3] as num).toInt();
          if (!grantedWh.contains(fromId) && !grantedWh.contains(toId)) {
            return _json({'error': 'Ruxsat yo\'q'}, status: 403);
          }
        }
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

if (!_fullAccess(role) && userId != null) {
              final grantedWh =
                  (request.context['fh_wh'] as Set<int>?) ?? <int>{};
              if (!grantedWh.contains(fromId) || !grantedWh.contains(toId)) {
                await db.execute('ROLLBACK');
                return _json({'error': 'Omborlarga ruxsat yo\'q'}, status: 403);
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

    // ---------- 51-REJIM BALANS HISOBOTI ----------
    // Faqat is_regime_51 = true bo'lgan yozuvlar bo'yicha SUM(in)-SUM(out).
    // Umumiy balansga ta'sir qilmaydi (umumiy SUM hech qachon bu flagga qaramaydi).
    get('/reports/regime51-balance', (Request request) async {
      try {
        final warehouseId = int.tryParse(request.url.queryParameters['warehouse_id'] ?? '');
        final itemId = int.tryParse(request.url.queryParameters['item_id'] ?? '');

        final db = await DatabaseConnection.getConnection();

        var where = 'l.is_regime_51 = true';
        final params = <dynamic>[];
        final whInfo = <String, dynamic>{};
        if (warehouseId != null) {
          params.add(warehouseId);
          where += ' AND l.warehouse_id = \$${params.length}';
          final wh = await db.execute('SELECT id, name, type FROM fh.warehouses WHERE id = \$1', parameters: [warehouseId]);
          if (wh.isEmpty) return _json({'error': 'Ombor topilmadi'}, status: 404);
          whInfo['id'] = wh.first[0];
          whInfo['name'] = wh.first[1];
          whInfo['type'] = wh.first[2];
        }
        if (itemId != null) {
          params.add(itemId);
          where += ' AND l.ref_id = \$${params.length}';
        }

        final result = await db.execute(
          '''
          SELECT
            l.warehouse_id,
            COALESCE(
              CASE
                WHEN l.item_type = \'raw_material\' THEN rm.code
                WHEN l.item_type = \'item\' AND l.ref_id IS NOT NULL THEN l.ref_id::text
                ELSE l.ref_barcode
              END
            ) AS ref_key,
            MAX(l.name_snapshot) AS name,
            MAX(l.unit) AS unit,
            l.item_type,
            l.ref_id,
            SUM(CASE l.direction WHEN \'in\' THEN l.qty ELSE -l.qty END) AS balance
          FROM fh.stock_ledger l
          LEFT JOIN public.raw_materials rm ON rm.id = l.ref_id
          WHERE $where
          GROUP BY l.warehouse_id, l.item_type, COALESCE(
            CASE
              WHEN l.item_type = \'raw_material\' THEN rm.code
              WHEN l.item_type = \'item\' AND l.ref_id IS NOT NULL THEN l.ref_id::text
              ELSE l.ref_barcode
            END
          ), l.ref_id
          HAVING SUM(CASE l.direction WHEN \'in\' THEN l.qty ELSE -l.qty END) <> 0
          ORDER BY l.warehouse_id, name
          ''',
          parameters: params,
        );

        return _json({
          'type': 'regime51',
          'warehouse':
              whInfo.isEmpty ? null : {'id': whInfo['id'], 'name': whInfo['name'], 'type': whInfo['type']},
          'balance': result.map((r) => {
            'warehouseId': r[0],
            'refKey': r[1],
            'name': r[2],
            'unit': r[3],
            'itemType': r[4],
            'refId': r[5],
            'balance': r[6]?.toString(),
          }).toList(),
        });
      } catch (e) {
        print('reports/regime51-balance xato: $e');
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
        final isRegime51 = body['is_regime_51'] as bool? ?? false;

        if (supplierName == null || rawMaterialId == null || qty == null || qty <= 0) {
          return _json({
            'error': 'supplier_name, raw_material_id va qty (>0) majburiy',
          }, status: 400);
        }

        final db = await DatabaseConnection.getConnection();
        await db.execute(
          '''
          INSERT INTO fh.supplier_orders
            (supplier_name, raw_material_id, qty, unit, expected_at, created_by, is_regime_51)
          VALUES (\$1, \$2, \$3, \$4, \$5::date, \$6, \$7)
          ''',
          parameters: [supplierName, rawMaterialId, qty, unit, expectedAt, _uid(request), isRegime51],
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
        final r = bom.first;
        // chiqadigan mahsulot haqida ma'lumot
        dynamic outputItem = null;
        final outItemId = r[3] as int?;
        if (outItemId != null) {
          final oi = await db.execute(
            'SELECT id, name, unit FROM fh.items WHERE id = \$1', parameters: [outItemId]);
          if (oi.isNotEmpty) {
            outputItem = {'id': oi.first[0], 'name': oi.first[1], 'unit': oi.first[2]};
          }
        }
        final items = await db.execute(
          'SELECT item_type, ref_id, ref_barcode, name_snapshot, unit, qty FROM fh.bom_items WHERE bom_id = \$1 ORDER BY id',
          parameters: [bomId],
        );
        return _json({
          'bom': {
            'id': r[0], 'name': r[1], 'stage': r[2], 'outputItemId': r[3],
            'outputQty': r[4]?.toString(), 'outputUnit': r[5],
          },
          'outputItem': outputItem,
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

        // output_item_id mavjudligini va stage bilan mosligini tekshirish
        final outItem = await db.execute(
          'SELECT name, item_type FROM fh.items WHERE id = \$1 AND is_active',
          parameters: [outputItemId],
        );
        if (outItem.isEmpty) {
          return _json({'error': 'Chiqadigan mahsulot (item) topilmadi. Avval items katalogida yarating.'}, status: 400);
        }
        final outItemType = outItem.first[1] as String;
        final outItemName = outItem.first[0] as String;

        // mixing → yarim tayyor/xom item; packaging → tayyor mahsulot itemi kerak
        bool typeMatchesStage = false;
        if (stage == 'mixing' &&
            (outItemType == 'semi_finished' || outItemType == 'intermediate' || outItemType == 'semi' || outItemType == 'raw' || outItemType == 'material')) {
          typeMatchesStage = true;
        } else if (stage == 'packaging' &&
            (outItemType == 'product' || outItemType == 'finished' || outItemType == 'item')) {
          typeMatchesStage = true;
        }
        if (!typeMatchesStage) {
          return _json({
            'error': "'$outItemName' item turi '${outItemType}' BOM bosqichiga '${stage}' mos kelmaydi. Aralashtirish bosqichi uchun yarim tayyor, qadoqlash uchun tayyor mahsulot itemini tanlang."
          }, status: 400);
        }

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
        return _json({'error': 'Retsept yaratishda xatolik yuz berdi'}, status: 500);
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
        final outputItemId = body['output_item_id'] as int?;
        final outputUnit = body['output_unit'] as String?;
        final items = body['items'] as List<dynamic>?;
        if (active != null) {
          final db = await DatabaseConnection.getConnection();
          await db.execute('UPDATE fh.boms SET is_active = \$1 WHERE id = \$2',
            parameters: [active, bomId]);
          return _json({'message': 'Yangilandi'});
        }
        if (name == null && outputQty == null && outputItemId == null &&
            outputUnit == null && items == null) {
          return _json({'error': 'Yangilanadigan maydon topilmadi'}, status: 400);
        }
        if (outputQty != null && outputQty <= 0) {
          return _json({'error': 'Chiqadigan miqdor 0 dan katta bo\'lishi kerak'}, status: 400);
        }
        final db = await DatabaseConnection.getConnection();
        if (outputItemId != null) {
          // output_item_id mavjudligini tekshirish
          final oi = await db.execute(
            'SELECT id FROM fh.items WHERE id = \$1 AND is_active', parameters: [outputItemId]);
          if (oi.isEmpty) {
            return _json({'error': 'Chiqadigan mahsulot (item) topilmadi'}, status: 400);
          }
        }
        await db.execute('BEGIN');
        try {
          if (name != null) {
            await db.execute('UPDATE fh.boms SET name = \$1 WHERE id = \$2',
              parameters: [name.trim(), bomId]);
          }
          if (outputQty != null) {
            await db.execute('UPDATE fh.boms SET output_qty_per_batch = \$1 WHERE id = \$2',
              parameters: [outputQty, bomId]);
          }
          if (outputItemId != null) {
            await db.execute('UPDATE fh.boms SET output_item_id = \$1 WHERE id = \$2',
              parameters: [outputItemId, bomId]);
          }
          if (outputUnit != null && outputUnit.isNotEmpty) {
            await db.execute('UPDATE fh.boms SET output_unit = \$1 WHERE id = \$2',
              parameters: [outputUnit, bomId]);
          }
          if (items != null) {
            // Tarkibni butunlay yangi ro'yxatga almashtirish.
            await db.execute('DELETE FROM fh.bom_items WHERE bom_id = \$1',
              parameters: [bomId]);
            final parsed = <List<dynamic>>[];
            for (final it in items) {
              final itemType = it['item_type'] as String?;
              final refId = it['ref_id'] as int?;
              final refBarcode = it['ref_barcode'] as String?;
              final nameSnapshot = it['name'] as String? ?? '';
              final unit = it['unit'] as String? ?? 'dona';
              final qty = (it['qty'] as num?)?.toDouble();
              if (itemType == null || qty == null || qty <= 0) continue;
              parsed.add([itemType, refId, refBarcode, nameSnapshot, unit, qty]);
            }
            if (parsed.isEmpty) {
              await db.execute('ROLLBACK');
              return _json({'error': 'Hech bo\'lmaganda bitta tarkib qatori kerak'}, status: 400);
            }
            for (final p in parsed) {
              await db.execute(
                'INSERT INTO fh.bom_items (bom_id, item_type, ref_id, ref_barcode, name_snapshot, unit, qty) '
                'VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7)',
                parameters: [bomId, p[0], p[1], p[2], p[3], p[4], p[5]],
              );
            }
          }
          await db.execute('COMMIT');
          return _json({'message': 'Yangilandi'});
        } catch (_) {
          await db.execute('ROLLBACK');
          rethrow;
        }
      } catch (e) {
        print('boms/<id> PUT xato: $e');
        return _json({'error': 'Retseptni yangilashda xatolik yuz berdi'}, status: 500);
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

        // ── Ombor turlarini tekshirish ──
        final srcWh = await db.execute(
          'SELECT name, type, can_expense FROM fh.warehouses WHERE id = \$1 AND is_active',
          parameters: [sourceWarehouseId],
        );
        if (srcWh.isEmpty) return _json({'error': 'Manba ombor topilmadi yoki faol emas'}, status: 404);
        final srcWhName = srcWh.first[0] as String;
        final srcWhType = srcWh.first[1] as String;
        final srcCanExpense = srcWh.first[2] as bool? ?? false;

        final dstWh = await db.execute(
          'SELECT name, type, can_income FROM fh.warehouses WHERE id = \$1 AND is_active',
          parameters: [destWarehouseId],
        );
        if (dstWh.isEmpty) return _json({'error': 'Qabul qiluvchi ombor topilmadi yoki faol emas'}, status: 404);
        final dstWhName = dstWh.first[0] as String;
        final dstWhType = dstWh.first[1] as String;
        final dstCanIncome = dstWh.first[2] as bool? ?? false;

        // BOM bosqichiga mos ombor turlarini tekshirish
        if (stage == 'mixing') {
          const validSrcTypes = ['raw', 'purchased_semi', 'spare_parts', 'production'];
          if (!validSrcTypes.contains(srcWhType)) {
            return _json({'error': "Aralashtirish bosqichi uchun manba ombor turi '$srcWhType' ga mos kelmaydi. Kerakli turlar: xom ashyo, sotib olingan yarim tayyor, yoki ishlab chiqarish"}, status: 400);
          }
          const validDstTypes = ['semi_finished', 'production'];
          if (!validDstTypes.contains(dstWhType)) {
            return _json({'error': "Aralashtirish bosqichi uchun qabul qiluvchi ombor turi '$dstWhType' ga mos kelmaydi. Kerakli turlar: yarim tayyor yoki ishlab chiqarish"}, status: 400);
          }
        } else if (stage == 'packaging') {
          const validDstTypes = ['finished', 'sales'];
          if (!validDstTypes.contains(dstWhType)) {
            return _json({'error': "Qadoqlash bosqichi uchun qabul qiluvchi ombor turi '$dstWhType' ga mos kelmaydi. Kerakli turlar: tayyor mahsulot yoki sotuv"}, status: 400);
          }
        }

        // Ombor imkoniyatlarini tekshirish
        if (!srcCanExpense) {
          return _json({'error': "'$srcWhName' omborida chiqim imkoniyati yoqilmagan"}, status: 400);
        }
        if (!dstCanIncome) {
          return _json({'error': "'$dstWhName' omborida kirim imkoniyati yoqilmagan"}, status: 400);
        }

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
              ''',
              parameters: [sourceWarehouseId, itemType, refId, refBarcode],
            );
            final balance = double.parse(balResult.first[0].toString());
            if (balance < needQty - 0.0001) {
              await db.execute('ROLLBACK');
              return _json({
                'error': "Yetarli emas: $nameSnapshot — kerak ${needQty.toStringAsFixed(3)} $unit, mavjud ${balance.toStringAsFixed(3)}",
                'shortages': [
                  {'name': nameSnapshot, 'needed': needQty, 'available': balance, 'unit': unit}
                ],
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
            'outputItemName': outName,
            'outputQty': totalOutQty,
            'outputUnit': outUnit,
            'destWarehouseName': dstWhName,
          }, status: 201);
        } catch (_) {
          await db.execute('ROLLBACK');
          rethrow;
        }
      } catch (e) {
        print('production/bom/start xato: $e');
        return _json({'error': 'Ishlab chiqarish boshlashda xatolik yuz berdi. Qayta urinib ko\'ring'}, status: 500);
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
        if (!_grantedWhContains(request, warehouseId)) {
          return _json({'error': 'Bu omborga kirish ruxsati yo\'q'}, status: 403);
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

    // ─────────────────────────────────────────────────────────────────────────
    //  SODDALASHTIRILGAN ISHLAB CHIQARISH (MIXING) — default omborlar bilan
    // ─────────────────────────────────────────────────────────────────────────
    // GET /production/mixing/preview?bom_id=&output_quantity=
    get('/production/mixing/preview', (Request request) async {
      try {
        final bomId = int.tryParse(request.url.queryParameters['bom_id'] ?? '');
        final outputQty =
            double.tryParse(request.url.queryParameters['output_quantity'] ?? '');
        if (bomId == null || outputQty == null || outputQty <= 0) {
          return _json({'error': 'bom_id va output_quantity (>0) majburiy'}, status: 400);
        }
        final db = await DatabaseConnection.getConnection();

        final bom = await db.execute(
          'SELECT id, name, stage, output_item_id, output_qty_per_batch, output_unit '
          'FROM fh.boms WHERE id = \$1 AND is_active',
          parameters: [bomId],
        );
        if (bom.isEmpty) return _json({'error': 'Retsept topilmadi'}, status: 404);
        final b = bom.first;
        if (b[2] != 'mixing') {
          return _json({'error': 'Bu retsept aralashtirish bosqichiga tegishli emas'}, status: 400);
        }
        final outItemId = b[3] as int?;
        final perBatch = double.parse(b[4].toString());
        if (perBatch <= 0) return _json({'error': 'Retsept chiqish miqdori noto\'g\'ri'}, status: 400);
        final scale = outputQty / perBatch;

        final outItem = await _itemBrief(db, outItemId);
        if (outItem == null) return _json({'error': 'Chiqish mahsuloti topilmadi'}, status: 404);

        final srcId = await _defaultWarehouseId(db, 'production');
        final dstId = await _defaultWarehouseId(db, 'semi_finished');
        if (srcId == null) {
          return _json({'error': 'Ishlab chiqarish (buffer) ombori belgilanmagan. Ombor sozlamalarida default belgilang.'}, status: 422);
        }
        if (dstId == null) {
          return _json({'error': 'Yarim tayyor mahsulotlar ombori belgilanmagan. Ombor sozlamalarida default belgilang.'}, status: 422);
        }
        final srcName = (await db.execute('SELECT name FROM fh.warehouses WHERE id = \$1', parameters: [srcId])).first[0];
        final dstName = (await db.execute('SELECT name FROM fh.warehouses WHERE id = \$1', parameters: [dstId])).first[0];

        final items = await db.execute(
          'SELECT item_type, ref_id, ref_barcode, name_snapshot, unit, qty FROM fh.bom_items WHERE bom_id = \$1 ORDER BY id',
          parameters: [bomId],
        );
        if (items.isEmpty) return _json({'error': 'Retsept bo\'sh'}, status: 400);

        final required = <Map<String, dynamic>>[];
        final shortages = <Map<String, dynamic>>[];
        for (final it in items) {
          final itemType = it[0] as String;
          final refId = it[1] as int?;
          final refBarcode = it[2] as String?;
          final name = it[3] as String? ?? '';
          final unit = it[4] as String? ?? 'dona';
          final need = double.parse(it[5].toString()) * scale;
          final available = await _stockBalance(db, srcId, itemType, refId, refBarcode);
          final ok = available >= need - 0.0001;
          required.add({'name': name, 'unit': unit, 'needed': need, 'available': available, 'ok': ok});
          if (!ok) shortages.add({'name': name, 'unit': unit, 'needed': need, 'available': available});
        }

        return _json({
          'result': shortages.isEmpty ? 'ok' : 'shortage',
          'stage': 'mixing',
          'outputItem': outItem,
          'outputQty': outputQty,
          'scale': scale,
          'sourceWarehouse': {'id': srcId, 'name': srcName, 'type': 'production'},
          'destWarehouse': {'id': dstId, 'name': dstName, 'type': 'semi_finished'},
          'required': required,
          'shortages': shortages,
        });
      } catch (e) {
        print('mixing/preview xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // POST /production/mixing/start  { bom_id, output_quantity }
    post('/production/mixing/start', (Request request) async {
      if (!Policy.canPlan(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      try {
        final body = await _body(request);
        final bomId = body['bom_id'] as int?;
        final outputQty = (body['output_quantity'] as num?)?.toDouble();
        if (bomId == null || outputQty == null || outputQty <= 0) {
          return _json({'error': 'bom_id va output_quantity (>0) majburiy'}, status: 400);
        }
        final db = await DatabaseConnection.getConnection();

        final bom = await db.execute(
          'SELECT id, name, stage, output_item_id, output_qty_per_batch, output_unit '
          'FROM fh.boms WHERE id = \$1 AND is_active',
          parameters: [bomId],
        );
        if (bom.isEmpty) return _json({'error': 'Retsept topilmadi'}, status: 404);
        final b = bom.first;
        if (b[2] != 'mixing') {
          return _json({'error': 'Bu retsept aralashtirish bosqichiga tegishli emas'}, status: 400);
        }
        final bomName = b[1] as String;
        final outItemId = b[3] as int?;
        final perBatch = double.parse(b[4].toString());
        final outUnit = b[5] as String? ?? 'dona';
        if (perBatch <= 0) return _json({'error': 'Retsept chiqish miqdori noto\'g\'ri'}, status: 400);
        final scale = outputQty / perBatch;

        final outItem = await _itemBrief(db, outItemId);
        if (outItem == null) return _json({'error': 'Chiqish mahsuloti topilmadi'}, status: 404);

        final srcId = await _defaultWarehouseId(db, 'production');
        final dstId = await _defaultWarehouseId(db, 'semi_finished');
        if (srcId == null) {
          return _json({'error': 'Ishlab chiqarish (buffer) ombori belgilanmagan'}, status: 422);
        }
        if (dstId == null) {
          return _json({'error': 'Yarim tayyor mahsulotlar ombori belgilanmagan'}, status: 422);
        }
        final dstName = (await db.execute('SELECT name FROM fh.warehouses WHERE id = \$1', parameters: [dstId])).first[0];

        final items = await db.execute(
          'SELECT item_type, ref_id, ref_barcode, name_snapshot, unit, qty FROM fh.bom_items WHERE bom_id = \$1 ORDER BY id',
          parameters: [bomId],
        );
        if (items.isEmpty) return _json({'error': 'Retsept bo\'sh'}, status: 400);

        // Yetarlilikni oldindan tekshirish (barchasi, to'xtamasdan)
        final shortages = <Map<String, dynamic>>[];
        for (final it in items) {
          final itemType = it[0] as String;
          final refId = it[1] as int?;
          final refBarcode = it[2] as String?;
          final name = it[3] as String? ?? '';
          final unit = it[4] as String? ?? 'dona';
          final need = double.parse(it[5].toString()) * scale;
          final available = await _stockBalance(db, srcId, itemType, refId, refBarcode);
          if (available < need - 0.0001) {
            shortages.add({'name': name, 'unit': unit, 'needed': need, 'available': available});
          }
        }
        if (shortages.isNotEmpty) {
          return _json({
            'error': 'Xom ashyo yetarli emas',
            'shortages': shortages,
          }, status: 422);
        }

        final planned = outputQty.round();
        final uid = _uid(request);

        await db.execute('BEGIN');
        try {
          for (final it in items) {
            final itemType = it[0] as String;
            final refId = it[1] as int?;
            final refBarcode = it[2] as String?;
            final name = it[3] as String? ?? '';
            final unit = it[4] as String? ?? 'dona';
            final need = double.parse(it[5].toString()) * scale;
            await db.execute(
              '''
              INSERT INTO fh.stock_ledger
                (warehouse_id, item_type, ref_id, ref_barcode, name_snapshot, unit,
                 direction, qty, source_type, source_ref, performed_by, note)
              VALUES (\$1, \$2, \$3, \$4, \$5, \$6, 'out', \$7, 'production_consume', \$8, \$9, \$10)
              ''',
              parameters: [
                srcId, itemType, refId, refBarcode, name, unit,
                need, 'mixing:$bomId', uid, '$bomName ($outputQty $outUnit)',
              ],
            );
          }

          final batch = await db.execute(
            'INSERT INTO fh.production_batches '
            '(product_barcode, bom_id, stage, planned_qty, produced_qty, status, '
            ' source_warehouse_id, dest_warehouse_id, started_by) '
            'VALUES (\$1, \$2, \'mixing\', \$3, \$3, \'in_progress\', \$4, \$5, \$6) RETURNING id',
            parameters: [outItem['name'], bomId, planned, srcId, dstId, uid],
          );
          final batchId = batch.first[0];

          final tr = await db.execute(
            'INSERT INTO fh.stock_transfers '
            '(item_id, quantity, unit, source_warehouse_id, dest_warehouse_id, '
            ' production_batch_id, status, created_by) '
            'VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \'pending\', \$7) RETURNING id',
            parameters: [outItemId, outputQty, outUnit, srcId, dstId, batchId, uid],
          );
          final transferId = tr.first[0];

          await db.execute('UPDATE fh.production_batches SET transfer_id = \$1 WHERE id = \$2',
            parameters: [transferId, batchId]);

          await db.execute('COMMIT');
          return _json({
            'message': 'Aralashtirish boshlandi. Natija qabul qiluvchi ombor tasdiqlashini kutmoqda.',
            'batchId': batchId,
            'transferId': transferId,
            'outputItemName': outItem['name'],
            'outputQty': outputQty,
            'outputUnit': outUnit,
            'destWarehouseName': dstName,
            'pending': true,
          }, status: 201);
        } catch (e) {
          await db.execute('ROLLBACK');
          rethrow;
        }
      } catch (e) {
        print('mixing/start xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ─────────────────────────────────────────────────────────────────────────
    //  QADOQLASH (PACKAGING) — semi_finished + packaging manbalari
    // ─────────────────────────────────────────────────────────────────────────
    // GET /production/packaging/preview?bom_id=&output_quantity=
    get('/production/packaging/preview', (Request request) async {
      try {
        final bomId = int.tryParse(request.url.queryParameters['bom_id'] ?? '');
        final outputQty =
            double.tryParse(request.url.queryParameters['output_quantity'] ?? '');
        if (bomId == null || outputQty == null || outputQty <= 0) {
          return _json({'error': 'bom_id va output_quantity (>0) majburiy'}, status: 400);
        }
        final db = await DatabaseConnection.getConnection();

        final bom = await db.execute(
          'SELECT id, name, stage, output_item_id, output_qty_per_batch, output_unit '
          'FROM fh.boms WHERE id = \$1 AND is_active',
          parameters: [bomId],
        );
        if (bom.isEmpty) return _json({'error': 'Retsept topilmadi'}, status: 404);
        final b = bom.first;
        if (b[2] != 'packaging') {
          return _json({'error': 'Bu retsept qadoqlash bosqichiga tegishli emas'}, status: 400);
        }
        final outItemId = b[3] as int?;
        final perBatch = double.parse(b[4].toString());
        if (perBatch <= 0) return _json({'error': 'Retsept chiqish miqdori noto\'g\'ri'}, status: 400);
        final scale = outputQty / perBatch;

        final outItem = await _itemBrief(db, outItemId);
        if (outItem == null) return _json({'error': 'Chiqish mahsuloti topilmadi'}, status: 404);

        final semiId = await _defaultWarehouseId(db, 'semi_finished');
        final pkgId = await _defaultWarehouseId(db, 'packaging');
        if (semiId == null) {
          return _json({'error': 'Yarim tayyor mahsulotlar ombori belgilanmagan'}, status: 422);
        }
        if (pkgId == null) {
          return _json({'error': 'Qadoqlash materiallari ombori belgilanmagan'}, status: 422);
        }
        Future<String?> whName(int id) async =>
            (await db.execute('SELECT name FROM fh.warehouses WHERE id = \$1', parameters: [id])).first[0] as String?;

        final items = await db.execute(
          'SELECT item_type, ref_id, ref_barcode, name_snapshot, unit, qty FROM fh.bom_items WHERE bom_id = \$1 ORDER BY id',
          parameters: [bomId],
        );
        if (items.isEmpty) return _json({'error': 'Retsept bo\'sh'}, status: 400);

        final required = <Map<String, dynamic>>[];
        final shortages = <Map<String, dynamic>>[];
        for (final it in items) {
          final itemType = it[0] as String;
          final refId = it[1] as int?;
          final refBarcode = it[2] as String?;
          final name = it[3] as String? ?? '';
          final unit = it[4] as String? ?? 'dona';
          final need = double.parse(it[5].toString()) * scale;
          var isPkg = itemType == 'packaging';
          if (!isPkg && refId != null) {
            final ref = await _itemBrief(db, refId);
            if (ref != null && ref['itemType'] == 'packaging') isPkg = true;
          }
          final useId = isPkg ? pkgId : semiId;
          final available = await _stockBalance(db, useId, itemType, refId, refBarcode);
          final ok = available >= need - 0.0001;
          required.add({'name': name, 'unit': unit, 'needed': need, 'available': available, 'ok': ok, 'group': isPkg ? 'packaging' : 'semi_finished'});
          if (!ok) shortages.add({'name': name, 'unit': unit, 'needed': need, 'available': available, 'group': isPkg ? 'packaging' : 'semi_finished'});
        }

        final finished = await db.execute(
          'SELECT id, name FROM fh.warehouses WHERE type = \'finished\' AND is_active ORDER BY id');

        return _json({
          'result': shortages.isEmpty ? 'ok' : 'shortage',
          'stage': 'packaging',
          'outputItem': outItem,
          'outputQty': outputQty,
          'scale': scale,
          'sourceSemi': {'id': semiId, 'name': await whName(semiId), 'type': 'semi_finished'},
          'sourcePackaging': {'id': pkgId, 'name': await whName(pkgId), 'type': 'packaging'},
          'finishedWarehouses': finished.map((r) => {'id': r[0], 'name': r[1]}).toList(),
          'required': required,
          'shortages': shortages,
        });
      } catch (e) {
        print('packaging/preview xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // POST /production/packaging/start  { bom_id, output_quantity, dest_warehouse_id }
    post('/production/packaging/start', (Request request) async {
      if (!Policy.canPlan(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      try {
        final body = await _body(request);
        final bomId = body['bom_id'] as int?;
        final outputQty = (body['output_quantity'] as num?)?.toDouble();
        final destWarehouseId = body['dest_warehouse_id'] as int?;
        if (bomId == null || outputQty == null || outputQty <= 0 || destWarehouseId == null) {
          return _json({'error': 'bom_id, output_quantity (>0), dest_warehouse_id majburiy'}, status: 400);
        }
        final db = await DatabaseConnection.getConnection();

        final bom = await db.execute(
          'SELECT id, name, stage, output_item_id, output_qty_per_batch, output_unit '
          'FROM fh.boms WHERE id = \$1 AND is_active',
          parameters: [bomId],
        );
        if (bom.isEmpty) return _json({'error': 'Retsept topilmadi'}, status: 404);
        final b = bom.first;
        if (b[2] != 'packaging') {
          return _json({'error': 'Bu retsept qadoqlash bosqichiga tegishli emas'}, status: 400);
        }
        final bomName = b[1] as String;
        final outItemId = b[3] as int?;
        final perBatch = double.parse(b[4].toString());
        final outUnit = b[5] as String? ?? 'dona';
        if (perBatch <= 0) return _json({'error': 'Retsept chiqish miqdori noto\'g\'ri'}, status: 400);
        final scale = outputQty / perBatch;

        final outItem = await _itemBrief(db, outItemId);
        if (outItem == null) return _json({'error': 'Chiqish mahsuloti topilmadi'}, status: 404);

        // Qabul qiluvchi ombor turi 'finished' bo'lishi shart
        final dst = await db.execute(
          'SELECT name, type FROM fh.warehouses WHERE id = \$1 AND is_active', parameters: [destWarehouseId]);
        if (dst.isEmpty) return _json({'error': 'Qabul qiluvchi ombor topilmadi'}, status: 404);
        if (dst.first[1] != 'finished') {
          return _json({'error': 'Qadoqlash natijasi faqat tayyor mahsulot (finished) omboriga qabul qilinadi'}, status: 400);
        }
        final dstName = dst.first[0] as String;

        final semiId = await _defaultWarehouseId(db, 'semi_finished');
        final pkgId = await _defaultWarehouseId(db, 'packaging');
        if (semiId == null || pkgId == null) {
          return _json({'error': 'Yarim tayyor yoki qadoqlash materiallari ombori belgilanmagan'}, status: 422);
        }
        final srcName = (await db.execute(
          'SELECT name FROM fh.warehouses WHERE id = \$1', parameters: [semiId])).first[0] as String;

        final items = await db.execute(
          'SELECT item_type, ref_id, ref_barcode, name_snapshot, unit, qty FROM fh.bom_items WHERE bom_id = \$1 ORDER BY id',
          parameters: [bomId],
        );
        if (items.isEmpty) return _json({'error': 'Retsept bo\'sh'}, status: 400);

        // Yetarlilik (ikkala manba bo'yicha)
        final shortages = <Map<String, dynamic>>[];
        for (final it in items) {
          final itemType = it[0] as String;
          final refId = it[1] as int?;
          final refBarcode = it[2] as String?;
          final name = it[3] as String? ?? '';
          final unit = it[4] as String? ?? 'dona';
          final need = double.parse(it[5].toString()) * scale;
          final isPkg = itemType == 'packaging';
          final useId = isPkg ? pkgId : semiId;
          final available = await _stockBalance(db, useId, itemType, refId, refBarcode);
          if (available < need - 0.0001) {
            shortages.add({'name': name, 'unit': unit, 'needed': need, 'available': available, 'group': isPkg ? 'packaging' : 'semi_finished'});
          }
        }
        if (shortages.isNotEmpty) {
          return _json({'error': 'Materiallar yetarli emas', 'shortages': shortages}, status: 422);
        }

        final planned = outputQty.round();
        final uid = _uid(request);

        await db.execute('BEGIN');
        try {
          for (final it in items) {
            final itemType = it[0] as String;
            final refId = it[1] as int?;
            final refBarcode = it[2] as String?;
            final name = it[3] as String? ?? '';
            final unit = it[4] as String? ?? 'dona';
            final need = double.parse(it[5].toString()) * scale;
            final isPkg = itemType == 'packaging';
            final useId = isPkg ? pkgId : semiId;
            await db.execute(
              '''
              INSERT INTO fh.stock_ledger
                (warehouse_id, item_type, ref_id, ref_barcode, name_snapshot, unit,
                 direction, qty, source_type, source_ref, performed_by, note)
              VALUES (\$1, \$2, \$3, \$4, \$5, \$6, 'out', \$7, 'production_consume', \$8, \$9, \$10)
              ''',
              parameters: [
                useId, itemType, refId, refBarcode, name, unit,
                need, 'packaging:$bomId', uid, '$bomName ($outputQty $outUnit)',
              ],
            );
          }

          final batch = await db.execute(
            'INSERT INTO fh.production_batches '
            '(product_barcode, bom_id, stage, planned_qty, produced_qty, status, '
            ' source_warehouse_id, dest_warehouse_id, started_by) '
            'VALUES (\$1, \$2, \'packaging\', \$3, \$3, \'in_progress\', \$4, \$5, \$6) RETURNING id',
            parameters: [outItem['name'], bomId, planned, semiId, destWarehouseId, uid],
          );
          final batchId = batch.first[0];

          final tr = await db.execute(
            'INSERT INTO fh.stock_transfers '
            '(item_id, quantity, unit, source_warehouse_id, dest_warehouse_id, '
            ' production_batch_id, status, created_by) '
            'VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \'pending\', \$7) RETURNING id',
            parameters: [outItemId, outputQty, outUnit, semiId, destWarehouseId, batchId, uid],
          );
          final transferId = tr.first[0];

          await db.execute('UPDATE fh.production_batches SET transfer_id = \$1 WHERE id = \$2',
            parameters: [transferId, batchId]);

          await db.execute('COMMIT');
          return _json({
            'message': 'Qadoqlash boshlandi. Natija qabul qiluvchi ombor tasdiqlashini kutmoqda.',
            'batchId': batchId,
            'transferId': transferId,
            'outputItemName': outItem['name'],
            'outputQty': outputQty,
            'outputUnit': outUnit,
            'sourceWarehouseName': srcName,
            'destWarehouseName': dstName,
            'pending': true,
          }, status: 201);
        } catch (e) {
          await db.execute('ROLLBACK');
          rethrow;
        }
      } catch (e) {
        print('packaging/start xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ─────────────────────────────────────────────────────────────────────────
    //  TASDIQLASH ZANJIRI (pending transfers: confirm / reject)
// ─────────────────────────────────────────────────────────────────────────
    //  TASDIQLASH ZANJIRI (pending transfers: confirm / reject)
    // ─────────────────────────────────────────────────────────────────────────
    // POST /transfers/<id>/confirm
    post('/transfers/<id>/confirm', (Request request, String id) async {
      if (!Policy.canTransactStock(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      final transferId = int.tryParse(id);
      if (transferId == null) return _json({'error': "Noto'g'ri ID"}, status: 400);
      try {
        final db = await DatabaseConnection.getConnection();
        final tr = await db.execute(
          'SELECT id, item_id, quantity, unit, source_warehouse_id, dest_warehouse_id, '
          'production_batch_id, status FROM fh.stock_transfers WHERE id = \$1',
          parameters: [transferId],
        );
        if (tr.isEmpty) return _json({'error': 'O\'tkazma topilmadi'}, status: 404);
        final r = tr.first;
        if (r[7] != 'pending') {
          return _json({'error': 'Bu o\'tkazma allaqachon hal qilingan'}, status: 409);
        }
        final destId = (r[5] as num).toInt();
        if (!_grantedWhContains(request, destId)) {
          return _json({'error': 'Bu omborga kirish ruxsati yo\'q'}, status: 403);
        }
        final itemId = r[1] as int;
        final qty = double.parse(r[2].toString());
        final unit = r[3] as String;
        final batchId = r[6] as int?;
        final srcId = r[4] as int?;
        final item = await _resolveItem(db, itemId, srcId) ?? <String, dynamic>{'name': 'Mahsulot'};
        final uid = _uid(request);

        await db.execute('BEGIN');
        try {
          // Qo'lda (batchsiz) o'tkazmalarda manba chiqimi faqat confirm vaqtida
          // yoziladi — send balansga tegmaydi. Eski qoidalar bilan yuborilgan
          // o'tkazmalarda chiqim allaqachon bor, qayta yozilmaydi.
          if (batchId == null && srcId != null) {
            final outExists = await db.execute(
              "SELECT 1 FROM fh.stock_ledger WHERE warehouse_id = \$1 AND source_ref = \$2::text "
              "AND direction = 'out' AND source_type = 'transfer_out' LIMIT 1",
              parameters: [srcId, transferId],
            );
            if (outExists.isEmpty) {
              await db.execute(
                '''
                INSERT INTO fh.stock_ledger
                  (warehouse_id, item_type, ref_id, ref_barcode, name_snapshot, unit,
                   direction, qty, source_type, source_ref, performed_by, note)
                VALUES (\$1, \$2, \$3, NULL, \$4, \$5, 'out', \$6, 'transfer_out', \$7::text, \$8, \$9)
                ''',
                parameters: [
                  srcId, (item['itemType'] as String?) ?? 'item', itemId, item['name'], unit,
                  qty, transferId, uid, 'Transfer #$transferId',
                ],
              );
            }
          }
          await db.execute(
            '''
            INSERT INTO fh.stock_ledger
              (warehouse_id, item_type, ref_id, ref_barcode, name_snapshot, unit,
               direction, qty, source_type, source_ref, performed_by, note)
            VALUES (\$1, \$2, \$3, NULL, \$4, \$5, 'in', \$6, 'transfer_in', \$7::text, \$8, \$9)
            ''',
            parameters: [
              destId, (item['itemType'] as String?) ?? 'item', itemId, item['name'], unit,
              qty, transferId, uid, 'Transfer #$transferId',
            ],
          );
          await db.execute(
            'UPDATE fh.stock_transfers SET status = \'confirmed\', confirmed_by = \$1, confirmed_at = now() WHERE id = \$2',
            parameters: [uid, transferId],
          );
          if (batchId != null) {
            await db.execute(
              'UPDATE fh.production_batches SET status = \'completed\', completed_at = now() WHERE id = \$1 AND status = \'in_progress\'',
              parameters: [batchId],
            );
          }
          await db.execute('COMMIT');
          return _json({'message': 'Qabul qilindi, ombor balansiga qo\'shildi', 'transferId': transferId});
        } catch (e) {
          await db.execute('ROLLBACK');
          rethrow;
        }
      } catch (e) {
        print('transfers confirm xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // POST /transfers/<id>/reject  { reason }
    post('/transfers/<id>/reject', (Request request, String id) async {
      if (!Policy.canTransactStock(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      final transferId = int.tryParse(id);
      if (transferId == null) return _json({'error': "Noto'g'ri ID"}, status: 400);
      try {
        final body = await _body(request);
        final reason = (body['reason'] as String?)?.trim();
        if (reason == null || reason.isEmpty) {
          return _json({'error': 'Rad etish sababi majburiy'}, status: 400);
        }
        final db = await DatabaseConnection.getConnection();
        final tr = await db.execute(
          'SELECT id, item_id, quantity, unit, source_warehouse_id, dest_warehouse_id, '
          'production_batch_id, status FROM fh.stock_transfers WHERE id = \$1',
          parameters: [transferId],
        );
        if (tr.isEmpty) return _json({'error': 'O\'tkazma topilmadi'}, status: 404);
        final r = tr.first;
        if (r[7] != 'pending') {
          return _json({'error': 'Bu o\'tkazma allaqachon hal qilingan'}, status: 409);
        }
        final destId = (r[5] as num).toInt();
        if (!_grantedWhContains(request, destId)) {
          return _json({'error': 'Bu omborga kirish ruxsati yo\'q'}, status: 403);
        }
        final srcId = r[4] as int?;
        final itemId = r[1] as int;
        final qty = double.parse(r[2].toString());
        final unit = r[3] as String;
        final batchId = r[6] as int?;
        final item = await _resolveItem(db, itemId, srcId) ?? <String, dynamic>{'name': 'Mahsulot'};
        final uid = _uid(request);

        // Rad etilgan miqdor qayerga: qo'lda yuborilgan (production_batch_id=null)
        // manba omboriga qaytadi; ishlab chiqarish/qadoqlash natijasi bo'lsa
        // Brak/nikoz omboriga tushadi.
        int? reverseDestId = srcId;
        String reverseType = 'reject_reverse';
        if (batchId != null) {
          reverseDestId = await _defaultWarehouseId(db, 'defective');
          if (reverseDestId == null) {
            return _json({'error': 'Brak/nikoz ombori topilmadi'}, status: 422);
          }
          reverseType = 'reject_to_defective';
        }

        await db.execute('BEGIN');
        try {
          // Qo'lda (batchsiz) o'tkazmalarda chiqim send paytida yozilmasa,
          // rad etish hech narsani qaytarmaydi. Eski qoidalar bilan yuborilgan
          // (chiqim send'da bor) o'tkazmalar rad etilganda manbaga qaytadi.
          if (batchId != null) {
            await db.execute(
              '''
              INSERT INTO fh.stock_ledger
                (warehouse_id, item_type, ref_id, ref_barcode, name_snapshot, unit,
                 direction, qty, source_type, source_ref, performed_by, note)
              VALUES (\$1, \$2, \$3, NULL, \$4, \$5, 'in', \$6, \$7, \$8::text, \$9, \$10)
              ''',
              parameters: [
                reverseDestId, (item['itemType'] as String?) ?? 'item', itemId, item['name'], unit, qty,
                reverseType, transferId, uid, 'Rad etildi: $reason',
              ],
            );
          } else if (srcId != null) {
            final outExists = await db.execute(
              "SELECT 1 FROM fh.stock_ledger WHERE warehouse_id = \$1 AND source_ref = \$2::text "
              "AND direction = 'out' AND source_type = 'transfer_out' LIMIT 1",
              parameters: [srcId, transferId],
            );
            if (outExists.isNotEmpty) {
              await db.execute(
                '''
                INSERT INTO fh.stock_ledger
                  (warehouse_id, item_type, ref_id, ref_barcode, name_snapshot, unit,
                   direction, qty, source_type, source_ref, performed_by, note)
                VALUES (\$1, \$2, \$3, NULL, \$4, \$5, 'in', \$6, 'reject_reverse', \$7::text, \$8, \$9)
                ''',
                parameters: [
                  reverseDestId, (item['itemType'] as String?) ?? 'item', itemId, item['name'], unit, qty,
                  transferId, uid, 'Rad etildi: $reason',
                ],
              );
            }
          }
          await db.execute(
            'UPDATE fh.stock_transfers SET status = \'rejected\', reject_reason = \$1, '
            'confirmed_by = \$2, confirmed_at = now() WHERE id = \$3',
            parameters: [reason, uid, transferId],
          );
          if (batchId != null) {
            await db.execute(
              'UPDATE fh.production_batches SET status = \'cancelled\' WHERE id = \$1 AND status = \'in_progress\'',
              parameters: [batchId],
            );
          }
          await db.execute('COMMIT');
          return _json({'message': 'O\'tkazma rad etildi', 'transferId': transferId});
        } catch (e) {
          await db.execute('ROLLBACK');
          rethrow;
        }
      } catch (e) {
        print('transfers reject xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ─────────────────────────────────────────────────────────────────────────
    //  KARANTIN TEKSHIRUVI (inspections)
    // ─────────────────────────────────────────────────────────────────────────
    // POST /inspections/receive  { item_id, quantity, unit?, quarantine_warehouse_id, note? }
    post('/inspections/receive', (Request request) async {
      if (!Policy.canTransactStock(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      try {
        final body = await _body(request);
        final itemId = body['item_id'] as int?;
        final qty = (body['quantity'] as num?)?.toDouble();
        final unit = body['unit'] as String? ?? 'dona';
        final whId = body['quarantine_warehouse_id'] as int?;
        final note = body['note'] as String?;
        if (itemId == null || qty == null || qty <= 0 || whId == null) {
          return _json({'error': 'item_id, quantity (>0), quarantine_warehouse_id majburiy'}, status: 400);
        }
        final db = await DatabaseConnection.getConnection();
        final item = await _itemBrief(db, itemId);
        if (item == null) return _json({'error': 'Mahsulot (item) topilmadi'}, status: 404);
        final wh = await db.execute(
          'SELECT type FROM fh.warehouses WHERE id = \$1 AND is_active', parameters: [whId]);
        if (wh.isEmpty) return _json({'error': 'Ombor topilmadi'}, status: 404);
        if (wh.first[0] != 'quarantine') {
          return _json({'error': 'Qabul faqat karantin omboriga qilinadi'}, status: 400);
        }
        if (!_grantedWhContains(request, whId)) {
          return _json({'error': 'Bu omborga kirish ruxsati yo\'q'}, status: 403);
        }
        final uid = _uid(request);

        await db.execute('BEGIN');
        try {
          final led = await db.execute(
            '''
            INSERT INTO fh.stock_ledger
              (warehouse_id, item_type, ref_id, ref_barcode, name_snapshot, unit,
               direction, qty, source_type, source_ref, performed_by, note)
            VALUES (\$1, \$2, \$3, NULL, \$4, \$5, 'in', \$6, 'inspection_in', \$7, \$8, \$9)
            RETURNING id
            ''',
            parameters: [whId, (item['itemType'] as String?) ?? 'item', itemId, item['name'], unit, qty, 'inspection:receive', uid, note],
          );
          final ledgerId = led.first[0];
          final insp = await db.execute(
            'INSERT INTO fh.inspections '
            '(item_id, quantity, unit, quarantine_warehouse_id, source_ledger_id, status) '
            'VALUES (\$1, \$2, \$3, \$4, \$5, \'pending\') RETURNING id',
            parameters: [itemId, qty, unit, whId, ledgerId],
          );
          await db.execute('COMMIT');
          return _json({
            'message': 'Karantinga qabul qilindi, tekshiruv kutilmoqda',
            'inspectionId': insp.first[0],
          }, status: 201);
        } catch (e) {
          await db.execute('ROLLBACK');
          rethrow;
        }
      } catch (e) {
        print('inspections receive xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // GET /inspections/pending?warehouse_id=
    get('/inspections/pending', (Request request) async {
      try {
        final warehouseId =
            int.tryParse(request.url.queryParameters['warehouse_id'] ?? '');
        if (warehouseId == null) {
          return _json({'error': 'warehouse_id majburiy'}, status: 400);
        }
        final db = await DatabaseConnection.getConnection();
        final result = await db.execute(
          '''
          SELECT i.id, i.item_id, it.name AS item_name, i.unit, i.quantity,
                 i.quarantine_warehouse_id, w.name AS wh_name, i.created_at, i.note
          FROM fh.inspections i
          JOIN fh.items it ON it.id = i.item_id
          JOIN fh.warehouses w ON w.id = i.quarantine_warehouse_id
          WHERE i.quarantine_warehouse_id = \$1 AND i.status = 'pending'
          ORDER BY i.created_at ASC
          ''',
          parameters: [warehouseId],
        );
        return _json({
          'inspections': result.map((r) => {
            'id': r[0], 'itemId': r[1], 'itemName': r[2], 'unit': r[3],
            'quantity': r[4]?.toString(),
            'warehouseId': r[5], 'warehouseName': r[6],
            'createdAt': r[7]?.toString(), 'note': r[8],
          }).toList(),
        });
      } catch (e) {
        print('inspections/pending xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // POST /inspections/<id>/decide  { result: approved|rejected, note? }
    post('/inspections/<id>/decide', (Request request, String id) async {
      if (!Policy.canTransactStock(_role(request))) {
        return _json({'error': 'Ruxsat yoq'}, status: 403);
      }
      final inspectionId = int.tryParse(id);
      if (inspectionId == null) return _json({'error': "Noto'g'ri ID"}, status: 400);
      try {
        final body = await _body(request);
        final result = body['result'] as String?;
        final note = body['note'] as String?;
        if (result == null || !['approved', 'rejected'].contains(result)) {
          return _json({'error': 'result: approved|rejected kerak'}, status: 400);
        }
        final db = await DatabaseConnection.getConnection();
        final insp = await db.execute(
          'SELECT id, item_id, quantity, unit, quarantine_warehouse_id, status '
          'FROM fh.inspections WHERE id = \$1',
          parameters: [inspectionId],
        );
        if (insp.isEmpty) return _json({'error': 'Tekshiruv topilmadi'}, status: 404);
        final r = insp.first;
        if (r[5] != 'pending') {
          return _json({'error': 'Bu tekshiruv allaqachon hal qilingan'}, status: 409);
        }
        final qWhId = (r[4] as num).toInt();
        if (!_grantedWhContains(request, qWhId)) {
          return _json({'error': 'Bu omborga kirish ruxsati yo\'q'}, status: 403);
        }
        final itemId = r[1] as int;
        final qty = double.parse(r[2].toString());
        final unit = r[3] as String;
        final item = await _resolveItem(db, itemId, qWhId) ?? <String, dynamic>{'name': 'Mahsulot'};
        final uid = _uid(request);

        // approved → Xom-ashyo ombori, rejected → Brak/nikoz ombori
        final destType = result == 'approved' ? 'raw' : 'defective';
        final destId = await _defaultWarehouseId(db, destType);
        if (destId == null) {
          return _json({'error': result == 'approved' ? 'Xom-ashyo ombori topilmadi' : 'Brak/nikoz ombori topilmadi'}, status: 422);
        }

        await db.execute('BEGIN');
        try {
          // Karantindan chiqim
          await db.execute(
            '''
            INSERT INTO fh.stock_ledger
              (warehouse_id, item_type, ref_id, ref_barcode, name_snapshot, unit,
               direction, qty, source_type, source_ref, performed_by, note)
            VALUES (\$1, \$2, \$3, NULL, \$4, \$5, 'out', \$6, 'inspection_out', \$7::text, \$8, \$9)
            ''',
            parameters: [qWhId, (item['itemType'] as String?) ?? 'item', itemId, item['name'], unit, qty, inspectionId, uid, note],
          );
          // Manzil omboriga kirim (approved → raw, rejected → defective)
          await db.execute(
            '''
            INSERT INTO fh.stock_ledger
              (warehouse_id, item_type, ref_id, ref_barcode, name_snapshot, unit,
               direction, qty, source_type, source_ref, performed_by, note)
            VALUES (\$1, \$2, \$3, NULL, \$4, \$5, 'in', \$6, 'inspection_in', \$7::text, \$8, \$9)
            ''',
            parameters: [destId, (item['itemType'] as String?) ?? 'item', itemId, item['name'], unit, qty, inspectionId, uid, note],
          );
          // Qaror tasdiq hisoblanadi — konfirmatsiya kutilmaydi
          final tr = await db.execute(
            'INSERT INTO fh.stock_transfers '
            '(item_id, quantity, unit, source_warehouse_id, dest_warehouse_id, '
            ' status, created_by, confirmed_by, confirmed_at) '
            'VALUES (\$1, \$2, \$3, \$4, \$5, \'confirmed\', \$6, \$6, now()) RETURNING id',
            parameters: [itemId, qty, unit, qWhId, destId, uid],
          );
          final transferId = tr.first[0];
          await db.execute(
            'UPDATE fh.inspections SET status = \$1, inspected_by = \$2, inspected_at = now(), '
            'note = \$3, resulting_transfer_id = \$4 WHERE id = \$5',
            parameters: [result, uid, note, transferId, inspectionId],
          );
          await db.execute('COMMIT');
          return _json({
            'message': result == 'approved' ? 'Tasdiqlandi, Xom-ashyo omboriga yo\'naltirildi' : 'Rad etildi, Brak/nikoz omboriga yo\'naltirildi',
            'inspectionId': inspectionId,
            'transferId': transferId,
            'destWarehouseId': destId,
          });
        } catch (e) {
          await db.execute('ROLLBACK');
          rethrow;
        }
      } catch (e) {
        print('inspections decide xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
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
          'SELECT product_barcode, status, bom_id, stage FROM fh.production_batches WHERE id = \$1',
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
        final bomId = batch[2] as int?;

        await db.execute('BEGIN');
        try {
          if (action == 'complete') {
            if (bomId != null) {
              // BOM-based production: use output_item_id from BOM
              final bomRow = await db.execute(
                'SELECT output_item_id, output_qty_per_batch, output_unit FROM fh.boms WHERE id = \$1',
                parameters: [bomId],
              );
              if (bomRow.isEmpty) {
                await db.execute('ROLLBACK');
                return _json({'error': 'Retsept topilmadi'}, status: 404);
              }
              final outputItemId = bomRow.first[0] as int?;
              final outputUnit = bomRow.first[2] as String? ?? 'dona';

              final outItem = await db.execute(
                'SELECT name FROM fh.items WHERE id = \$1',
                parameters: [outputItemId],
              );
              final outName = outItem.isNotEmpty ? outItem.first[0] as String : 'Mahsulot';

              // Get dest warehouse name
              final destWh = await db.execute(
                'SELECT name FROM fh.warehouses WHERE id = \$1',
                parameters: [finishedWarehouseId],
              );
              final destWhName = destWh.isNotEmpty ? destWh.first[0] as String : 'Ombor';

              await db.execute(
                '''
                INSERT INTO fh.stock_ledger
                  (warehouse_id, item_type, ref_id, ref_barcode, name_snapshot, unit,
                   direction, qty, source_type, source_ref, performed_by)
                VALUES (\$1, 'item', \$2, NULL, \$3, \$4, 'in', \$5, 'production_in', \$6, \$7)
                ''',
                parameters: [
                  finishedWarehouseId, outputItemId, outName, outputUnit,
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

              await db.execute('COMMIT');
              return _json({
                'message': 'Yakunlandi',
                'outputItemName': outName,
                'outputQty': producedQty,
                'outputUnit': outputUnit,
                'destWarehouseName': destWhName,
              });
            } else {
              // Legacy production: use public.products
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

              await db.execute('COMMIT');
              return _json({'message': 'Yakunlandi'});
            }
          } else {
            // Cancel: reversal for BOM-based batches
            if (bomId != null) {
              // Reverse stock_ledger entries for this batch
              final ledgerEntries = await db.execute(
                '''SELECT id, warehouse_id, item_type, ref_id, ref_barcode, name_snapshot, unit, direction, qty, source_type
                   FROM fh.stock_ledger WHERE source_ref = \$1''',
                parameters: [batchId.toString()],
              );
              for (final entry in ledgerEntries) {
                final entryWarehouseId = entry[1];
                final entryItemType = entry[2];
                final entryRefId = entry[3];
                final entryRefBarcode = entry[4];
                final entryNameSnapshot = entry[5];
                final entryUnit = entry[6];
                final entryDirection = entry[7];
                final entryQty = entry[8];
                final entrySourceType = entry[9];
                // Create reversal entry
                final reversalDirection = entryDirection == 'in' ? 'out' : 'in';
                final reversalSourceType = entrySourceType == 'production_in' ? 'production_out' : 'production_in';
                await db.execute(
                  '''
                  INSERT INTO fh.stock_ledger
                    (warehouse_id, item_type, ref_id, ref_barcode, name_snapshot, unit,
                     direction, qty, source_type, source_ref, performed_by, note)
                  VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$8, \$9, \$10, \$11)
                  ''',
                  parameters: [
                    entryWarehouseId, entryItemType, entryRefId, entryRefBarcode,
                    entryNameSnapshot, entryUnit, reversalDirection, entryQty,
                    reversalSourceType, batchId.toString(), _uid(request),
                    'Bekor qilish — reversal #$batchId',
                  ],
                );
              }
            }

            await db.execute(
              "UPDATE fh.production_batches SET status = 'cancelled', completed_at = now() "
              'WHERE id = \$1',
              parameters: [batchId],
            );

            await db.execute('COMMIT');
            return _json({'message': 'Bekor qilindi'});
          }
        } catch (_) {
          await db.execute('ROLLBACK');
          rethrow;
        }
      } catch (e) {
        print('production/:id xato: $e');
        return _json({'error': 'Partiya holatini yangilashda xatolik. Qayta urinib ko\'ring'}, status: 500);
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

    _registerHrRoutes();
  }
}

// ============================================================
// HR MODULI — xodimlar, davomat, premiya/jarima/avans, hisobot
// Ruxsatlar: admin/hr_manager — to''liq; director — faqat ko''rish.
// ============================================================
extension _HrRoutes on Router {
  void _registerHrRoutes() {
    bool _canRead(Request r) => Policy.canReadHr(_role(r));
    bool _canManage(Request r) => Policy.canManageHr(_role(r));

    // ───────────────────────── XODIMLAR ─────────────────────────
    get('/hr/employees', (Request request) async {
      if (!_canRead(request)) return _json({'error': 'Ruxsat yoq'}, status: 403);
      try {
        final status = request.url.queryParameters['status'];
        final department = request.url.queryParameters['department'];
        final search = request.url.queryParameters['search'];
        final params = <dynamic>[];
        var where = 'TRUE';
        if (status != null && status.isNotEmpty) {
          params.add(status);
          where += ' AND status = \$${params.length}';
        }
        if (department != null && department.isNotEmpty) {
          params.add(department);
          where += ' AND department = \$${params.length}';
        }
        if (search != null && search.isNotEmpty) {
          params.add('%$search%');
          where += ' AND full_name ILIKE \$${params.length}';
        }
        final db = await DatabaseConnection.getConnection();
        final res = await db.execute(
          'SELECT id, full_name, position, department, phone, hire_date, '
          'termination_date, status, base_salary, note '
          'FROM fh.employees WHERE ${where} ORDER BY full_name',
          parameters: params,
        );
        return _json({
          'employees': res.map((r) => Employee.fromRow(r).toJson()).toList(),
        });
      } catch (e) {
        print('hr employees GET xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    post('/hr/employees', (Request request) async {
      if (!_canManage(request)) return _json({'error': 'Ruxsat yoq'}, status: 403);
      try {
        final body = await _body(request);
        final fullName = (body['fullName'] as String?)?.trim();
        if (fullName == null || fullName.isEmpty) {
          return _json({'error': 'fullName majburiy'}, status: 400);
        }
final dateStr = body['hireDate'] as String?;
        final hireDate = (dateStr == null || dateStr.isEmpty)
            ? DateTime.now().toIso8601String().substring(0, 10)
            : dateStr;
        final salary = (body['baseSalary'] as num?)?.toDouble();
        final db = await DatabaseConnection.getConnection();
        final res = await db.execute(
          '''INSERT INTO fh.employees
             (full_name, position, department, phone, hire_date, status, base_salary, note)
             VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8)
             RETURNING id, full_name, position, department, phone, hire_date,
                       termination_date, status, base_salary, note''',
          parameters: [
            fullName,
            body['position'],
            body['department'],
            body['phone'],
            hireDate,
            body['status'] as String? ?? 'active',
            salary,
            body['note'],
          ],
        );
        return _json({'employee': Employee.fromRow(res.first).toJson()}, status: 201);
      } catch (e) {
        print('hr employees POST xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    get('/hr/employees/<id>', (Request request, String id) async {
      if (!_canRead(request)) return _json({'error': 'Ruxsat yoq'}, status: 403);
      final eid = int.tryParse(id);
      if (eid == null) return _json({'error': 'Noto\'g\'ri id'}, status: 400);
      try {
        final db = await DatabaseConnection.getConnection();
        final res = await db.execute(
          'SELECT id, full_name, position, department, phone, hire_date, '
          'termination_date, status, base_salary, note '
          'FROM fh.employees WHERE id = \$1',
          parameters: [eid],
        );
        if (res.isEmpty) return _json({'error': 'Xodim topilmadi'}, status: 404);
        return _json({'employee': Employee.fromRow(res.first).toJson()});
      } catch (e) {
        print('hr employee GET xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    put('/hr/employees/<id>', (Request request, String id) async {
      if (!_canManage(request)) return _json({'error': 'Ruxsat yoq'}, status: 403);
      final eid = int.tryParse(id);
      if (eid == null) return _json({'error': 'Noto\'g\'ri id'}, status: 400);
      try {
        final body = await _body(request);
        final fields = <String, dynamic>{
          'full_name': null,
          'position': null,
          'department': null,
          'phone': null,
          'status': null,
          'note': null,
        };
        final setParts = <String>[];
        final params = <dynamic>[];
        if (body['fullName'] != null) {
          fields['full_name'] = (body['fullName'] as String).trim();
        }
        if (body['baseSalary'] != null) {
          fields['base_salary'] = (body['baseSalary'] as num).toDouble();
        }
if (body['hireDate'] != null) {
          final hd = (body['hireDate'] as String).trim();
          if (hd.isNotEmpty) {
            fields['hire_date'] = hd;
          }
        }
        if (body['terminationDate'] != null) {
          fields['termination_date'] = (body['terminationDate'] as String).isEmpty
              ? null
              : (body['terminationDate'] as String);
        }
        for (final key in fields.keys) {
          final v = fields[key];
          if (v == null) continue;
          params.add(v);
          setParts.add('$key = \$${params.length}');
        }
        if (setParts.isEmpty) {
          return _json({'error': 'Yangilash uchun maydon kerak'}, status: 400);
        }
        setParts.add('updated_at = now()');
        params.add(eid);
        final db = await DatabaseConnection.getConnection();
        final res = await db.execute(
          'UPDATE fh.employees SET ${setParts.join(', ')} WHERE id = \$${params.length} '
          'RETURNING id, full_name, position, department, phone, hire_date, '
          'termination_date, status, base_salary, note',
          parameters: params,
        );
        if (res.isEmpty) return _json({'error': 'Xodim topilmadi'}, status: 404);
        return _json({'employee': Employee.fromRow(res.first).toJson()});
      } catch (e) {
        print('hr employee PUT xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    delete('/hr/employees/<id>', (Request request, String id) async {
      if (!_canManage(request)) return _json({'error': 'Ruxsat yoq'}, status: 403);
      final eid = int.tryParse(id);
      if (eid == null) return _json({'error': 'Noto\'g\'ri id'}, status: 400);
      try {
        final db = await DatabaseConnection.getConnection();
        final res = await db.execute(
          "UPDATE fh.employees SET status = 'terminated', termination_date = CURRENT_DATE "
          'WHERE id = \$1 AND status <> \'terminated\'',
          parameters: [eid],
        );
        if (res.affectedRows == 0) {
          final existing = await db.execute('SELECT 1 FROM fh.employees WHERE id = \$1', parameters: [eid]);
          if (existing.isEmpty) return _json({'error': 'Xodim topilmadi'}, status: 404);
          return _json({'message': 'Xodim allaqachon ishdan bo\'shatilgan'});
        }
        return _json({'message': 'Xodim ishdan bo\'shatildi'});
      } catch (e) {
        print('hr employee DELETE xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ───────────────────────── DAVOMAT ─────────────────────────
    get('/hr/attendance', (Request request) async {
      if (!_canRead(request)) return _json({'error': 'Ruxsat yoq'}, status: 403);
      try {
        final q = request.url.queryParameters;
        final params = <dynamic>[];
        var where = 'TRUE';
        final empId = int.tryParse(q['employee_id'] ?? '');
        if (empId != null) {
          params.add(empId);
          where += ' AND a.employee_id = \$${params.length}';
        }
        if (q['from'] != null && q['from']!.isNotEmpty) {
          params.add(q['from']);
          where += ' AND a.work_date >= \$${params.length}';
        }
        if (q['to'] != null && q['to']!.isNotEmpty) {
          params.add(q['to']);
          where += ' AND a.work_date <= \$${params.length}';
        }
        final db = await DatabaseConnection.getConnection();
        final res = await db.execute(
          'SELECT a.id, a.employee_id, a.work_date, a.check_in, a.check_out, '
          'a.hours_worked, a.status, a.note, a.recorded_by, e.full_name '
          'FROM fh.attendance a JOIN fh.employees e ON e.id = a.employee_id '
          'WHERE ${where} ORDER BY a.work_date DESC, a.employee_id',
          parameters: params,
        );
        final list = res.map((r) {
          final m = AttendanceRecord.fromRow(r).toJson();
          m['employeeName'] = r[9];
          return m;
        }).toList();
        return _json({'attendance': list});
      } catch (e) {
        print('hr attendance GET xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

double? _hours(String? inStr, String? outStr) {
      if (inStr == null || outStr == null) return null;
      final a = DateTime.tryParse('2000-01-01 $inStr');
      final b = DateTime.tryParse('2000-01-01 $outStr');
      if (a == null || b == null) return null;
      final diff = b.difference(a).inMinutes / 60.0;
      return double.parse(diff.toStringAsFixed(2));
    }

    String? _timeToHm(dynamic v) {
      if (v == null) return null;
      if (v is Time) {
        final h = v.hour == 24 ? 0 : v.hour;
        return '${h.toString().padLeft(2, '0')}:${v.minute.toString().padLeft(2, '0')}';
      }
      return v.toString();
    }

    post('/hr/attendance', (Request request) async {
      if (!_canManage(request)) return _json({'error': 'Ruxsat yoq'}, status: 403);
      try {
        final body = await _body(request);
        final eid = body['employeeId'] as int?;
        final workDate = body['workDate'] as String?;
        final status = body['status'] as String? ?? 'present';
        final checkIn = body['checkIn'] as String?;
        final checkOut = body['checkOut'] as String?;
        if (eid == null || workDate == null || workDate.isEmpty) {
          return _json({'error': 'employeeId va workDate majburiy'}, status: 400);
        }
        final hours = _hours(checkIn?.isEmpty ?? true ? null : checkIn,
            checkOut?.isEmpty ?? true ? null : checkOut);
        final db = await DatabaseConnection.getConnection();
        try {
          final res = await db.execute(
            '''INSERT INTO fh.attendance
               (employee_id, work_date, check_in, check_out, hours_worked, status, note, recorded_by)
               VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8)
               RETURNING id, employee_id, work_date, check_in, check_out,
                         hours_worked, status, note, recorded_by''',
            parameters: [
              eid, workDate,
              checkIn?.isEmpty ?? true ? null : checkIn,
              checkOut?.isEmpty ?? true ? null : checkOut,
              hours, status, body['note'], _uid(request),
            ],
          );
return _json({'attendance': AttendanceRecord.fromRow(res.first).toJson()}, status: 201);
        } on PgException catch (e) {
          if (e is ServerException && e.code == '23505') {
            return _json({'error': 'Bu kun uchun yozuv allaqachon bor', 'duplicate': true}, status: 409);
          }
          rethrow;
        }
      } catch (e) {
        print('hr attendance POST xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    post('/hr/attendance/bulk', (Request request) async {
      if (!_canManage(request)) return _json({'error': 'Ruxsat yoq'}, status: 403);
      try {
        final body = await _body(request);
        final workDate = body['workDate'] as String?;
        final records = body['records'] as List<dynamic>?;
        if (workDate == null || workDate.isEmpty) {
          return _json({'error': 'workDate majburiy'}, status: 400);
        }
        if (records == null || records.isEmpty) {
          return _json({'error': 'records bo\'sh'}, status: 400);
        }
        final db = await DatabaseConnection.getConnection();
        final inserted = <Map<String, dynamic>>[];
        final errors = <Map<String, dynamic>>[];
        for (final rec in records) {
          final m = rec as Map<String, dynamic>;
          final eid = m['employeeId'] as int?;
          if (eid == null) continue;
          final status = m['status'] as String? ?? 'present';
          final checkIn = m['checkIn'] as String?;
          final checkOut = m['checkOut'] as String?;
          final hours = _hours(checkIn?.isEmpty ?? true ? null : checkIn,
              checkOut?.isEmpty ?? true ? null : checkOut);
          try {
            final res = await db.execute(
              '''INSERT INTO fh.attendance
                 (employee_id, work_date, check_in, check_out, hours_worked, status, note, recorded_by)
                 VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8)
                 RETURNING id, employee_id, work_date, check_in, check_out,
                           hours_worked, status, note, recorded_by''',
              parameters: [
                eid, workDate,
                checkIn?.isEmpty ?? true ? null : checkIn,
                checkOut?.isEmpty ?? true ? null : checkOut,
                hours, status, m['note'], _uid(request),
              ],
            );
inserted.add(AttendanceRecord.fromRow(res.first).toJson());
          } on PgException catch (e) {
            if (e is ServerException && e.code == '23505') {
              errors.add({'employeeId': eid, 'error': 'Bu kun uchun yozuv allaqachon bor'});
            } else {
              errors.add({'employeeId': eid, 'error': 'Xatolik: ${e.message}'});
            }
          } catch (e) {
            errors.add({'employeeId': eid, 'error': 'Xatolik: $e'});
          }
        }
        return _json({
          'inserted': inserted,
          'errors': errors,
        }, status: errors.isEmpty ? 201 : 200);
      } catch (e) {
        print('hr attendance bulk xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    put('/hr/attendance/<id>', (Request request, String id) async {
      if (!_canManage(request)) return _json({'error': 'Ruxsat yoq'}, status: 403);
      final aid = int.tryParse(id);
      if (aid == null) return _json({'error': 'Noto\'g\'ri id'}, status: 400);
      try {
        final body = await _body(request);
        final db = await DatabaseConnection.getConnection();
        // Mavjud qiymatlarni olib, yangilangan in/out bilan hours hisoblaymiz.
        final cur = await db.execute(
          'SELECT check_in, check_out FROM fh.attendance WHERE id = \$1',
          parameters: [aid],
        );
        if (cur.isEmpty) return _json({'error': 'Yozuv topilmadi'}, status: 404);

String? existingIn = _timeToHm(cur.first[0]);
        String? existingOut = _timeToHm(cur.first[1]);
        final setParts = <String>[];
        final params = <dynamic>[];
        final bodyIn = body['checkIn'] as String?;
        final bodyOut = body['checkOut'] as String?;
        final bodyStatus = body['status'] as String?;

        bool recalcHours = false;
        if (bodyIn != null) {
          existingIn = bodyIn;
          setParts.add('check_in = \$${params.length + 1}');
          params.add(bodyIn.isEmpty ? null : bodyIn);
          if (!bodyIn.isEmpty) recalcHours = true;
        }
        if (bodyOut != null) {
          existingOut = bodyOut;
          setParts.add('check_out = \$${params.length + 1}');
          params.add(bodyOut.isEmpty ? null : bodyOut);
          if (!bodyOut.isEmpty) recalcHours = true;
        }
        if (recalcHours) {
          setParts.add('hours_worked = \$${params.length + 1}');
          params.add(_hours(existingIn, existingOut));
        }
        if (bodyStatus != null) {
          setParts.add('status = \$${params.length + 1}');
          params.add(bodyStatus);
        }
        if (body['note'] != null) {
          setParts.add('note = \$${params.length + 1}');
          params.add(body['note']);
        }
        if (setParts.isEmpty) {
          return _json({'error': 'Yangilash uchun maydon kerak'}, status: 400);
        }
        params.add(aid);
        final res = await db.execute(
          'UPDATE fh.attendance SET ${setParts.join(', ')} WHERE id = \$${params.length} '
          'RETURNING id, employee_id, work_date, check_in, check_out, '
          'hours_worked, status, note, recorded_by',
          parameters: params,
        );
        return _json({'attendance': AttendanceRecord.fromRow(res.first).toJson()});
      } catch (e) {
        print('hr attendance PUT xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    // ────────────────── PREMIYA / JARIMA / AVANS ──────────────────
    get('/hr/salary-adjustments', (Request request) async {
      if (!_canRead(request)) return _json({'error': 'Ruxsat yoq'}, status: 403);
      try {
        final q = request.url.queryParameters;
        final params = <dynamic>[];
        var where = 'TRUE';
        final empId = int.tryParse(q['employee_id'] ?? '');
        if (empId != null) {
          params.add(empId);
          where += ' AND s.employee_id = \$${params.length}';
        }
        if (q['type'] != null && q['type']!.isNotEmpty) {
          params.add(q['type']);
          where += ' AND s.adjustment_type = \$${params.length}';
        }
        if (q['status'] != null && q['status']!.isNotEmpty) {
          params.add(q['status']);
          where += ' AND s.status = \$${params.length}';
        }
        if (q['from'] != null && q['from']!.isNotEmpty) {
          params.add(q['from']);
          where += ' AND s.adjustment_date >= \$${params.length}';
        }
        if (q['to'] != null && q['to']!.isNotEmpty) {
          params.add(q['to']);
          where += ' AND s.adjustment_date <= \$${params.length}';
        }
        final db = await DatabaseConnection.getConnection();
        final res = await db.execute(
          'SELECT s.id, s.employee_id, s.adjustment_type, s.amount, s.reason, '
          's.adjustment_date, s.status, s.approved_by, e.full_name '
          'FROM fh.salary_adjustments s JOIN fh.employees e ON e.id = s.employee_id '
          'WHERE ${where} ORDER BY s.adjustment_date DESC, s.id DESC',
          parameters: params,
        );
        final list = res.map((r) {
          final m = SalaryAdjustment.fromRow(r).toJson();
          m['employeeName'] = r[8];
          return m;
        }).toList();
        return _json({'adjustments': list});
      } catch (e) {
        print('hr salary-adjustments GET xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    post('/hr/salary-adjustments', (Request request) async {
      if (!_canManage(request)) return _json({'error': 'Ruxsat yoq'}, status: 403);
      try {
        final body = await _body(request);
        final eid = body['employeeId'] as int?;
        final type = body['adjustmentType'] as String?;
        final amount = (body['amount'] as num?)?.toDouble();
        final reason = (body['reason'] as String?)?.trim();
        if (eid == null || type == null || amount == null || amount <= 0) {
          return _json({'error': 'employeeId, adjustmentType va amount (>0) majburiy'}, status: 400);
        }
        if (reason == null || reason.isEmpty) {
          return _json({'error': 'reason majburiy'}, status: 400);
        }
        final allowed = ['bonus', 'penalty', 'advance', 'other'];
        if (!allowed.contains(type)) {
          return _json({'error': 'adjustmentType noto\'g\'ri'}, status: 400);
        }
        final dateStr = body['adjustmentDate'] as String?;
        final db = await DatabaseConnection.getConnection();
        final res = await db.execute(
          '''INSERT INTO fh.salary_adjustments
             (employee_id, adjustment_type, amount, reason, adjustment_date, status)
             VALUES (\$1, \$2, \$3, \$4, \$5, \$6)
             RETURNING id, employee_id, adjustment_type, amount, reason,
                       adjustment_date, status, approved_by''',
          parameters: [
            eid, type, amount, reason,
            dateStr?.isEmpty ?? true ? null : dateStr,
            body['status'] as String? ?? 'pending',
          ],
        );
        return _json({'adjustment': SalaryAdjustment.fromRow(res.first).toJson()}, status: 201);
      } catch (e) {
        print('hr salary-adjustments POST xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });

    Future<Response> _setAdjustmentStatus(Request request, String id, String newStatus) async {
      if (!_canManage(request)) return _json({'error': 'Ruxsat yoq'}, status: 403);
      final aid = int.tryParse(id);
      if (aid == null) return _json({'error': 'Noto\'g\'ri id'}, status: 400);
      try {
        final db = await DatabaseConnection.getConnection();
        final res = await db.execute(
          'UPDATE fh.salary_adjustments SET status = \$1, approved_by = \$2 '
          'WHERE id = \$3 AND status = \'pending\'',
          parameters: [newStatus, _uid(request), aid],
        );
        if (res.affectedRows == 0) {
          final existing = await db.execute('SELECT status FROM fh.salary_adjustments WHERE id = \$1', parameters: [aid]);
          if (existing.isEmpty) return _json({'error': 'Yozuv topilmadi'}, status: 404);
          return _json({'error': 'Yozuv allaqachon qayta ishlangan (${existing.first[0]})'}, status: 409);
        }
        return _json({'ok': true, 'status': newStatus});
      } catch (e) {
        print('hr adjustment approve/reject xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    }

    put('/hr/salary-adjustments/<id>/approve', (Request request, String id) async {
      return _setAdjustmentStatus(request, id, 'approved');
    });

    put('/hr/salary-adjustments/<id>/reject', (Request request, String id) async {
      return _setAdjustmentStatus(request, id, 'rejected');
    });

    // ───────────────────────── HISOBOT ─────────────────────────
    get('/hr/reports/monthly', (Request request) async {
      if (!_canRead(request)) return _json({'error': 'Ruxsat yoq'}, status: 403);
      try {
        final q = request.url.queryParameters;
        final params = <dynamic>[];
        var where = 'TRUE';
        final empId = int.tryParse(q['employee_id'] ?? '');
        if (empId != null) {
          params.add(empId);
          where += ' AND employee_id = \$${params.length}';
        }
        final month = q['month'];
        if (month != null && month.isNotEmpty) {
          params.add(month);
          where += ' AND to_char(month, \'YYYY-MM\') = \$${params.length}';
        }
        final db = await DatabaseConnection.getConnection();
        final res = await db.execute(
          'SELECT employee_id, full_name, position, department, base_salary, month, '
          'days_present, days_absent, days_late, days_sick, days_vacation, total_hours, '
          'total_bonus, total_penalty, total_advance '
          'FROM fh.monthly_payroll_summary WHERE ${where} '
          'ORDER BY month DESC, full_name',
          parameters: params,
        );
        final list = res.map((r) => {
          'employeeId': r[0],
          'fullName': r[1],
          'position': r[2],
          'department': r[3],
          'baseSalary': r[4]?.toString(),
          'month': (r[5] as DateTime).toIso8601String().substring(0, 10),
          'daysPresent': r[6],
          'daysAbsent': r[7],
          'daysLate': r[8],
          'daysSick': r[9],
          'daysVacation': r[10],
          'totalHours': r[11]?.toString(),
          'totalBonus': r[12]?.toString(),
          'totalPenalty': r[13]?.toString(),
          'totalAdvance': r[14]?.toString(),
        }).toList();
        return _json({'rows': list});
      } catch (e) {
        print('hr reports monthly xato: $e');
        return _json({'error': 'Server xatosi'}, status: 500);
      }
    });
  }
}

