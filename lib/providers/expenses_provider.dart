import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'saas_session_provider.dart';
import '../services/firebase_connection_service.dart';

// --- EXPENSES PROVIDER ---
// ARCHITECTURE: Dual-mode — Customer Firestore (Live) or Hive (Mock)
// Expenses belong to the Organization's own Firebase project.

final expensesProvider =
    StateNotifierProvider<ExpensesNotifier, List<Map<String, dynamic>>>((ref) {
  ref.watch(saasSessionProvider);
  return ExpensesNotifier(ref);
});

class ExpensesNotifier extends StateNotifier<List<Map<String, dynamic>>> {
  final Box _box = Hive.box('expenses');
  final Ref _ref;

  ExpensesNotifier(this._ref) : super(const []) {
    load();
  }

  void _loadLocal() {
    final saasSession = _ref.read(saasSessionProvider);
    if (saasSession.currentUser == null) {
      state = const [];
      return;
    }

    final orgId = saasSession.currentOrganization?.id;
    final franchiseId = saasSession.activeFranchiseId;

    var values = _box.values.whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((exp) => exp['is_active'] != false);

    if (saasSession.currentUser?.role != 'MASTER_ADMIN') {
      values = values.where((exp) {
        final expOrg = (exp['organization_id'] ?? exp['organizationId'])?.toString();
        final expFranchise = (exp['franchise_id'] ?? exp['franchiseId'])?.toString();
        if (!saasSession.isMockMode) {
          return expOrg == orgId && expFranchise == franchiseId;
        }
        return (expOrg == null || expOrg == orgId) &&
            (expFranchise == null || expFranchise == franchiseId);
      });
    }

    state = values.toList()
      ..sort((a, b) => (b['timestamp'] as String? ?? '')
          .compareTo(a['timestamp'] as String? ?? ''));
  }

  void load() {
    _loadLocal();
    final saasSession = _ref.read(saasSessionProvider);
    if (saasSession.currentUser != null && !saasSession.isMockMode) {
      _loadFromFirestore();
    }
  }

  Future<void> _loadFromFirestore() async {
    final saasSession = _ref.read(saasSessionProvider);
    final orgId = saasSession.currentOrganization?.id;
    final franchiseId = saasSession.activeFranchiseId;
    final firestore =
        _ref.read(firebaseConnectionServiceProvider).customerFirestore;

    if (firestore == null) return;

    try {
      var query = firestore
          .collection('expenses')
          .where('organizationId', isEqualTo: orgId);

      // MANAGER/STAFF can only see their franchise expenses
      if (saasSession.currentUser?.role == 'MANAGER' ||
          saasSession.currentUser?.role == 'STAFF') {
        query = query.where('franchiseId', isEqualTo: franchiseId);
      }

      final snapshot = await query.get();

      for (var doc in snapshot.docs) {
        final data = {...doc.data(), 'id': doc.id};
        await _box.put(doc.id, data);
      }

      _loadLocal();
    } catch (e) {
      debugPrint('Error loading expenses from Firestore: $e');
    }
  }

  Future<void> addExpense({
    required String title,
    required String category,
    required double amount,
    required String paymentMode,
    String? timestamp,
  }) async {
    final saasSession = _ref.read(saasSessionProvider);
    final orgId = saasSession.currentOrganization?.id;
    final franchiseId = saasSession.activeFranchiseId;
    final ts = timestamp ?? DateTime.now().toIso8601String();

    final String id = saasSession.isMockMode
        ? 'EXPENSE_${DateTime.now().millisecondsSinceEpoch}'
        : 'exp_${DateTime.now().millisecondsSinceEpoch}';

    final expense = {
      'id': id,
      'title': title.trim(),
      'category': category,
      'amount': amount,
      'paymentMode': paymentMode,
      'timestamp': ts,
      'organization_id': orgId,
      'organizationId': orgId,
      'franchise_id': franchiseId,
      'franchiseId': franchiseId,
      'version': DateTime.now().millisecondsSinceEpoch,
      'is_active': true,
      'createdAt': DateTime.now().toIso8601String(),
      'updatedAt': DateTime.now().toIso8601String(),
    };

    await _box.put(id, expense);
    _loadLocal();
  }

  Future<void> updateExpense(
    String id, {
    required String title,
    required String category,
    required double amount,
    required String paymentMode,
  }) async {
    final saasSession = _ref.read(saasSessionProvider);
    final orgId = saasSession.currentOrganization?.id;
    final franchiseId = saasSession.activeFranchiseId;

    final existing = _box.get(id);
    if (existing != null) {
      final expense = Map<String, dynamic>.from(existing as Map);
      expense['title'] = title.trim();
      expense['category'] = category;
      expense['amount'] = amount;
      expense['paymentMode'] = paymentMode;
      expense['organization_id'] = orgId;
      expense['organizationId'] = orgId;
      expense['franchise_id'] = franchiseId;
      expense['franchiseId'] = franchiseId;
      expense['version'] = DateTime.now().millisecondsSinceEpoch;
      expense['updatedAt'] = DateTime.now().toIso8601String();

      await _box.put(id, expense);
      _loadLocal();
    }
  }

  Future<void> deleteExpense(String id) async {
    final existing = _box.get(id);
    if (existing != null) {
      final expense = Map<String, dynamic>.from(existing as Map);
      expense['is_active'] = false;
      expense['version'] = DateTime.now().millisecondsSinceEpoch;
      expense['updatedAt'] = DateTime.now().toIso8601String();

      await _box.put(id, expense);
      _loadLocal();
    }
  }
}
