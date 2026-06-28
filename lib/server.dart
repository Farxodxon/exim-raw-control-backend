import 'dart:io';
import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'database/connection.dart';

void main() async {
  print('🚀 Starting Dart Backend Server...');

  try {
    await DatabaseConnection.getConnection();
    print('✅ Database connected');
  } catch (e) {
    print('⚠️ Database not connected: \$e');
  }

  final router = Router();

  // ─── HEALTH ──────────────────────────────────────────────────────────────────
  router.get('/health', (Request request) async {
    bool dbOk = false;
    try { await DatabaseConnection.getConnection(); dbOk = true; } catch (_) {}
    return Response.ok(
      jsonEncode({'status': 'ok', 'database': dbOk ? 'connected' : 'disconnected',
        'timestamp': DateTime.now().toIso8601String()}),
      headers: {'Content-Type': 'application/json'},
    );
  });

  // ─── RAW MATERIALS ───────────────────────────────────────────────────────────
  router.get('/api/raw-materials', (Request request) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      final result = await conn.execute('SELECT * FROM raw_materials ORDER BY id');
      final materials = result.map((row) => {
        'id': row[0], 'name': row[1], 'netto_kg': row[2],
        'brutto_kg': row[3], 'package_quantity': row[4], 'current_netto': row[5],
      }).toList();
      return Response.ok(jsonEncode(materials), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  router.post('/api/raw-materials', (Request request) async {
    try {
      final body = jsonDecode(await request.readAsString());
      final conn = await DatabaseConnection.getConnection();
      final result = await conn.execute(
        'INSERT INTO raw_materials (name, netto_kg, brutto_kg, package_quantity, current_netto) '
        'VALUES (\$1, \$2, \$3, \$4, \$5) RETURNING *',
        parameters: [body['name'], body['netto_kg'], body['brutto_kg'],
          body['package_quantity'], body['current_netto'] ?? body['netto_kg']],
      );
      final row = result.first;
      return Response.ok(jsonEncode({
        'id': row[0], 'name': row[1], 'netto_kg': row[2],
        'brutto_kg': row[3], 'package_quantity': row[4], 'current_netto': row[5],
      }), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  // ─── PRODUCTS ────────────────────────────────────────────────────────────────

  // GET /api/products?search=...&category=...
  router.get('/api/products', (Request request) async {
    try {
      final params = request.url.queryParameters;
      final search = params['search'] ?? '';
      final category = params['category'] ?? '';
      final conn = await DatabaseConnection.getConnection();

      String sql = 'SELECT * FROM products WHERE 1=1';
      final List<Object?> args = [];
      int idx = 1;

      if (search.isNotEmpty) {
       sql += ' AND (name ILIKE \$${idx} OR barcode ILIKE \$${idx + 1})';
        args.add('%\$search%');
        args.add('%\$search%');
        idx += 2;
      }
      if (category.isNotEmpty) {
        sql += ' AND category = \\${idx}';
        args.add(category);
        idx++;
      }
      sql += ' ORDER BY category, name';

      final result = await conn.execute(sql, parameters: args);
      final products = result.map((row) => {
        'id': row[0], 'barcode': row[1], 'name': row[2], 'category': row[3],
        'tnved': row[4], 'pcs_in_box': row[5], 'price_usd': row[6], 'netto_per_piece': row[7],
      }).toList();
      return Response.ok(jsonEncode(products), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  // GET /api/products/categories
  router.get('/api/products/categories', (Request request) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      final result = await conn.execute(
        'SELECT DISTINCT category FROM products WHERE category IS NOT NULL ORDER BY category');
      final cats = result.map((row) => row[0] as String).toList();
      return Response.ok(jsonEncode(cats), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  // GET /api/products/barcode/:barcode
  router.get('/api/products/barcode/<barcode>', (Request request, String barcode) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      final result = await conn.execute(
        'SELECT * FROM products WHERE barcode = \$1', parameters: [barcode]);
      if (result.isEmpty) {
        return Response.notFound(jsonEncode({'error': 'Topilmadi'}),
          headers: {'Content-Type': 'application/json'});
      }
      final row = result.first;
      return Response.ok(jsonEncode({
        'id': row[0], 'barcode': row[1], 'name': row[2], 'category': row[3],
        'tnved': row[4], 'pcs_in_box': row[5], 'price_usd': row[6], 'netto_per_piece': row[7],
      }), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  // POST /api/products
  router.post('/api/products', (Request request) async {
    try {
      final body = jsonDecode(await request.readAsString());
      if (body['barcode'] == null || body['name'] == null) {
        return Response(400, body: jsonEncode({'error': 'barcode va name majburiy'}),
          headers: {'Content-Type': 'application/json'});
      }
      final conn = await DatabaseConnection.getConnection();
      final result = await conn.execute(
        'INSERT INTO products (barcode, name, category, tnved, pcs_in_box, price_usd, netto_per_piece) '
        'VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7) RETURNING *',
        parameters: [body['barcode'], body['name'], body['category'], body['tnved'],
          body['pcs_in_box'], body['price_usd'], body['netto_per_piece']],
      );
      final row = result.first;
      return Response.ok(jsonEncode({
        'id': row[0], 'barcode': row[1], 'name': row[2], 'category': row[3],
        'tnved': row[4], 'pcs_in_box': row[5], 'price_usd': row[6], 'netto_per_piece': row[7],
      }), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('unique') || msg.contains('duplicate')) {
        return Response(409, body: jsonEncode({'error': 'Bu barcode allaqachon mavjud'}),
          headers: {'Content-Type': 'application/json'});
      }
      return Response.internalServerError(body: jsonEncode({'error': msg}));
    }
  });

  // PUT /api/products/:id
  router.put('/api/products/<id>', (Request request, String id) async {
    try {
      final body = jsonDecode(await request.readAsString());
      final conn = await DatabaseConnection.getConnection();
      final result = await conn.execute(
        'UPDATE products SET barcode=\$1, name=\$2, category=\$3, tnved=\$4, '
        'pcs_in_box=\$5, price_usd=\$6, netto_per_piece=\$7 WHERE id=\$8 RETURNING *',
        parameters: [body['barcode'], body['name'], body['category'], body['tnved'],
          body['pcs_in_box'], body['price_usd'], body['netto_per_piece'], int.parse(id)],
      );
      if (result.isEmpty) {
        return Response(404, body: jsonEncode({'error': 'Mahsulot topilmadi'}),
          headers: {'Content-Type': 'application/json'});
      }
      final row = result.first;
      return Response.ok(jsonEncode({
        'id': row[0], 'barcode': row[1], 'name': row[2], 'category': row[3],
        'tnved': row[4], 'pcs_in_box': row[5], 'price_usd': row[6], 'netto_per_piece': row[7],
      }), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  // DELETE /api/products/:id
  router.delete('/api/products/<id>', (Request request, String id) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      final result = await conn.execute(
        'DELETE FROM products WHERE id=\$1 RETURNING id', parameters: [int.parse(id)]);
      if (result.isEmpty) {
        return Response(404, body: jsonEncode({'error': 'Mahsulot topilmadi'}),
          headers: {'Content-Type': 'application/json'});
      }
      return Response.ok(jsonEncode({'message': "O'chirildi", 'id': int.parse(id)}),
        headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  // ─── ORDERS ──────────────────────────────────────────────────────────────────
  router.post('/api/orders/check', (Request request) async {
    try {
      final body = jsonDecode(await request.readAsString());
      final barcodes = List<String>.from(body['barcodes']);
      final conn = await DatabaseConnection.getConnection();
      final results = [];
      for (final barcode in barcodes) {
        final result = await conn.execute(
          'SELECT * FROM products WHERE barcode = \$1', parameters: [barcode]);
        if (result.isNotEmpty) {
          final row = result.first;
          results.add({'barcode': barcode, 'found': true, 'product': {
            'id': row[0], 'barcode': row[1], 'name': row[2], 'category': row[3],
            'tnved': row[4], 'pcs_in_box': row[5], 'price_usd': row[6], 'netto_per_piece': row[7],
          }});
        } else {
          results.add({'barcode': barcode, 'found': false});
        }
      }
      return Response.ok(jsonEncode({
        'total': barcodes.length,
        'found': results.where((r) => r['found'] == true).length,
        'not_found': results.where((r) => r['found'] == false).length,
        'results': results,
      }), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });


  // ─── SETUP (jadvallar yaratish) ──────────────────────────────────────────────
  router.get('/api/setup', (Request request) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      await conn.execute('''
        CREATE TABLE IF NOT EXISTS orders (
          id SERIAL PRIMARY KEY,
          order_number VARCHAR(50),
          country VARCHAR(100),
          company_name VARCHAR(200),
          contract_number VARCHAR(100),
          created_at TIMESTAMP DEFAULT NOW()
        )
      ''');
      await conn.execute('''
        CREATE TABLE IF NOT EXISTS order_items (
          id SERIAL PRIMARY KEY,
          order_id INTEGER REFERENCES orders(id) ON DELETE CASCADE,
          barcode VARCHAR(20),
          product_name VARCHAR(300),
          quantity INTEGER DEFAULT 0,
          price_usd DECIMAL(10,2),
          found BOOLEAN DEFAULT false
        )
      ''');
      return Response.ok(
        jsonEncode({'message': 'Jadvallar yaratildi'}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  // ─── ORDERS ──────────────────────────────────────────────────────────────────

  // GET /api/orders
  router.get('/api/orders', (Request request) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      final result = await conn.execute(
        '''SELECT o.*, COUNT(oi.id) as total_items,
          SUM(CASE WHEN oi.found THEN 1 ELSE 0 END) as found_items
          FROM orders o
          LEFT JOIN order_items oi ON oi.order_id = o.id
          GROUP BY o.id ORDER BY o.created_at DESC'''
      );
      final orders = result.map((row) => {
        'id': row[0], 'order_number': row[1], 'country': row[2],
        'company_name': row[3], 'contract_number': row[4],
        'created_at': row[5]?.toString(),
        'total_items': row[6], 'found_items': row[7],
      }).toList();
      return Response.ok(jsonEncode(orders), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  // POST /api/orders
  router.post('/api/orders', (Request request) async {
    try {
      final body = jsonDecode(await request.readAsString());
      final conn = await DatabaseConnection.getConnection();
      final result = await conn.execute(
        '''INSERT INTO orders (order_number, country, company_name, contract_number)
          VALUES (\$1, \$2, \$3, \$4) RETURNING *''',
        parameters: [body['order_number'], body['country'], body['company_name'], body['contract_number']],
      );
      final row = result.first;
      return Response.ok(jsonEncode({
        'id': row[0], 'order_number': row[1], 'country': row[2],
        'company_name': row[3], 'contract_number': row[4], 'created_at': row[5]?.toString(),
      }), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  // GET /api/orders/:id
  router.get('/api/orders/<id>', (Request request, String id) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      final orderRes = await conn.execute(
        'SELECT * FROM orders WHERE id=\$1', parameters: [int.parse(id)]);
      if (orderRes.isEmpty) {
        return Response(404, body: jsonEncode({'error': 'Topilmadi'}),
          headers: {'Content-Type': 'application/json'});
      }
      final o = orderRes.first;
      final itemsRes = await conn.execute(
        'SELECT * FROM order_items WHERE order_id=\$1 ORDER BY id',
        parameters: [int.parse(id)]);
      final items = itemsRes.map((row) => {
        'id': row[0], 'order_id': row[1], 'barcode': row[2],
        'product_name': row[3], 'quantity': row[4], 'price_usd': row[5], 'found': row[6],
      }).toList();
      return Response.ok(jsonEncode({
        'id': o[0], 'order_number': o[1], 'country': o[2],
        'company_name': o[3], 'contract_number': o[4], 'created_at': o[5]?.toString(),
        'items': items,
      }), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  // POST /api/orders/:id/items (barcha itemlarni saqlash)
  router.post('/api/orders/<id>/items', (Request request, String id) async {
    try {
      final body = jsonDecode(await request.readAsString());
      final items = List<Map<String, dynamic>>.from(body['items']);
      final conn = await DatabaseConnection.getConnection();
      // Avval eski itemlarni o'chiramiz
      await conn.execute('DELETE FROM order_items WHERE order_id=\$1',
        parameters: [int.parse(id)]);
      // Yangilarini qo'shamiz
      for (final item in items) {
        await conn.execute(
          '''INSERT INTO order_items (order_id, barcode, product_name, quantity, price_usd, found)
            VALUES (\$1, \$2, \$3, \$4, \$5, \$6)''',
          parameters: [
            int.parse(id), item['barcode'], item['product_name'],
            item['quantity'] ?? 0, item['price_usd'], item['found'] ?? false,
          ],
        );
      }
      return Response.ok(jsonEncode({'message': 'Saqlandi', 'count': items.length}),
        headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  // DELETE /api/orders/:id
  router.delete('/api/orders/<id>', (Request request, String id) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      await conn.execute('DELETE FROM orders WHERE id=\$1', parameters: [int.parse(id)]);
      return Response.ok(jsonEncode({'message': "O'chirildi"}),
        headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  // ─── CORS HANDLER ────────────────────────────────────────────────────────────
  final handler = (Request request) async {
    if (request.method == 'OPTIONS') {
      return Response.ok('', headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      });
    }
    final response = await router(request);
    return response.change(headers: {'Access-Control-Allow-Origin': '*'});
  };

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  await shelf_io.serve(handler, '0.0.0.0', port);
  print('✅ Server running on http://0.0.0.0:\$port');
}
