/// Carry the owner's printer settings into their invoice template, once.
///
/// Before the template engine, layout was a handful of switches on
/// `PrinterState`: a header line, a note, whether to show tax, how many lines
/// to feed at the end. Those switches now have no code reading them, so
/// without this an upgraded tenant would silently lose settings they had
/// configured — the header they typed would stop printing and nobody would
/// know until a customer looked at a slip.
///
/// It runs once per organisation, and only when the owner actually changed
/// something. A tenant on the defaults gets no edit at all, which keeps their
/// invoice byte-identical to the one `receipt_golden_test.dart` pins.
library;

import 'package:hive_flutter/hive_flutter.dart';

import 'receipt_store.dart';
import 'receipt_template.dart';
import 'starter_templates.dart';

class PrinterLayoutMigration {
  PrinterLayoutMigration._();

  static const String _markerKey = '_printer_layout_migrated_v1';

  /// True when any of these differs from what the app ships with. Checked
  /// before touching anything, so the common case costs one Hive read.
  ///
  /// `showCustomer` is deliberately absent. It defaults to on, but only the
  /// order-history generator ever honoured it \u2014 the counter bill, the one
  /// a customer is actually handed, has never printed their name or phone.
  /// Migrating it would start printing guests' phone numbers on every slip in
  /// the restaurant on the strength of a default nobody chose. The lines are
  /// two taps away in the editor for an owner who wants them.
  static bool hasCustomisation({
    String? customHeader,
    String? customNotes,
    bool showGst = true,
    bool showDiscount = true,
    bool boldItems = false,
    int feedLines = 3,
    String? invoicePrefix,
  }) =>
      (customHeader ?? '').trim().isNotEmpty ||
      (customNotes ?? '').trim().isNotEmpty ||
      !showGst ||
      !showDiscount ||
      boldItems ||
      feedLines != 3 ||
      ((invoicePrefix ?? 'INV-').trim().isNotEmpty &&
          (invoicePrefix ?? 'INV-').trim() != 'INV-');

  /// Apply the settings to this tenant's classic invoice.
  ///
  /// Returns the migrated template, or null when there was nothing to do.
  /// Never throws: a migration that fails leaves the tenant on the shipped
  /// template, which prints correctly.
  static Future<ReceiptTemplate?> run({
    required String orgId,
    String? customHeader,
    String alignHeader = 'center',
    String? customNotes,
    bool showGst = true,
    bool showDiscount = true,
    bool boldItems = false,
    int feedLines = 3,
    String? invoicePrefix,
    bool force = false,
  }) async {
    try {
      final box = await Hive.openBox(ReceiptTemplateStore.boxNameFor(orgId));
      if (!force && box.get(_markerKey) == true) return null;

      final customised = hasCustomisation(
        customHeader: customHeader,
        customNotes: customNotes,
        showGst: showGst,
        showDiscount: showDiscount,
        boldItems: boldItems,
        feedLines: feedLines,
        invoicePrefix: invoicePrefix,
      );

      // Mark it done either way. A tenant on the defaults needs no edit, and
      // re-checking on every launch is the shape of bug that quietly rewrites
      // a document the owner has since edited by hand.
      await box.put(_markerKey, true);
      if (!customised) return null;

      await ReceiptTemplateStore.ensureSeeded(orgId);
      final current =
          await ReceiptTemplateStore.byId(orgId, StarterTemplates.invoiceClassicId) ??
              StarterTemplates.classicInvoice;

      final migrated = apply(
        current,
        customHeader: customHeader,
        alignHeader: alignHeader,
        customNotes: customNotes,
        showGst: showGst,
        showDiscount: showDiscount,
        boldItems: boldItems,
        feedLines: feedLines,
        invoicePrefix: invoicePrefix,
      );

      await ReceiptTemplateStore.save(orgId, migrated);
      return migrated;
    } catch (_) {
      return null;
    }
  }

  /// The edit itself, pure so it can be tested without a box.
  static ReceiptTemplate apply(
    ReceiptTemplate template, {
    String? customHeader,
    String alignHeader = 'center',
    String? customNotes,
    bool showGst = true,
    bool showDiscount = true,
    bool boldItems = false,
    int feedLines = 3,
    String? invoicePrefix,
    /// Off by default \u2014 see [hasCustomisation]. Available so the editor and
    /// a tenant who asks for it can have the lines.
    bool showCustomer = false,
  }) {
    final blocks = <ReceiptBlock>[];

    // The owner's header line goes above everything, which is where the old
    // generator put it.
    final header = (customHeader ?? '').trim();
    if (header.isNotEmpty) {
      blocks.add(ReceiptBlock(
        type: BlockType.text,
        style: BlockStyle(align: _align(alignHeader), bold: true),
        props: {'value': header, 'wrap': false},
      ));
    }

    final lastSpacer =
        template.blocks.lastIndexWhere((b) => b.type == BlockType.spacer);

    for (var i = 0; i < template.blocks.length; i++) {
      final b = template.blocks[i];
      // The invoice prefix was applied to the bill number by the old
      // generator. It lives on the identifiers row.
      if (b.type == BlockType.columns) {
        blocks.add(_withPrefix(b, invoicePrefix));
        continue;
      }

      if (b.type == BlockType.items) {
        blocks.add(ReceiptBlock(
          type: b.type,
          style: b.style.copyWith(bold: boldItems || b.style.bold),
          when: b.when,
          props: b.props,
        ));
        continue;
      }

      if (b.type == BlockType.totals) {
        final rows = _rows(b, showGst: showGst, showDiscount: showDiscount);
        if (rows.isEmpty) continue;
        blocks.add(ReceiptBlock(
          type: b.type,
          style: b.style,
          when: b.when,
          props: {...b.props, 'rows': rows},
        ));
        continue;
      }

      // The owner's note, and then the trailing feed, both sit around the
      // final spacer.
      if (b.type == BlockType.spacer && i == lastSpacer) {
        final note = (customNotes ?? '').trim();
        if (note.isNotEmpty) {
          blocks.add(ReceiptBlock(
            type: BlockType.text,
            style: const BlockStyle(align: TextAlign_.center),
            props: {'value': note},
          ));
        }
        blocks.add(ReceiptBlock(
          type: BlockType.spacer,
          props: {'lines': feedLines < 1 ? 1 : feedLines},
        ));
        continue;
      }

      blocks.add(b);
    }

    if (showCustomer) {
      _insertCustomer(blocks);
    }

    return template.copyWith(blocks: blocks);
  }

  // ── pieces ──────────────────────────────────────────────────────────────

  static TextAlign_ _align(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'left':
        return TextAlign_.left;
      case 'right':
        return TextAlign_.right;
      default:
        return TextAlign_.center;
    }
  }

  static ReceiptBlock _withPrefix(ReceiptBlock b, String? prefix) {
    final p = (prefix ?? '').trim();
    if (p.isEmpty || p == 'INV-') return b;

    final cells = (b.props['cells'] as List?) ?? const [];
    var touched = false;
    final out = <Map<String, dynamic>>[];
    for (final cell in cells) {
      if (cell is! Map) continue;
      final m = Map<String, dynamic>.from(cell);
      final value = (m['value'] ?? '').toString();
      if (value.contains('{{order.id}}') && !value.contains(p)) {
        m['value'] = value.replaceAll('{{order.id}}', '$p{{order.id}}');
        touched = true;
      }
      out.add(m);
    }
    if (!touched) return b;
    return ReceiptBlock(
      type: b.type,
      style: b.style,
      when: b.when,
      props: {...b.props, 'cells': out},
    );
  }

  static List<String> _rows(ReceiptBlock b,
      {required bool showGst, required bool showDiscount}) {
    final rows = b.rows.isEmpty
        ? const [
            'subtotal',
            'discount',
            'serviceCharge',
            'cgst',
            'sgst',
            'roundOff',
            'grandTotal',
          ]
        : b.rows;
    return [
      for (final r in rows)
        if (!(r == 'cgst' || r == 'sgst') || showGst)
          if (r != 'discount' || showDiscount) r,
    ];
  }

  /// The old generator printed the customer's name and phone when the switch
  /// was on. The shipped template has no customer lines at all, so they are
  /// added above the items rather than edited in.
  static void _insertCustomer(List<ReceiptBlock> blocks) {
    if (blocks.any((b) =>
        b.type == BlockType.field &&
        b.value.contains('{{order.customerName}}'))) {
      return;
    }

    const name = ReceiptBlock(
      type: BlockType.field,
      when: 'order.customerName != ""',
      props: {'label': 'CUSTOMER', 'value': '{{order.customerName}}'},
    );
    const phone = ReceiptBlock(
      type: BlockType.field,
      when: 'order.customerPhone != ""',
      props: {'label': 'PHONE', 'value': '{{order.customerPhone}}'},
    );

    final at = blocks.indexWhere((b) => b.type == BlockType.items);
    // The rule below the identifiers is the natural seam; without an items
    // block the lines go at the end rather than nowhere.
    final index = at <= 0 ? blocks.length : at - 1;
    blocks.insertAll(index, [name, phone]);
  }
}
