import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_store.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_template.dart';
import 'package:smart_restaurant_pos/core/receipt/starter_templates.dart';

/// R4: where the tenant's slips live, and which one each order prints.
///
/// The assertion that matters most is the last group: `resolve` is called from
/// the settlement path, so it has to return something printable no matter how
/// badly the stored data has been mangled.
void main() {
  late Directory dir;
  const org = 'ORG_TEST';

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('receipt_store_test');
    Hive.init(dir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    await Hive.deleteBoxFromDisk(ReceiptTemplateStore.boxNameFor(org));
  });

  group('seeding', () {
    test('the starter pack arrives on first open', () async {
      final all = await ReceiptTemplateStore.all(org);
      expect(all.length, StarterTemplates.all.length);
      expect(all.map((t) => t.id).toSet(),
          StarterTemplates.all.map((t) => t.id).toSet());
    });

    test('it never overwrites an edit', () async {
      await ReceiptTemplateStore.ensureSeeded(org);
      final mine = StarterTemplates.classicInvoice.copyWith(name: 'My invoice');
      await ReceiptTemplateStore.save(org, mine);

      await ReceiptTemplateStore.ensureSeeded(org);
      final back = await ReceiptTemplateStore.byId(
          org, StarterTemplates.invoiceClassicId);
      expect(back!.name, 'My invoice');
    });

    test('a deleted copy does not come back', () async {
      await ReceiptTemplateStore.ensureSeeded(org);
      final copy = await ReceiptTemplateStore.duplicate(
          org, StarterTemplates.largeToken);
      await ReceiptTemplateStore.delete(org, copy.id);
      await ReceiptTemplateStore.ensureSeeded(org);
      expect(await ReceiptTemplateStore.byId(org, copy.id), isNull);
    });

    test('each organisation gets its own box', () async {
      await ReceiptTemplateStore.ensureSeeded('ORG_A');
      await ReceiptTemplateStore.save('ORG_A',
          StarterTemplates.classicInvoice.copyWith(name: 'A only'));
      final b = await ReceiptTemplateStore.byId(
          'ORG_B', StarterTemplates.invoiceClassicId);
      expect(b, isNull, reason: 'ORG_B has not been seeded yet');
      await Hive.deleteBoxFromDisk(ReceiptTemplateStore.boxNameFor('ORG_A'));
      await Hive.deleteBoxFromDisk(ReceiptTemplateStore.boxNameFor('ORG_B'));
    });
  });

  group('editing', () {
    test('a saved template comes back the same', () async {
      final edited = StarterTemplates.largeToken
          .copyWith(name: 'Counter token', paper: '80');
      await ReceiptTemplateStore.save(org, edited);
      final back =
          await ReceiptTemplateStore.byId(org, StarterTemplates.tokenLargeId);
      expect(back!.name, 'Counter token');
      expect(back.paper, '80');
      expect(back.blocks.length, edited.blocks.length);
    });

    test('a starter cannot be deleted, only reset', () async {
      await ReceiptTemplateStore.ensureSeeded(org);
      expect(
          await ReceiptTemplateStore.delete(
              org, StarterTemplates.invoiceClassicId),
          isFalse);
      expect(
          await ReceiptTemplateStore.byId(
              org, StarterTemplates.invoiceClassicId),
          isNotNull);

      await ReceiptTemplateStore.save(org,
          StarterTemplates.classicInvoice.copyWith(name: 'Mangled', blocks: const []));
      final reset = await ReceiptTemplateStore.resetToStarter(
          org, StarterTemplates.invoiceClassicId);
      expect(reset!.name, StarterTemplates.classicInvoice.name);
      expect(reset.blocks.length, StarterTemplates.classicInvoice.blocks.length);
    });

    test('a duplicate gets a free id and does not touch the original', () async {
      await ReceiptTemplateStore.ensureSeeded(org);
      final one = await ReceiptTemplateStore.duplicate(
          org, StarterTemplates.classicInvoice);
      final two = await ReceiptTemplateStore.duplicate(
          org, StarterTemplates.classicInvoice);
      expect(one.id, isNot(two.id));
      expect(one.kind, ReceiptKind.invoice);
      final original = await ReceiptTemplateStore.byId(
          org, StarterTemplates.invoiceClassicId);
      expect(original!.name, StarterTemplates.classicInvoice.name);
    });

    test('listing by kind returns only that kind', () async {
      final tokens =
          await ReceiptTemplateStore.all(org, kind: ReceiptKind.token);
      expect(tokens, isNotEmpty);
      expect(tokens.every((t) => t.kind == ReceiptKind.token), isTrue);
    });
  });

  group('mapping an order type to a slip', () {
    test('what is mapped is what resolves', () async {
      await ReceiptTemplateStore.ensureSeeded(org);
      await ReceiptTemplateStore.setMapping(org, ReceiptKind.invoice,
          'Takeaway', StarterTemplates.invoiceCompactId);

      final takeaway = await ReceiptTemplateStore.resolve(
          org, ReceiptKind.invoice,
          channel: 'Takeaway');
      expect(takeaway.id, StarterTemplates.invoiceCompactId);

      final dineIn = await ReceiptTemplateStore.resolve(org, ReceiptKind.invoice,
          channel: 'Dine-In');
      expect(dineIn.id, StarterTemplates.invoiceClassicId,
          reason: 'an unmapped order type falls back to the default');
    });

    test('order type spellings are forgiving', () async {
      await ReceiptTemplateStore.ensureSeeded(org);
      await ReceiptTemplateStore.setMapping(org, ReceiptKind.invoice, 'dine_in',
          StarterTemplates.invoiceCompactId);
      for (final spelling in ['Dine-In', 'DINE_IN', 'dine in', 'dinein']) {
        final t = await ReceiptTemplateStore.resolve(org, ReceiptKind.invoice,
            channel: spelling);
        expect(t.id, StarterTemplates.invoiceCompactId, reason: spelling);
      }
    });

    test('clearing a mapping returns the default', () async {
      await ReceiptTemplateStore.ensureSeeded(org);
      await ReceiptTemplateStore.setMapping(org, ReceiptKind.invoice, 'QR',
          StarterTemplates.invoiceCompactId);
      await ReceiptTemplateStore.setMapping(
          org, ReceiptKind.invoice, 'QR', null);
      final t = await ReceiptTemplateStore.resolve(org, ReceiptKind.invoice,
          channel: 'QR');
      expect(t.id, StarterTemplates.invoiceClassicId);
    });

    test('deleting a template clears what pointed at it', () async {
      await ReceiptTemplateStore.ensureSeeded(org);
      final copy = await ReceiptTemplateStore.duplicate(
          org, StarterTemplates.compactInvoice);
      await ReceiptTemplateStore.setMapping(
          org, ReceiptKind.invoice, 'Delivery', copy.id);
      await ReceiptTemplateStore.delete(org, copy.id);

      expect((await ReceiptTemplateStore.mapping(org, ReceiptKind.invoice))
          .containsValue(copy.id), isFalse);
      final t = await ReceiptTemplateStore.resolve(org, ReceiptKind.invoice,
          channel: 'Delivery');
      expect(t.id, StarterTemplates.invoiceClassicId,
          reason: 'a mapping must never point at a template that is gone');
    });

    test('a mapping cannot make an invoice print a token slip', () async {
      await ReceiptTemplateStore.ensureSeeded(org);
      await ReceiptTemplateStore.setMapping(org, ReceiptKind.invoice,
          'Dine-In', StarterTemplates.tokenLargeId);
      final t = await ReceiptTemplateStore.resolve(org, ReceiptKind.invoice,
          channel: 'Dine-In');
      expect(t.kind, ReceiptKind.invoice);
    });
  });

  group('resolve always returns something printable', () {
    test('every kind resolves on a fresh install', () async {
      for (final kind in ReceiptKind.values) {
        final t = await ReceiptTemplateStore.resolve(org, kind);
        expect(t.kind, kind);
        expect(t.blocks, isNotEmpty);
      }
    });

    test('a mapping pointing at nothing still resolves', () async {
      await ReceiptTemplateStore.ensureSeeded(org);
      await ReceiptTemplateStore.setMapping(
          org, ReceiptKind.invoice, 'Dine-In', 'tpl_that_never_existed');
      final t = await ReceiptTemplateStore.resolve(org, ReceiptKind.invoice,
          channel: 'Dine-In');
      expect(t.blocks, isNotEmpty);
    });

    test('a corrupt document is skipped, not thrown', () async {
      await ReceiptTemplateStore.ensureSeeded(org);
      final box = await Hive.openBox(ReceiptTemplateStore.boxNameFor(org));
      await box.put('tpl_broken', '{not json at all');
      await box.put('tpl_${StarterTemplates.invoiceCompactId}', 'nonsense');

      final all = await ReceiptTemplateStore.all(org);
      expect(all.any((t) => t.id == 'broken'), isFalse);
      final t = await ReceiptTemplateStore.resolve(org, ReceiptKind.invoice);
      expect(t.blocks, isNotEmpty);
    });

    test('an unknown order type resolves to the default', () async {
      final t = await ReceiptTemplateStore.resolve(org, ReceiptKind.invoice,
          channel: 'Catering');
      expect(t.id, StarterTemplates.invoiceClassicId);
    });
  });

  group('import and export', () {
    test('a round trip keeps the templates', () async {
      final source = [
        StarterTemplates.classicInvoice,
        StarterTemplates.largeToken,
      ];
      final parsed =
          ReceiptTemplateStore.parseImport(ReceiptTemplateStore.exportJson(source));
      expect(parsed.length, 2);
      expect(parsed.first.blocks.length,
          StarterTemplates.classicInvoice.blocks.length);
    });

    test('an import never overwrites what the tenant prints today', () async {
      await ReceiptTemplateStore.ensureSeeded(org);
      await ReceiptTemplateStore.save(
          org, StarterTemplates.classicInvoice.copyWith(name: 'Mine'));

      final saved = await ReceiptTemplateStore.importAll(
          org, [StarterTemplates.classicInvoice]);
      expect(saved.single.id, isNot(StarterTemplates.invoiceClassicId));

      final original = await ReceiptTemplateStore.byId(
          org, StarterTemplates.invoiceClassicId);
      expect(original!.name, 'Mine');
    });

    test('junk in the file is skipped, and never throws', () async {
      expect(ReceiptTemplateStore.parseImport('not json'), isEmpty);
      expect(ReceiptTemplateStore.parseImport('{}'), isEmpty);
      expect(ReceiptTemplateStore.parseImport('[]'), isEmpty);
      expect(
          ReceiptTemplateStore.parseImport(
              '{"templates":[{"id":"","blocks":[]},{"nope":1}]}'),
          isEmpty);
    });

    test('a bare list of templates is accepted, not only a wrapped export', () {
      final bare = jsonEncode([StarterTemplates.largeToken.toJson()]);
      final parsed = ReceiptTemplateStore.parseImport(bare);
      expect(parsed.single.id, StarterTemplates.tokenLargeId);
      expect(parsed.single.blocks.length,
          StarterTemplates.largeToken.blocks.length);
    });
  });

  group('order channels', () {
    test('every channel has a label and normalises to itself', () {
      for (final c in OrderChannel.all) {
        expect(c.label, isNotEmpty);
        expect(c.description, isNotEmpty);
        expect(OrderChannel.normalise(c.id), c.id);
        expect(OrderChannel.find(c.id), c);
      }
    });

    test('the spellings real screens actually produce all map to QR', () {
      // The order-history screen says 'QR Self-Order'; the table sheet stores
      // 'DINE_IN_QR'. Neither matched, so an owner who mapped a QR template
      // never saw it print.
      for (final spelling in [
        'QR Self-Order',
        'qr self order',
        'QR_MENU',
        'DINE_IN_QR',
        'Self Order',
      ]) {
        expect(OrderChannel.normalise(spelling), OrderChannel.qr.id,
            reason: spelling);
      }
    });

    test('an empty order type is treated as dine-in', () {
      expect(OrderChannel.normalise(''), OrderChannel.dineIn.id);
    });

    test('something we do not know is left alone rather than guessed', () {
      expect(OrderChannel.normalise('Catering'), 'Catering');
      expect(OrderChannel.find('Catering'), isNull);
    });
  });
}
