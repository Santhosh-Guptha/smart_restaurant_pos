import 'entitlements.dart';

/// Where a feature actually shows up in the app.
///
/// The platform admin's encyclopedia is generated from this, not written into
/// a screen, for one reason: a console that describes a control the app does
/// not have sells a promise nobody can keep (FEATURE_MASTER_PLAN.md D4).
/// `test/feature_usage_test.dart` fails the build if a key here is unknown to
/// [FeatureCatalog], if a catalogue key has no entry, or if a key never
/// appears at a gating site in `lib/`.
///
/// Everything below was read off the code, in present tense. If a capability
/// is planned but not built, it does not belong here yet.
class FeatureUsage {
  /// Screens this feature opens or removes entirely.
  final List<String> screens;

  /// Individual controls it owns inside screens that exist anyway.
  final List<String> controls;

  /// What the restaurant gets, in one paragraph an admin can read to a client.
  final String note;

  /// What the tenant loses when it is off — the honest other half.
  final String whenOff;

  /// False when the key exists in the catalogue but nothing in the app is
  /// gated by it. The encyclopedia says so in red, and the console refuses to
  /// sell it, because a switch that changes nothing is worse than no switch.
  final bool implemented;

  const FeatureUsage({
    required this.note,
    required this.whenOff,
    this.screens = const [],
    this.controls = const [],
    this.implemented = true,
  });
}

/// One entry per catalogue key.
const Map<String, FeatureUsage> kFeatureUsage = {
  // ── Offline basic ─────────────────────────────────────────────────────────
  FeatureKeys.billing: FeatureUsage(
    note:
        'The till itself. Add dishes to an order, change quantities, apply a '
        'line or bill discount, add a note, let the app work out tax and '
        'service charge, then settle in cash, on the restaurant\'s own card '
        'machine, or against its UPI ID by QR. Voids and discounts above the '
        'limit ask for a manager PIN.',
    whenOff:
        'Never off. Billing survives an expired licence, no network and a '
        'migration in progress — it is the one thing a till must always do.',
    screens: ['Counter till', 'Order history'],
    controls: ['Settle', 'Discount', 'Void (manager PIN)', 'Order notes'],
  ),
  FeatureKeys.qsrBilling: FeatureUsage(
    note:
        'The counter screen: a tappable dish grid by category, search, and a '
        'token number on every order (#101, #102…) that resets at midnight. '
        'This is what a takeaway counter or a quick-service window runs on.',
    whenOff:
        'The Counter Billing card disappears from the home screen. Orders '
        'still exist; there is no fast counter screen to raise them from.',
    screens: ['Home card: Counter Billing', 'Counter till'],
    controls: ['Category dish grid', 'Dish search', 'Token number'],
  ),
  FeatureKeys.menuManagement: FeatureUsage(
    note:
        'Create and edit dishes: name, category and sub-category, price, '
        'veg/non-veg, availability window, and whether the dish goes to the '
        'kitchen or straight over the counter. Mark a dish sold out and it is '
        'unavailable on every terminal at once.',
    whenOff:
        'The Menu Config card disappears. Dishes already on the device still '
        'bill; nobody can add or change one.',
    screens: ['Home card: Menu Config', 'Menu configuration'],
    controls: ['Add / edit dish', 'Manage categories', 'Dish availability (86)'],
  ),
  FeatureKeys.thermalPrinting: FeatureUsage(
    note:
        'Bluetooth thermal printers at 58 mm and 80 mm: connect, set the '
        'receipt layout — store name, address, GSTIN, invoice prefix, header '
        'and footer text, which totals to show — and print the customer bill, '
        'automatically on settlement if the owner wants.',
    whenOff:
        'No printer settings, no Print buttons in the table sheet or order '
        'history. Bills are still raised and can be shared as text or PDF.',
    screens: ['Printer settings'],
    controls: [
      'Print Bill (table sheet)',
      'Print (order history)',
      'Auto-print on settlement',
    ],
  ),
  FeatureKeys.storeConfiguration: FeatureUsage(
    note:
        'Everything about the store itself: name, phone, address, GSTIN and '
        'FSSAI, tax and service-charge rates, packaging and delivery charges, '
        'the UPI ID guests pay into, opening hours and meal shifts.',
    whenOff:
        'The Store Settings card disappears. Whatever was configured stays in '
        'force.',
    screens: ['Home card: Store Settings', 'Store configuration'],
    controls: ['Profile & legal', 'Taxes & charges', 'Payments & UPI', 'Hours & shifts'],
  ),
  FeatureKeys.dayEndReports: FeatureUsage(
    note:
        'Close the day: the Z-report totals the shift by payment mode, '
        'compares counted cash against what the system expects, and hands the '
        'register over.',
    whenOff: 'The Z-report button in the till is absent.',
    controls: ['Z-report / day-end (till app bar)'],
  ),
  FeatureKeys.staffManagement: FeatureUsage(
    note:
        'Add staff with a username, password and 4-digit PIN, and give each a '
        'role — owner, manager, billing, kitchen, waiter — that decides which '
        'screens they can reach.',
    whenOff:
        'The Staff Mapping card disappears. Existing logins keep working.',
    screens: ['Home card: Staff Mapping', 'Staff management'],
    controls: ['Add / edit staff', 'Role', 'PIN'],
  ),
  FeatureKeys.backupRestore: FeatureUsage(
    note:
        'Export everything this device holds — bills, menu, customers, '
        'settings — into one file encrypted with a passphrase the owner '
        'chooses, and restore it onto a new device. Staff logins are not '
        'included; they come back with the owner\'s sign-in.',
    whenOff: 'The backup section in Settings and the printer-layout backup card are absent.',
    controls: ['Settings: Backup & Restore', 'Printer settings: Layout backup'],
  ),

  // ── Offline add-ons ───────────────────────────────────────────────────────
  FeatureKeys.dineInBilling: FeatureUsage(
    note:
        'Pay-later dining. An order can stay open while the guests eat, take '
        'more rounds, and be settled at the end. The till gets a Pending Bills '
        'tab listing every running tab.',
    whenOff:
        'Every order is paid when it is raised. The till has one tab, the '
        'Dine-in choice goes straight to payment, and Collect Payment is '
        'absent from the table sheet and order history.',
    controls: [
      'Till: Pending Bills tab',
      'Till: pay-later choice',
      'Table sheet: Collect Payment',
      'Order history: Collect Payment',
    ],
  ),
  FeatureKeys.tableManagement: FeatureUsage(
    note:
        'The floor. A card per table showing vacant, seated, occupied, billed, '
        'reserved, cleaning or blocked, with seat, clean, block, move and merge '
        'actions, and a table picker in the till so a bill carries its table '
        'number onto the KOT and the printed bill.',
    whenOff:
        'The Tables & Floor card disappears and the till stops asking which '
        'table — a dine-in order is recorded as "Dine-in" and still bills '
        'normally.',
    screens: ['Home card: Tables & Floor', 'Table management'],
    controls: ['Table picker (till)', 'Seat / clean / block', 'Move table', 'Merge tables'],
  ),
  FeatureKeys.reservations: FeatureUsage(
    note:
        'Take a booking over the phone against a specific table: guest name, '
        'phone, party size and time. The table shows as reserved on the floor '
        'so it is not sold twice, and the booking can be edited, seated or '
        'cancelled.',
    whenOff: 'The reserve actions are absent from the table sheet; tables work otherwise.',
    controls: [
      'Table sheet: Reserve Table',
      'Table sheet: Change time / re-reserve',
      'Table sheet: Cancel reservation',
    ],
  ),
  FeatureKeys.dualPrinting: FeatureUsage(
    note:
        'A second slip for the kitchen. When an order is fired, a kitchen '
        'ticket prints with the table, token and the items that need cooking; '
        'counter-only items are left off it.',
    whenOff: 'Only the customer bill prints. The KOT toggle and the KDS slip button are absent.',
    controls: [
      'Store settings: auto-print KOT',
      'KDS: Print Kitchen KOT Slip',
    ],
  ),
  FeatureKeys.expenseManagement: FeatureUsage(
    note:
        'What went out of the drawer: vegetables, gas, wages, repairs — with a '
        'category, an amount and a note, so the day\'s closing cash is the '
        'truth and not a guess.',
    whenOff: 'The Expenses card and the Expense Categories tab in Store Settings are absent.',
    screens: ['Home card: Expenses', 'Expenses'],
    controls: ['Store settings: Expense Categories tab'],
  ),
  FeatureKeys.analytics: FeatureUsage(
    note:
        'Sales read back to the owner: revenue by day and by hour, the rush '
        'pattern across the week, top dishes, category splits and average bill '
        'value, computed from the store\'s own order records.',
    whenOff: 'The Analytics card disappears, along with the kitchen analytics view on the KDS.',
    screens: ['Home card: Analytics & Rush', 'Analytics'],
    controls: ['KDS: kitchen analytics'],
  ),

  // ── Online basic ──────────────────────────────────────────────────────────
  FeatureKeys.cloudSync: FeatureUsage(
    note:
        'The shared ledger. Bills, tables and order status go to the cloud '
        'store and come back to every other device, with anything raised '
        'offline queued and sent when the connection returns. This is what '
        'makes a second device possible at all.',
    whenOff:
        'The store is a single till with its own records. Nothing leaves the '
        'device: no sync, no Refresh, no Google grants, no new-order chime, '
        'and the queue simply holds anything that would have been sent.',
    controls: [
      'Order history: Refresh',
      'Menu: Sync to cloud / Pull from Sheets',
      'Settings: new-KOT sound',
      'Staff: Google sheet access',
      'Table & menu sync to the store sheet',
    ],
  ),

  // ── Online add-ons ────────────────────────────────────────────────────────
  FeatureKeys.emailReceipts: FeatureUsage(
    note:
        'Ask the guest for an e-mail at checkout and send them the bill.',
    whenOff: 'The e-mail field is absent from the payment sheets; nothing else changes.',
    controls: ['Till: customer e-mail field', 'Waiter: customer e-mail field'],
  ),
  FeatureKeys.kdsEnabled: FeatureUsage(
    note:
        'A screen in the kitchen instead of paper. Tickets arrive live and '
        'move through new → cooking → ready, with a timer on each, a chime on '
        'arrival, and a station filter so the tandoor sees tandoor items. '
        'Dishes carry a station, and staff can be assigned to one.',
    whenOff:
        'The Kitchen (KDS) card disappears, and the station fields vanish from '
        'the dish editor and the staff editor because nothing reads them.',
    screens: ['Home card: Kitchen (KDS)', 'Kitchen display'],
    controls: [
      'Menu: Kitchen Stations',
      'Menu: dish station',
      'Staff: assigned station',
    ],
  ),
  FeatureKeys.waiterOrdering: FeatureUsage(
    note:
        'A phone or tablet on the floor. The captain picks a table, takes the '
        'order there, and fires it to the kitchen without walking to the '
        'counter. Rounds can be added to a running tab.',
    whenOff:
        'The Waiter Pad card disappears. On the floor screen, a table card '
        'seats the guest and nothing more — dishes are added from the till.',
    screens: ['Home card: Waiter Pad', 'Waiter pad (table picker)', 'Waiter order taking'],
    controls: ['Table card: Take Order', 'Table sheet: Place order for customers'],
  ),
  FeatureKeys.onlineMenu: FeatureUsage(
    note:
        'A public web menu for the store, published from the POS menu: '
        'categories, dishes, veg marks and prices, kept current every time the '
        'menu is saved.',
    whenOff:
        'Nothing is published. The menu-link buttons are absent, and the menu '
        'screen stops writing the public store record.',
    controls: [
      'Menu: publish to the public store',
      'Branches: Copy menu link',
      'Branches: Open menu',
    ],
  ),
  FeatureKeys.qrOrdering: FeatureUsage(
    note:
        'A QR standee per table. The guest scans it, sees the menu, and places '
        'an order that lands on the counter and the kitchen marked as coming '
        'from that table.',
    whenOff: 'The QR buttons on table cards, in the table sheet and on the branch cards are absent.',
    controls: [
      'Table card: QR',
      'Table sheet: Table QR standee',
      'Branches: Print table QR standees',
    ],
  ),
  FeatureKeys.onlineOrderingEnabled: FeatureUsage(
    note:
        'Lets the public menu take takeaway orders, not just show the menu — '
        'the link can be shared anywhere. Switching it off leaves the menu '
        'readable and tells guests the store is not taking orders online.',
    whenOff:
        'The guest page shows the menu but no cart. (The guest web app is a '
        'separate deployment; it reads this flag from the public store record.)',
    controls: ['Public store record: onlineOrderingEnabled'],
  ),
  FeatureKeys.multiOutlet: FeatureUsage(
    note:
        'More than one branch under one owner: create outlets, switch between '
        'them, and scope reports to one store, several, or all of them.',
    whenOff:
        'The Outlets card disappears, analytics has no store scope, and order '
        'history stops looking for sibling outlets.',
    screens: ['Home card: Outlets / Stores', 'Branch management'],
    controls: ['Analytics: store scope', 'Order history: outlet filter'],
  ),
  FeatureKeys.inventoryEnabled: FeatureUsage(
    implemented: false,
    note:
        'NOT BUILT. The key exists and can be switched on, but no screen, '
        'field or button in the app reads it — turning it on changes nothing '
        'a restaurant would notice. Stock tracking, ingredient recipes and '
        'supplier orders are all unwritten. Do not include it in a package '
        'or promise it to a client until it has code behind it.',
    whenOff: 'Identical to on, which is the problem.',
  ),
};
