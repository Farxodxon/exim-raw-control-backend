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



  // ─── SETUP RESET ─────────────────────────────────────────────────────────────
  router.get('/api/setup-reset', (Request request) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      await conn.execute('DROP TABLE IF EXISTS order_items CASCADE');
      await conn.execute('DROP TABLE IF EXISTS orders CASCADE');
      await conn.execute('''
        CREATE TABLE orders (
          id SERIAL PRIMARY KEY,
          order_number VARCHAR(100),
          country VARCHAR(100),
          company_name VARCHAR(200),
          contract_number VARCHAR(100),
          created_at TIMESTAMP DEFAULT NOW()
        )
      ''');
      await conn.execute('''
        CREATE TABLE order_items (
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
        jsonEncode({'message': 'Jadvallar qayta yaratildi'}),
        headers: {'Content-Type': 'application/json'},
      );
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



  router.get('/api/setup-materials-reset', (Request request) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      await conn.execute('DROP TABLE IF EXISTS material_expenses CASCADE');
      await conn.execute('DROP TABLE IF EXISTS product_materials CASCADE');
      await conn.execute('DROP TABLE IF EXISTS material_incomes CASCADE');
      await conn.execute('DROP TABLE IF EXISTS raw_materials CASCADE');
      await conn.execute('''CREATE TABLE raw_materials (
        id SERIAL PRIMARY KEY,
        name VARCHAR(200) NOT NULL,
        code VARCHAR(100),
        unit VARCHAR(20) DEFAULT ''''kg'''',
        created_at TIMESTAMP DEFAULT NOW())''');
      await conn.execute('''CREATE TABLE material_incomes (
        id SERIAL PRIMARY KEY,
        raw_material_id INTEGER REFERENCES raw_materials(id) ON DELETE CASCADE,
        netto_kg DECIMAL(12,3) NOT NULL,
        brutto_kg DECIMAL(12,3),
        doc_number VARCHAR(100),
        income_date DATE DEFAULT CURRENT_DATE,
        created_at TIMESTAMP DEFAULT NOW())''');
      await conn.execute('''CREATE TABLE product_materials (
        id SERIAL PRIMARY KEY,
        product_barcode VARCHAR(20) NOT NULL,
        raw_material_id INTEGER REFERENCES raw_materials(id) ON DELETE CASCADE,
        grams_per_unit DECIMAL(10,3) NOT NULL,
        UNIQUE(product_barcode, raw_material_id))''');
      await conn.execute('''CREATE TABLE material_expenses (
        id SERIAL PRIMARY KEY,
        raw_material_id INTEGER REFERENCES raw_materials(id) ON DELETE CASCADE,
        order_id INTEGER REFERENCES orders(id) ON DELETE CASCADE,
        product_barcode VARCHAR(20),
        quantity_kg DECIMAL(12,3) NOT NULL,
        created_at TIMESTAMP DEFAULT NOW())''');
      return Response.ok(jsonEncode({'message': 'Siryo jadvallari qayta yaratildi'}),
        headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });


  router.get('/api/setup-materials-reset', (Request request) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      await conn.execute('DROP TABLE IF EXISTS material_expenses CASCADE');
      await conn.execute('DROP TABLE IF EXISTS product_materials CASCADE');
      await conn.execute('DROP TABLE IF EXISTS material_incomes CASCADE');
      await conn.execute('DROP TABLE IF EXISTS raw_materials CASCADE');
      await conn.execute('''CREATE TABLE raw_materials (
        id SERIAL PRIMARY KEY,
        name VARCHAR(200) NOT NULL,
        code VARCHAR(100),
        unit VARCHAR(20) DEFAULT ''''kg'''',
        created_at TIMESTAMP DEFAULT NOW())''');
      await conn.execute('''CREATE TABLE material_incomes (
        id SERIAL PRIMARY KEY,
        raw_material_id INTEGER REFERENCES raw_materials(id) ON DELETE CASCADE,
        netto_kg DECIMAL(12,3) NOT NULL,
        brutto_kg DECIMAL(12,3),
        doc_number VARCHAR(100),
        income_date DATE DEFAULT CURRENT_DATE,
        created_at TIMESTAMP DEFAULT NOW())''');
      await conn.execute('''CREATE TABLE product_materials (
        id SERIAL PRIMARY KEY,
        product_barcode VARCHAR(20) NOT NULL,
        raw_material_id INTEGER REFERENCES raw_materials(id) ON DELETE CASCADE,
        grams_per_unit DECIMAL(10,3) NOT NULL,
        UNIQUE(product_barcode, raw_material_id))''');
      await conn.execute('''CREATE TABLE material_expenses (
        id SERIAL PRIMARY KEY,
        raw_material_id INTEGER REFERENCES raw_materials(id) ON DELETE CASCADE,
        order_id INTEGER REFERENCES orders(id) ON DELETE CASCADE,
        product_barcode VARCHAR(20),
        quantity_kg DECIMAL(12,3) NOT NULL,
        created_at TIMESTAMP DEFAULT NOW())''');
      return Response.ok(jsonEncode({'message': 'Siryo jadvallari qayta yaratildi'}),
        headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  // ─── SIRYO SETUP ─────────────────────────────────────────────────────────────
  router.get('/api/setup-materials', (Request request) async {
    try {
      final conn = await DatabaseConnection.getConnection();

      // Siryo katalogi
      await conn.execute('''
        CREATE TABLE IF NOT EXISTS raw_materials (
          id SERIAL PRIMARY KEY,
          name VARCHAR(200) NOT NULL,
          code VARCHAR(100),
          unit VARCHAR(20) DEFAULT 'kg',
          created_at TIMESTAMP DEFAULT NOW()
        )
      ''');

      // Kirim lotlari
      await conn.execute('''
        CREATE TABLE IF NOT EXISTS material_incomes (
          id SERIAL PRIMARY KEY,
          raw_material_id INTEGER REFERENCES raw_materials(id) ON DELETE CASCADE,
          netto_kg DECIMAL(12,3) NOT NULL,
          brutto_kg DECIMAL(12,3),
          doc_number VARCHAR(100),
          income_date DATE DEFAULT CURRENT_DATE,
          created_at TIMESTAMP DEFAULT NOW()
        )
      ''');

      // Mahsulot-siryo bog'liqlik (1 dona uchun necha gram)
      await conn.execute('''
        CREATE TABLE IF NOT EXISTS product_materials (
          id SERIAL PRIMARY KEY,
          product_barcode VARCHAR(20) NOT NULL,
          raw_material_id INTEGER REFERENCES raw_materials(id) ON DELETE CASCADE,
          grams_per_unit DECIMAL(10,3) NOT NULL,
          UNIQUE(product_barcode, raw_material_id)
        )
      ''');

      // Avtomatik rasxod
      await conn.execute('''
        CREATE TABLE IF NOT EXISTS material_expenses (
          id SERIAL PRIMARY KEY,
          raw_material_id INTEGER REFERENCES raw_materials(id) ON DELETE CASCADE,
          order_id INTEGER REFERENCES orders(id) ON DELETE CASCADE,
          product_barcode VARCHAR(20),
          quantity_kg DECIMAL(12,3) NOT NULL,
          created_at TIMESTAMP DEFAULT NOW()
        )
      ''');

      return Response.ok(
        jsonEncode({'message': 'Siryo jadvallari yaratildi'}),
        headers: {'Content-Type': 'application/json'},
      );
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  // ─── RAW MATERIALS CATALOG ───────────────────────────────────────────────────

  router.get('/api/raw-materials-catalog', (Request request) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      final result = await conn.execute('''
        SELECT r.*,
          COALESCE((SELECT SUM(i.netto_kg) FROM material_incomes i WHERE i.raw_material_id = r.id), 0) as total_income,
          COALESCE((SELECT SUM(e.quantity_kg) FROM material_expenses e WHERE e.raw_material_id = r.id), 0) as total_expense
        FROM raw_materials r
        ORDER BY r.name
      ''');
      final list = result.map((row) => {
        'id': row[0], 'name': row[1], 'code': row[2], 'unit': row[3],
        'created_at': row[4]?.toString(),
        'total_income': row[5], 'total_expense': row[6],
        'balance': (double.tryParse(row[5].toString()) ?? 0) - (double.tryParse(row[6].toString()) ?? 0),
      }).toList();
      return Response.ok(jsonEncode(list), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  router.post('/api/raw-materials-catalog', (Request request) async {
    try {
      final body = jsonDecode(await request.readAsString());
      final conn = await DatabaseConnection.getConnection();
      final result = await conn.execute(
        'INSERT INTO raw_materials (name, code, unit) VALUES (\$1, \$2, \$3) RETURNING *',
        parameters: [body['name'], body['code'], body['unit'] ?? 'kg'],
      );
      final row = result.first;
      return Response.ok(jsonEncode({
        'id': row[0], 'name': row[1], 'code': row[2], 'unit': row[3],
      }), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  router.delete('/api/raw-materials-catalog/<id>', (Request request, String id) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      await conn.execute('DELETE FROM raw_materials WHERE id=\$1', parameters: [int.parse(id)]);
      return Response.ok(jsonEncode({'message': "O'chirildi"}), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  // ─── MATERIAL INCOMES ────────────────────────────────────────────────────────

  router.get('/api/material-incomes', (Request request) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      final params = request.url.queryParameters;
      String sql = '''
        SELECT i.*, r.name as material_name, r.code as material_code
        FROM material_incomes i
        JOIN raw_materials r ON r.id = i.raw_material_id
        WHERE 1=1
      ''';
      final List<Object?> args = [];
      if (params['material_id'] != null) {
        sql += ' AND i.raw_material_id = \$1';
        args.add(int.parse(params['material_id']!));
      }
      sql += ' ORDER BY i.income_date DESC, i.created_at DESC';
      final result = await conn.execute(sql, parameters: args);
      final list = result.map((row) => {
        'id': row[0], 'raw_material_id': row[1], 'netto_kg': row[2],
        'brutto_kg': row[3], 'doc_number': row[4],
        'income_date': row[5]?.toString(), 'created_at': row[6]?.toString(),
        'material_name': row[7], 'material_code': row[8],
      }).toList();
      return Response.ok(jsonEncode(list), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  router.post('/api/material-incomes', (Request request) async {
    try {
      final body = jsonDecode(await request.readAsString());
      final conn = await DatabaseConnection.getConnection();
      final result = await conn.execute(
        '''INSERT INTO material_incomes (raw_material_id, netto_kg, brutto_kg, doc_number, income_date)
          VALUES (\$1, \$2, \$3, \$4, \$5) RETURNING *''',
        parameters: [
          body['raw_material_id'], body['netto_kg'], body['brutto_kg'],
          body['doc_number'], body['income_date'],
        ],
      );
      final row = result.first;
      return Response.ok(jsonEncode({
        'id': row[0], 'raw_material_id': row[1], 'netto_kg': row[2],
        'brutto_kg': row[3], 'doc_number': row[4], 'income_date': row[5]?.toString(),
      }), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  router.delete('/api/material-incomes/<id>', (Request request, String id) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      await conn.execute('DELETE FROM material_incomes WHERE id=\$1', parameters: [int.parse(id)]);
      return Response.ok(jsonEncode({'message': "O'chirildi"}), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  // ─── PRODUCT MATERIALS ───────────────────────────────────────────────────────

  router.get('/api/product-materials/<barcode>', (Request request, String barcode) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      final result = await conn.execute(
        '''SELECT pm.*, r.name as material_name, r.code as material_code, r.unit
          FROM product_materials pm
          JOIN raw_materials r ON r.id = pm.raw_material_id
          WHERE pm.product_barcode = \$1''',
        parameters: [barcode],
      );
      final list = result.map((row) => {
        'id': row[0], 'product_barcode': row[1], 'raw_material_id': row[2],
        'grams_per_unit': row[3], 'material_name': row[4],
        'material_code': row[5], 'unit': row[6],
      }).toList();
      return Response.ok(jsonEncode(list), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  router.post('/api/product-materials', (Request request) async {
    try {
      final body = jsonDecode(await request.readAsString());
      final conn = await DatabaseConnection.getConnection();
      final result = await conn.execute(
        '''INSERT INTO product_materials (product_barcode, raw_material_id, grams_per_unit)
          VALUES (\$1, \$2, \$3)
          ON CONFLICT (product_barcode, raw_material_id)
          DO UPDATE SET grams_per_unit = EXCLUDED.grams_per_unit
          RETURNING *''',
        parameters: [body['product_barcode'], body['raw_material_id'], body['grams_per_unit']],
      );
      final row = result.first;
      return Response.ok(jsonEncode({
        'id': row[0], 'product_barcode': row[1],
        'raw_material_id': row[2], 'grams_per_unit': row[3],
      }), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  router.delete('/api/product-materials/<id>', (Request request, String id) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      await conn.execute('DELETE FROM product_materials WHERE id=\$1', parameters: [int.parse(id)]);
      return Response.ok(jsonEncode({'message': "O'chirildi"}), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  // ─── MATERIAL EXPENSES (avtomatik) ───────────────────────────────────────────

  router.get('/api/material-expenses', (Request request) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      final params = request.url.queryParameters;
      String sql = '''
        SELECT e.*, r.name as material_name, r.code as material_code,
          o.order_number
        FROM material_expenses e
        JOIN raw_materials r ON r.id = e.raw_material_id
        LEFT JOIN orders o ON o.id = e.order_id
        WHERE 1=1
      ''';
      final List<Object?> args = [];
      if (params['material_id'] != null) {
        sql += ' AND e.raw_material_id = \$1';
        args.add(int.parse(params['material_id']!));
      }
      sql += ' ORDER BY e.created_at DESC';
      final result = await conn.execute(sql, parameters: args);
      final list = result.map((row) => {
        'id': row[0], 'raw_material_id': row[1], 'order_id': row[2],
        'product_barcode': row[3], 'quantity_kg': row[4],
        'created_at': row[5]?.toString(),
        'material_name': row[6], 'material_code': row[7], 'order_number': row[8],
      }).toList();
      return Response.ok(jsonEncode(list), headers: {'Content-Type': 'application/json'});
    } catch (e) {
      return Response.internalServerError(body: jsonEncode({'error': e.toString()}));
    }
  });

  // POST /api/orders/:id/calculate-expenses — buyurtma saqlanganda chaqiriladi
  router.post('/api/orders/<id>/calculate-expenses', (Request request, String id) async {
    try {
      final conn = await DatabaseConnection.getConnection();
      final orderId = int.parse(id);

      // Avval eski rasxodlarni o'chiramiz
      await conn.execute('DELETE FROM material_expenses WHERE order_id=\$1', parameters: [orderId]);

      // Buyurtma itemlarini olamiz
      final items = await conn.execute(
        'SELECT barcode, quantity FROM order_items WHERE order_id=\$1 AND found=true AND quantity > 0',
        parameters: [orderId],
      );

      int totalExpenses = 0;
      for (final item in items) {
        final barcode = item[0] as String;
        final qty = (item[1] as num).toInt();

        // Bu mahsulot uchun siryo bog'liqliklarini olamiz
        final materials = await conn.execute(
          'SELECT raw_material_id, grams_per_unit FROM product_materials WHERE product_barcode=\$1',
          parameters: [barcode],
        );

        for (final mat in materials) {
          final materialId = mat[0] as int;
          final gramsPerUnit = double.tryParse(mat[1].toString()) ?? 0;
          final quantityKg = (qty * gramsPerUnit) / 1000.0;

          if (quantityKg > 0) {
            await conn.execute(
              '''INSERT INTO material_expenses (raw_material_id, order_id, product_barcode, quantity_kg)
                VALUES (\$1, \$2, \$3, \$4)''',
              parameters: [materialId, orderId, barcode, quantityKg],
            );
            totalExpenses++;
          }
        }
      }

      return Response.ok(
        jsonEncode({'message': 'Rasxod hisoblandi', 'expense_records': totalExpenses}),
        headers: {'Content-Type': 'application/json'},
      );
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
