import '../core/package_model.dart';

/// What a tab of the store's Google Sheet is for. The same role has a
/// different tab name per trade (a restaurant's "Menu & Modifiers" is a
/// shop's "Products & Stock").
enum SheetRole {
  products,
  sales,
  kot,
  tables,
  recipes,
  stockMovements,
  khata,
  expenses,
  dayClose,
}

/// The one definition of the store's Google Sheet: tab names, header rows,
/// and the Drive folder / file prefix for item images, per trade.
///
/// The restaurant layout is byte-for-byte what every restaurant sheet was
/// provisioned with before layouts existed, so those sheets keep working
/// unchanged. Shops (kirana, supermarket, pharmacy, retail) get their own
/// words: products and stock instead of dishes and a kitchen, a counter
/// instead of tables, and a khata ledger. A shop sheet created before this
/// (with the restaurant tab names) is still read and written: see
/// [resolveTabs].
///
/// The Apps Script twin is `sheetLayoutFor_` in google_apps_script/Code.gs.
/// Change one, change the other.
class SheetLayout {
  final String vertical;

  /// Tab per role, in the order the tabs are created.
  final Map<SheetRole, String> tabsByRole;

  /// Header row written when the sheet is first provisioned.
  final Map<SheetRole, List<String>> headersByRole;

  /// Header row written when a missing tab is added to an existing sheet.
  /// The same as [headersByRole] except where the restaurant sheet always
  /// used a slightly different row for a re-created tab.
  final Map<SheetRole, List<String>> ensureHeadersByRole;

  /// Drive folder holding the item photos.
  final String imagesFolder;

  /// File-name prefix of an uploaded item photo.
  final String imagePrefix;

  /// Description set on a newly created [imagesFolder].
  final String imagesFolderDescription;

  /// Description of one uploaded photo; `{id}` stands for the item id.
  final String imageFileDescription;

  const SheetLayout._({
    required this.vertical,
    required this.tabsByRole,
    required this.headersByRole,
    required this.ensureHeadersByRole,
    required this.imagesFolder,
    required this.imagePrefix,
    required this.imagesFolderDescription,
    required this.imageFileDescription,
  });

  // ── The session's trade ────────────────────────────────────────────────

  static String _activeVertical = Verticals.restaurant;

  /// The signed-in store's trade, set by the entitlements provider whenever
  /// the session changes. Services that are not handed a trade use it.
  static String get activeVertical => _activeVertical;

  static void setActiveVertical(String? vertical) {
    final v = (vertical ?? '').trim().toLowerCase();
    _activeVertical = Verticals.isValid(v) ? v : Verticals.restaurant;
  }

  /// The layout of the signed-in store.
  static SheetLayout get active => forVertical(_activeVertical);

  /// The layout for [vertical]; anything that is not a shop trade reads as
  /// restaurant.
  static SheetLayout forVertical(String? vertical) {
    final v = (vertical ?? '').trim().toLowerCase();
    if (!Verticals.isShop(v)) return restaurant;
    return v == Verticals.pharmacy ? _pharmacy : _shop(v);
  }

  bool get isShop => Verticals.isShop(vertical);

  // ── Tab names ──────────────────────────────────────────────────────────

  String? tabFor(SheetRole role) => tabsByRole[role];

  String get productsTab => tabsByRole[SheetRole.products]!;
  String get salesTab => tabsByRole[SheetRole.sales]!;
  String get expensesTab => tabsByRole[SheetRole.expenses]!;
  String get dayCloseTab => tabsByRole[SheetRole.dayClose]!;

  /// Restaurant only.
  String? get kotTab => tabsByRole[SheetRole.kot];
  String? get tablesTab => tabsByRole[SheetRole.tables];
  String? get recipesTab => tabsByRole[SheetRole.recipes];

  /// Shops only.
  String? get stockMovementsTab => tabsByRole[SheetRole.stockMovements];
  String? get khataTab => tabsByRole[SheetRole.khata];

  /// Every tab, in creation order.
  List<String> get tabs => tabsByRole.values.toList(growable: false);

  // ── Headers ────────────────────────────────────────────────────────────

  List<String> headersFor(SheetRole role) => headersByRole[role] ?? const [];

  List<String> ensureHeadersFor(SheetRole role) =>
      ensureHeadersByRole[role] ?? headersFor(role);

  List<String> get productHeaders => headersFor(SheetRole.products);
  List<String> get salesHeaders => headersFor(SheetRole.sales);
  List<String> get expenseHeaders => headersFor(SheetRole.expenses);
  List<String> get dayCloseHeaders => headersFor(SheetRole.dayClose);

  /// Provisioning header row of the tab named [tab] (empty when the tab is
  /// not part of this layout).
  List<String> headersForTab(String tab) {
    for (final e in tabsByRole.entries) {
      if (e.value == tab) return headersFor(e.key);
    }
    return const [];
  }

  /// Photo file name for item [id] uploaded at [timestampMs].
  String imageFileName(String id, int timestampMs) => '$imagePrefix${id}_$timestampMs.jpg';

  String imageDescriptionFor(String id) => imageFileDescription.replaceAll('{id}', id);

  // ── A1 notation ────────────────────────────────────────────────────────

  /// Column letter of the 1-based column [n]: 1 is A, 26 is Z, 27 is AA.
  static String colLetter(int n) {
    if (n < 1) throw ArgumentError.value(n, 'n', 'columns start at 1');
    final codes = <int>[];
    var x = n;
    while (x > 0) {
      codes.insert(0, 65 + (x - 1) % 26);
      x = (x - 1) ~/ 26;
    }
    return String.fromCharCodes(codes);
  }

  /// A tab name quoted for A1 notation.
  static String quoteTab(String tab) => "'${tab.replaceAll("'", "''")}'";

  /// Range from row [firstRow] of column A to row [lastRow] of the
  /// [columns]-th column: `'Menu & Modifiers'!A2:L1000` for 12 columns.
  static String range(String tab, int columns, {int firstRow = 2, int lastRow = 1000}) =>
      '${quoteTab(tab)}!A$firstRow:${colLetter(columns)}$lastRow';

  /// The header row range: `'Dining Bills'!A1:L1` for 12 columns.
  static String headerRange(String tab, int columns) =>
      '${quoteTab(tab)}!A1:${colLetter(columns)}1';

  /// The top-left cell of a write starting at [row]: `'Tables & QR'!A2`.
  static String anchor(String tab, {int row = 2}) => '${quoteTab(tab)}!A$row';

  // ── Legacy tab detection ───────────────────────────────────────────────

  /// Tab names a role had in sheets provisioned before per-trade layouts
  /// (every trade got the restaurant tabs then).
  static const Map<SheetRole, List<String>> legacyTabNames = {
    SheetRole.products: ['Menu & Modifiers'],
    SheetRole.sales: ['Dining Bills'],
    SheetRole.expenses: ['Kitchen Expenses'],
    SheetRole.dayClose: ['Day End Reports'],
  };

  /// Which tab each role of this layout uses in a spreadsheet whose tabs are
  /// [existingTitles] (from `spreadsheets.get`, `sheets.properties.title`).
  ///
  /// A role whose own tab exists uses it. Otherwise, when a pre-layout tab
  /// for that role exists (a shop sheet made with the restaurant names),
  /// that tab keeps being used - legacy mode - so no data is split across
  /// two tabs. Only roles with neither are listed in `missing`, to be added.
  /// Old tabs are never removed or renamed.
  ResolvedSheetTabs resolveTabs(Iterable<String> existingTitles) {
    final existing = existingTitles.toSet();
    final byRole = <SheetRole, String>{};
    final missing = <String>[];
    final legacyRoles = <SheetRole>{};
    for (final e in tabsByRole.entries) {
      final own = e.value;
      if (existing.contains(own)) {
        byRole[e.key] = own;
        continue;
      }
      String? legacy;
      if (isShop) {
        for (final old in legacyTabNames[e.key] ?? const <String>[]) {
          if (existing.contains(old)) {
            legacy = old;
            break;
          }
        }
      }
      if (legacy != null) {
        byRole[e.key] = legacy;
        legacyRoles.add(e.key);
      } else {
        byRole[e.key] = own;
        missing.add(own);
      }
    }
    return ResolvedSheetTabs._(byRole, legacyRoles, missing);
  }

  // ── Item <-> row, by header name ───────────────────────────────────────

  /// The item field a header stands for, whatever layout (or older
  /// spelling) wrote it; `null` for a column the app does not own (a
  /// user's own column, the server's `rev`), whose cells are kept.
  static String? fieldForHeader(String header) {
    final h = header.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    switch (h) {
      case 'productid':
      case 'dishid':
      case 'itemid':
      case 'id':
        return 'id';
      case 'productname':
      case 'dishname':
      case 'itemname':
      case 'name':
        return 'name';
      case 'category':
        return 'category';
      case 'barcode':
        return 'barcode';
      case 'sku':
        return 'sku';
      case 'unit':
      case 'unitkggmlpcs':
        return 'unit';
      case 'price':
      case 'pricers':
      case 'sellingprice':
        return 'price';
      case 'mrp':
        return 'mrp';
      case 'costprice':
      case 'purchaseprice':
        return 'costPrice';
      case 'hsn':
      case 'hsncode':
        return 'hsnCode';
      case 'taxexempt':
        return 'isTaxExempt';
      case 'stock':
      case 'stockquantity':
        return 'stock';
      case 'reorderlevel':
        return 'reorderLevel';
      case 'batchno':
        return 'batchNo';
      case 'expiry':
      case 'expirynearestbatch':
        return 'expiry';
      case 'available':
      case 'isavailable':
        return 'isAvailable';
      case 'image':
      case 'imageurl':
        return 'imageUrl';
      case 'soldbyweight':
        return 'soldByWeight';
      case 'plu':
        return 'pluCode';
      case 'variants':
        return 'variants';
      case 'foodtypevegnonveg':
        return 'isVeg';
      case 'preptimemins':
        return 'prepTime';
      case 'kitchenstation':
        return 'station';
      case 'availablefrom':
        return 'availableFrom';
      case 'availableto':
        return 'availableTo';
      case 'istimerestricted':
        return 'isTimeRestricted';
    }
    return null;
  }

  static num? _num(Object? v) {
    if (v is num) return v;
    if (v == null) return null;
    return num.tryParse(v.toString().replaceAll(RegExp(r'[^0-9.\-]'), ''));
  }

  static String _fmt(num n) => n == n.roundToDouble() ? n.toInt().toString() : n.toString();

  /// Keeps a code such as a barcode as text in the sheet: with
  /// USER_ENTERED an all-digit value would become a number and lose its
  /// leading zeros. The apostrophe is not stored in the cell.
  static String _asText(Object? v) {
    final s = (v ?? '').toString().trim();
    if (s.isEmpty) return '';
    return RegExp(r'^[0-9]+$').hasMatch(s) ? "'$s" : s;
  }

  static String _yesNo(Object? v) =>
      (v == true || v?.toString().toLowerCase() == 'true') ? 'Yes' : 'No';

  static List<Map> _batches(Map item) =>
      (item['batches'] is List) ? (item['batches'] as List).whereType<Map>().toList() : const [];

  /// The batch with stock left that expires first.
  static Map? _nearestBatch(Map item) {
    Map? best;
    DateTime? bestAt;
    for (final b in _batches(item)) {
      final q = _num(b['qty'] ?? b['quantity']) ?? 0;
      if (q <= 0) continue;
      final at = DateTime.tryParse((b['expiry'] ?? '').toString());
      if (best == null || (at != null && (bestAt == null || at.isBefore(bestAt)))) {
        best = b;
        bestAt = at;
      }
    }
    return best;
  }

  static num? _stockOf(Map item) {
    final q = _num(item['stockQuantity']) ?? _num(item['stock_quantity']) ?? _num(item['stock']);
    if (q != null) return q;
    final b = _batches(item);
    if (b.isEmpty) return null;
    num sum = 0;
    for (final x in b) {
      sum += _num(x['qty'] ?? x['quantity']) ?? 0;
    }
    return sum;
  }

  /// One entry per variant: `M/Red ₹499 (5); L/Red ₹499 (2)`.
  static String variantsSummary(Object? raw) {
    if (raw is! List) return '';
    final parts = <String>[];
    for (final v in raw.whereType<Map>()) {
      var label = (v['label'] ?? '').toString().trim();
      if (label.isEmpty) {
        label = [v['size'], v['color']]
            .where((x) => x != null && x.toString().trim().isNotEmpty)
            .join('/');
      }
      if (label.isEmpty) label = (v['id'] ?? '').toString();
      final buf = StringBuffer(label);
      final price = _num(v['price']);
      if (price != null) buf.write(' ₹${_fmt(price)}');
      final stock = _stockOf(v);
      if (stock != null) buf.write(' (${_fmt(stock)})');
      parts.add(buf.toString());
    }
    return parts.join('; ');
  }

  /// The cell for [header] of [item], or `null` when the header is not an
  /// app column (the caller keeps what the cell held). A field the item
  /// does not carry is written blank - never a made-up default.
  static Object? valueForHeader(String header, Map item) {
    final field = fieldForHeader(header);
    if (field == null) return null;
    switch (field) {
      case 'id':
        return _asText(item['id']);
      case 'name':
        return (item['name'] ?? '').toString();
      case 'category':
        return (item['category'] ?? '').toString();
      case 'barcode':
        return _asText(item['barcode']);
      case 'sku':
        return _asText(item['sku']);
      case 'unit':
        return (item['unit'] ?? '').toString();
      case 'price':
        return item['price'] ?? item['selling_price'] ?? '';
      case 'mrp':
        return item['mrp'] ?? '';
      case 'costPrice':
        return item['costPrice'] ?? item['purchase_price'] ?? item['cost_price'] ?? '';
      case 'hsnCode':
        return _asText(item['hsnCode'] ?? item['hsn']);
      case 'isTaxExempt':
        return _yesNo(item['isTaxExempt'] ?? item['is_tax_exempt']);
      case 'stock':
        return _stockOf(item) ?? '';
      case 'reorderLevel':
        return item['reorderLevel'] ?? '';
      case 'batchNo':
        return (_nearestBatch(item)?['batchNo'] ?? '').toString();
      case 'expiry':
        final e = DateTime.tryParse((_nearestBatch(item)?['expiry'] ?? '').toString());
        if (e == null) return '';
        return '${e.year.toString().padLeft(4, '0')}-'
            '${e.month.toString().padLeft(2, '0')}-'
            '${e.day.toString().padLeft(2, '0')}';
      case 'isAvailable':
        final a = item['isAvailable'] ?? item['is_available'];
        return a == false ? 'Sold Out' : 'Available';
      case 'imageUrl':
        return (item['imageUrl'] ?? '').toString();
      case 'soldByWeight':
        return item.containsKey('soldByWeight') ? _yesNo(item['soldByWeight']) : '';
      case 'pluCode':
        return _asText(item['pluCode']);
      case 'variants':
        return variantsSummary(item['variants']);
      case 'isVeg':
        if (item['isVeg'] == null) return '';
        return item['isVeg'] == true ? 'Veg' : 'Non-Veg';
      case 'prepTime':
        return item['prepTime'] ?? '';
      case 'station':
        return (item['station'] ?? '').toString();
      case 'availableFrom':
        return (item['availableFrom'] ?? '').toString();
      case 'availableTo':
        return (item['availableTo'] ?? '').toString();
      case 'isTimeRestricted':
        return item['isTimeRestricted'] == null ? '' : _yesNo(item['isTimeRestricted']);
    }
    return null;
  }

  /// [existing] (a tab's current header row) plus every header of
  /// [layout] whose field it does not already have, appended at the end.
  /// Existing columns are never moved, so nothing that reads by position
  /// shifts. An empty [existing] gives [layout].
  static List<String> mergeHeaders(List<Object?> existing, List<String> layout) {
    final cur = existing.map((e) => (e ?? '').toString()).toList();
    while (cur.isNotEmpty && cur.last.trim().isEmpty) {
      cur.removeLast();
    }
    if (cur.isEmpty) return List<String>.from(layout);
    String keyOf(String h) => fieldForHeader(h) ?? 'raw:${h.trim().toLowerCase()}';
    final have = <String>{for (final h in cur) keyOf(h)};
    final out = List<String>.from(cur);
    for (final h in layout) {
      if (have.add(keyOf(h))) out.add(h);
    }
    return out;
  }

  /// Data rows for [items] under [headers]. A column the app does not own
  /// keeps the value the same item's row (matched by id) had in
  /// [existingRows] (data rows, no header).
  static List<List<Object?>> buildRows({
    required List<String> headers,
    required List<Map> items,
    List<List<Object?>> existingRows = const [],
  }) {
    final idCol = headers.indexWhere((h) => fieldForHeader(h) == 'id');
    final byId = <String, List<Object?>>{};
    if (idCol >= 0) {
      for (final r in existingRows) {
        if (r.length > idCol) {
          final k = (r[idCol] ?? '').toString().trim();
          if (k.isNotEmpty) byId[k] = r;
        }
      }
    }
    final rows = <List<Object?>>[];
    for (final item in items) {
      final old = byId[(item['id'] ?? '').toString().trim()];
      rows.add([
        for (var c = 0; c < headers.length; c++)
          valueForHeader(headers[c], item) ??
              ((old != null && old.length > c) ? (old[c] ?? '') : ''),
      ]);
    }
    return rows;
  }

  /// An item read back from a sheet row, mapped by header name - so a
  /// restaurant-shaped, a shop-shaped or a user-rearranged tab all read
  /// the same. Only columns that are present and non-blank are set.
  static Map<String, dynamic> rowToItem(List<Object?> headers, List<Object?> row) {
    final out = <String, dynamic>{};
    for (var c = 0; c < headers.length && c < row.length; c++) {
      final field = fieldForHeader((headers[c] ?? '').toString());
      if (field == null || field == 'variants') continue;
      final raw = row[c];
      final s = (raw ?? '').toString().trim();
      if (s.isEmpty) continue;
      switch (field) {
        case 'price':
        case 'mrp':
        case 'costPrice':
        case 'stock':
        case 'reorderLevel':
        case 'prepTime':
          final n = _num(raw);
          if (n != null) out[field] = n;
        case 'isAvailable':
          final l = s.toLowerCase();
          out[field] = !(l == 'sold out' || l == 'false' || l == 'no' || l == '0' || l == 'unavailable');
        case 'isTaxExempt':
        case 'soldByWeight':
        case 'isTimeRestricted':
          final l = s.toLowerCase();
          out[field] = l == 'yes' || l == 'true' || l == '1';
        case 'isVeg':
          final l = s.toLowerCase();
          out[field] = !l.contains('non') && l.contains('veg');
        default:
          out[field] = s.startsWith("'") ? s.substring(1) : s;
      }
    }
    return out;
  }

  // ── The layouts ────────────────────────────────────────────────────────

  static const SheetLayout restaurant = SheetLayout._(
    vertical: Verticals.restaurant,
    tabsByRole: {
      SheetRole.products: 'Menu & Modifiers',
      SheetRole.sales: 'Dining Bills',
      SheetRole.kot: 'KOT History',
      SheetRole.tables: 'Tables & QR',
      SheetRole.recipes: 'Recipe Inventory (BOM)',
      SheetRole.expenses: 'Kitchen Expenses',
      SheetRole.dayClose: 'Day End Reports',
    },
    headersByRole: {
      SheetRole.products: [
        'Dish ID',
        'Name',
        'Category',
        'Price (Rs)',
        'Food Type (Veg/NonVeg)',
        'Prep Time (Mins)',
        'Kitchen Station',
        'Is Available',
        'Available From',
        'Available To',
        'Is Time Restricted',
        'Image URL',
      ],
      SheetRole.sales: [
        'Bill ID',
        'Date & Time',
        'Customer Name',
        'Customer Phone',
        'Payment Mode',
        'Subtotal',
        'Discount',
        'Total Amount',
        'Items Summary',
        'Status',
        'Table',
        'Transaction ID',
      ],
      SheetRole.kot: [
        'KOT ID',
        'Token Number',
        'Table Location',
        'Kitchen Station',
        'Punched By',
        'Items Description',
        'Status',
        'Timestamp',
      ],
      SheetRole.tables: [
        'Table ID',
        'Table Number',
        'Section',
        'Capacity',
        'Status',
        'QR Menu Link',
      ],
      SheetRole.recipes: [
        'Material ID',
        'Ingredient Name',
        'Stock Quantity',
        'Unit (kg/g/ml/pcs)',
        'Reorder Level',
        'Cost Per Unit',
      ],
      SheetRole.expenses: [
        'Expense ID',
        'Date',
        'Category (Dairy/Veggies/Gas)',
        'Amount (Rs)',
        'Vendor / Supplier',
        'Note',
      ],
      SheetRole.dayClose: [
        'Date',
        'Total Revenue',
        'Dine-In Sales',
        'Takeaway Sales',
        'Online QR Sales',
        'Cash Collected',
        'UPI Collected',
        'Discounts Given',
      ],
    },
    ensureHeadersByRole: {
      SheetRole.products: [
        'Item ID',
        'Dish Name',
        'Category',
        'Price (Rs)',
        'Food Type (Veg/NonVeg)',
        'Prep Time (Mins)',
        'Kitchen Station',
        'Is Available',
        'Available From',
        'Available To',
        'Is Time Restricted',
        'Image URL',
      ],
    },
    imagesFolder: 'SmartDine_Menu_Images',
    imagePrefix: 'dish_',
    imagesFolderDescription: 'Public menu item images for SmartBizz POS and QR ordering',
    imageFileDescription: 'Menu dish image for dish: {id}',
  );

  static const List<String> _shopProductHead = [
    'Product ID',
    'Product Name',
    'Category',
    'Barcode',
    'SKU',
    'Unit',
    'Price',
    'MRP',
    'Cost Price',
    'HSN',
    'Tax Exempt',
    'Stock',
    'Reorder Level',
  ];

  static const List<String> _shopProductTail = [
    'Available',
    'Image',
    'Sold By Weight',
    'PLU',
    'Variants',
  ];

  static const List<String> _pharmacyBatch = ['Batch No.', 'Expiry (nearest batch)'];

  /// A shop's sales header row: the restaurant row with the table column
  /// holding the counter instead, so every position is unchanged for the
  /// server's positional fallbacks. The customer is in Customer Name/Phone.
  static const List<String> _shopSalesHeaders = [
    'Bill ID',
    'Date & Time',
    'Customer Name',
    'Customer Phone',
    'Payment Mode',
    'Subtotal',
    'Discount',
    'Total Amount',
    'Items Summary',
    'Status',
    'Counter',
    'Transaction ID',
  ];

  static const List<String> _shopStockMovementHeaders = [
    'Movement ID',
    'Date & Time',
    'Product ID',
    'Product Name',
    'Type (Sale/Purchase/Adjustment/Return)',
    'Quantity',
    'Stock After',
    'Batch No.',
    'Reference',
    'By',
  ];

  static const List<String> _shopKhataHeaders = [
    'Transaction ID',
    'Date',
    'Customer Name',
    'Customer Phone',
    'Type (Credit/Payment)',
    'Amount (Rs)',
    'Notes',
  ];

  static const List<String> _shopExpenseHeaders = [
    'Expense ID',
    'Date',
    'Category',
    'Amount (Rs)',
    'Vendor / Supplier',
    'Note',
  ];

  static const List<String> _shopDayCloseHeaders = [
    'Date',
    'Total Revenue',
    'Walk-in Sales',
    'Delivery Sales',
    'Online Sales',
    'Cash Collected',
    'UPI Collected',
    'Discounts Given',
  ];

  static const Map<SheetRole, String> _shopTabs = {
    SheetRole.products: 'Products & Stock',
    SheetRole.sales: 'Sales Bills',
    SheetRole.stockMovements: 'Stock Movements',
    SheetRole.khata: 'Customers & Khata',
    SheetRole.expenses: 'Expenses',
    SheetRole.dayClose: 'Day Close',
  };

  static SheetLayout _shopWith(String vertical, List<String> productHeaders) => SheetLayout._(
        vertical: vertical,
        tabsByRole: _shopTabs,
        headersByRole: {
          SheetRole.products: productHeaders,
          SheetRole.sales: _shopSalesHeaders,
          SheetRole.stockMovements: _shopStockMovementHeaders,
          SheetRole.khata: _shopKhataHeaders,
          SheetRole.expenses: _shopExpenseHeaders,
          SheetRole.dayClose: _shopDayCloseHeaders,
        },
        ensureHeadersByRole: const {},
        imagesFolder: 'SmartBizz_Product_Images',
        imagePrefix: 'product_',
        imagesFolderDescription: 'Public product images for SmartBizz POS',
        imageFileDescription: 'Product image for item: {id}',
      );

  static SheetLayout _shop(String vertical) =>
      _shopWith(vertical, const [..._shopProductHead, ..._shopProductTail]);

  static final SheetLayout _pharmacy = _shopWith(
    Verticals.pharmacy,
    const [..._shopProductHead, ..._pharmacyBatch, ..._shopProductTail],
  );
}

/// The tab each role uses in one particular spreadsheet; see
/// [SheetLayout.resolveTabs].
class ResolvedSheetTabs {
  final Map<SheetRole, String> byRole;

  /// Roles served by a pre-layout (restaurant-named) tab.
  final Set<SheetRole> legacyRoles;

  /// Tabs of the layout that the spreadsheet lacks and should get.
  final List<String> missing;

  const ResolvedSheetTabs._(this.byRole, this.legacyRoles, this.missing);

  String? tab(SheetRole role) => byRole[role];

  bool get isLegacy => legacyRoles.isNotEmpty;

  bool isLegacyRole(SheetRole role) => legacyRoles.contains(role);
}
