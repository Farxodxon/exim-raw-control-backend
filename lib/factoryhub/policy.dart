class AppRoles {
  static const admin = 'admin';
  static const operationsManager = 'operations_manager';
  static const warehouseKeeper = 'warehouse_keeper';
  static const warehouseController = 'warehouse_controller';
  static const director = 'director';
  static const hrManager = 'hr_manager';
  static const employee = 'employee';

  static const all = <String>[
    admin,
    operationsManager,
    warehouseKeeper,
    warehouseController,
    director,
    hrManager,
    employee,
  ];

  static bool isValid(String role) => all.contains(role);
}

class Policy {
  static bool canManageUsers(String role) => role == AppRoles.admin;

  static bool canManageSettings(String role) => role == AppRoles.admin;

  // Admin va director BARCHA omborlar va modullarga to'liq kirishga ega.
  static bool canViewAllWarehouses(String role) =>
      role == AppRoles.admin || role == AppRoles.director;

  static bool canPlan(String role) =>
      role == AppRoles.admin || role == AppRoles.operationsManager;

  static bool canTransactStock(String role) =>
      role == AppRoles.admin ||
      role == AppRoles.operationsManager ||
      role == AppRoles.warehouseKeeper ||
      role == AppRoles.warehouseController;

  static bool canControlWarehouses(String role) =>
      role == AppRoles.admin || role == AppRoles.warehouseController;

  // ─── HR moduli ─────────────────────────────────────────────
  // admin — to'liq; hr_manager — to'liq (faqat HR); director — faqat ko'rish.
  static bool canReadHr(String role) =>
      role == AppRoles.admin ||
      role == AppRoles.hrManager ||
      role == AppRoles.director;

  static bool canManageHr(String role) =>
      role == AppRoles.admin || role == AppRoles.hrManager;

  // ─── Xodim (employee) — faqat o'z davomatini belgilaydi ────
  static bool isEmployee(String role) => role == AppRoles.employee;

  // GPS o'z-o'zini belgilash: xodim o'zi yoki HR/admin (sinov uchun).
  static bool canSelfCheckin(String role) =>
      role == AppRoles.employee || canManageHr(role);
}
