import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:dotenv/dotenv.dart';

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

Future<void> main() async {
  final c = await connect();
  try {
    await c.execute('BEGIN');

    // 1) employees
    await c.execute('''
      CREATE TABLE IF NOT EXISTS fh.employees (
          id              SERIAL PRIMARY KEY,
          full_name       TEXT NOT NULL,
          position        TEXT,
          department      TEXT,
          phone           TEXT,
          hire_date       DATE NOT NULL DEFAULT CURRENT_DATE,
          termination_date DATE,
          status          TEXT NOT NULL DEFAULT 'active'
                          CHECK (status IN ('active', 'on_leave', 'terminated')),
          base_salary     NUMERIC(14,2),
          note            TEXT,
          created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
          updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
      )''');
    await c.execute('CREATE INDEX IF NOT EXISTS idx_employees_status ON fh.employees(status)');
    print('fh.employees + index');

    // 2) attendance
    await c.execute('''
      CREATE TABLE IF NOT EXISTS fh.attendance (
          id              SERIAL PRIMARY KEY,
          employee_id     INTEGER NOT NULL REFERENCES fh.employees(id) ON DELETE CASCADE,
          work_date       DATE NOT NULL,
          check_in        TIME,
          check_out       TIME,
          hours_worked    NUMERIC(5,2),
          status          TEXT NOT NULL DEFAULT 'present'
                          CHECK (status IN (
                              'present', 'absent', 'late', 'sick_leave',
                              'vacation', 'unpaid_leave', 'business_trip'
                          )),
          note            TEXT,
          recorded_by     INTEGER,
          created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
          UNIQUE (employee_id, work_date)
      )''');
    await c.execute('CREATE INDEX IF NOT EXISTS idx_attendance_employee_date ON fh.attendance(employee_id, work_date)');
    await c.execute('CREATE INDEX IF NOT EXISTS idx_attendance_date ON fh.attendance(work_date)');
    print('fh.attendance + indexes');

    // 3) salary_adjustments
    await c.execute('''
      CREATE TABLE IF NOT EXISTS fh.salary_adjustments (
          id              SERIAL PRIMARY KEY,
          employee_id     INTEGER NOT NULL REFERENCES fh.employees(id) ON DELETE CASCADE,
          adjustment_type TEXT NOT NULL
                          CHECK (adjustment_type IN ('bonus', 'penalty', 'advance', 'other')),
          amount          NUMERIC(14,2) NOT NULL CHECK (amount > 0),
          reason          TEXT NOT NULL,
          adjustment_date DATE NOT NULL DEFAULT CURRENT_DATE,
          status          TEXT NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending', 'approved', 'rejected')),
          approved_by     INTEGER,
          created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
      )''');
    await c.execute('CREATE INDEX IF NOT EXISTS idx_salary_adj_employee ON fh.salary_adjustments(employee_id)');
    await c.execute('CREATE INDEX IF NOT EXISTS idx_salary_adj_date ON fh.salary_adjustments(adjustment_date)');
    await c.execute('CREATE INDEX IF NOT EXISTS idx_salary_adj_type ON fh.salary_adjustments(adjustment_type)');
    print('fh.salary_adjustments + indexes');

    // 4) VIEW monthly_payroll_summary
    await c.execute(r'''
      CREATE OR REPLACE VIEW fh.monthly_payroll_summary AS
      SELECT
          e.id                                            AS employee_id,
          e.full_name,
          e.position,
          e.department,
          e.base_salary,
          am.month,
          am.days_present,
          am.days_absent,
          am.days_late,
          am.days_sick,
          am.days_vacation,
          am.total_hours,
          COALESCE(sa.bonus, 0)                           AS total_bonus,
          COALESCE(sa.penalty, 0)                         AS total_penalty,
          COALESCE(sa.advance, 0)                         AS total_advance
      FROM fh.employees e
      JOIN (
          SELECT employee_id,
                 date_trunc('month', work_date)::date          AS month,
                 COUNT(*) FILTER (WHERE status = 'present')     AS days_present,
                 COUNT(*) FILTER (WHERE status = 'absent')      AS days_absent,
                 COUNT(*) FILTER (WHERE status = 'late')        AS days_late,
                 COUNT(*) FILTER (WHERE status = 'sick_leave')  AS days_sick,
                 COUNT(*) FILTER (WHERE status = 'vacation')    AS days_vacation,
                 COALESCE(SUM(hours_worked), 0)                 AS total_hours
          FROM fh.attendance
          GROUP BY employee_id, date_trunc('month', work_date)::date
      ) am ON am.employee_id = e.id
      LEFT JOIN (
          SELECT employee_id,
                 date_trunc('month', adjustment_date)::date     AS month,
                 SUM(amount) FILTER (WHERE adjustment_type = 'bonus')    AS bonus,
                 SUM(amount) FILTER (WHERE adjustment_type = 'penalty')  AS penalty,
                 SUM(amount) FILTER (WHERE adjustment_type = 'advance')  AS advance
          FROM fh.salary_adjustments
          WHERE status = 'approved'
          GROUP BY employee_id, date_trunc('month', adjustment_date)::date
      ) sa ON sa.employee_id = e.id AND sa.month = am.month
    ''');
    await c.execute(r'''
      COMMENT ON VIEW fh.monthly_payroll_summary IS
          'Har bir xodim uchun oylik davomat + premiya/jarima/avans yig''indisi. Frontend hisobot ekrani shu view''dan foydalanadi.'
    ''');
    print('fh.monthly_payroll_summary VIEW + comment');

    // 5) users.role CHECK — hr_manager qo'shish
    final cons = await c.execute(
      "SELECT conname FROM pg_constraint WHERE conrelid = 'fh.users'::regclass "
      "AND contype='c' AND pg_get_constraintdef(oid) ILIKE '%role%'");
    for (final r in cons) {
      await c.execute('ALTER TABLE fh.users DROP CONSTRAINT "${r[0]}"');
    }
    await c.execute("""
      ALTER TABLE fh.users ADD CONSTRAINT users_role_check
      CHECK (role IN (
        'admin', 'operations_manager', 'warehouse_controller',
        'warehouse_keeper', 'director', 'hr_manager'
      ))""");
    print('users_role_check: hr_manager qo-shildi');

    await c.execute('COMMIT');
    print('\n=== HR MIGRATSIYA MUVOFFAQIYATLI ===');
  } catch (e) {
    await c.execute('ROLLBACK');
    print('ROLLBACK: $e');
    rethrow;
  } finally {
    await c.close();
  }
}