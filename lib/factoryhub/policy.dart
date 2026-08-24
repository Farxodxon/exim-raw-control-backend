class AppRoles {
  static const admin = 'admin';
  static const operationsManager = 'operations_manager';
  static const warehouseKeeper = 'warehouse_keeper';
  static const warehouseController = 'warehouse_controller';
  static const director = 'director';

  static const all = <String>[
    admin,
    operationsManager,
    warehouseKeeper,
    warehouseController,
    director,
  ];

  static bool isValid(String role) => all.contains(role);
}

class Policy {
  static bool canManageUsers(String role) => role == AppRoles.admin;

  static bool canManageSettings(String role) => role == AppRoles.admin;

  static bool canPlan(String role) =>
      role == AppRoles.admin || role == AppRoles.operationsManager;

  static bool canTransactStock(String role) =>
      role == AppRoles.admin ||
      role == AppRoles.operationsManager ||
      role == AppRoles.warehouseKeeper ||
      role == AppRoles.warehouseController;

  static bool canControlWarehouses(String role) =>
      role == AppRoles.admin || role == AppRoles.warehouseController;
}
