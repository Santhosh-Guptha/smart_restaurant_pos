/// The block editor: the paper on one side, the parts of it on the other.
///
/// Every change re-renders the preview against a sample order, so the owner
/// sees the slip rather than a form. Nothing is written until they save, and
/// a template that would print nothing useful cannot be saved at all.
library;

import 'dart:convert';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/classic_theme.dart';
import '../../core/design_tokens.dart';
import '../../core/receipt/escpos_encoder.dart';
import '../../core/receipt/receipt_condition.dart';
import '../../core/receipt/receipt_context.dart';
import '../../core/receipt/receipt_layout.dart';
import '../../core/receipt/receipt_preview.dart';
import '../../core/receipt/receipt_renderer.dart';
import '../../core/receipt/receipt_store.dart';
import '../../core/receipt/receipt_template.dart';
import '../../core/responsive.dart';
import '../../services/thermal_printer_service.dart';
import '../../utils/ui_feedback.dart';

class ReceiptTemplateEditorScreen extends ConsumerStatefulWidget {
  final String orgId;
  final ReceiptTemplate template;

  const ReceiptTemplateEditorScreen({
    super.key,
    required this.orgId,
    required this.template,
  });

  @override
  ConsumerState<ReceiptTemplateEditorScreen> createState() =>
      _ReceiptTemplateEditorScreenState();
}

class _ReceiptTemplateEditorScreenState
    extends ConsumerState<ReceiptTemplateEditorScreen> {
  late List<ReceiptBlock> _blocks;

  /// Stable identity per block, so reordering moves a tile instead of
  /// rebuilding every one of them. The blocks themselves cannot be their own
  /// keys: two default dividers are the same canonicalised const object.
  late List<String> _ids;
  var _nextId = 0;

  late String _name;
  late String _paper;
  bool _dirty = false;
  bool _printing = false;

  final ReceiptContext _sample = ReceiptContext.sample();

  /// Recomputed only when something changes, not on every frame.
  ReceiptLayout? _cachedLayout;
  List<String> _cachedProblems = const [];

  @override
  void initState() {
    super.initState();
    _blocks = List<ReceiptBlock>.from(widget.template.blocks);
    _ids = [for (final _ in _blocks) 'b${_nextId++}'];
    _name = widget.template.name;
    _paper = widget.template.paper;
    _recompute();
  }

  /// Changing anything marks the template dirty and re-renders the paper.
  void _changed(VoidCallback mutate) {
    setState(() {
      mutate();
      _dirty = true;
      _recompute();
    });
  }

  void _recompute() {
    final layout =
        ReceiptRenderer.layout(_draft, _sample, paperChars: _paperChars);
    final problems = <String>[...layout.warnings];
    for (final b in _blocks) {
      if (b.when.trim().isEmpty) continue;
      final r = ReceiptCondition.validate(b.when);
      if (!r.ok) problems.add('"${b.when}" \u2014 ${r.error}');
    }
    if (_blocks.isEmpty) {
      problems.add('This slip has no parts, so it prints nothing.');
    }
    _cachedLayout = layout;
    _cachedProblems = problems;
  }

  /// `updatedAt` is stamped by `copyWith`, once, at save time — not on
  /// every read, which would make an untouched slip look freshly edited.
  ReceiptTemplate get _draft => ReceiptTemplate(
        id: widget.template.id,
        name: _name,
        kind: widget.template.kind,
        blocks: _blocks,
        paper: _paper,
        version: widget.template.version,
        updatedAt: widget.template.updatedAt,
      );

  int get _paperChars {
    if (_paper == '80') return Paper.mm80;
    if (_paper == '58') return Paper.mm58;
    // 'auto' follows the connected printer, so the preview should too.
    return ref.read(thermalPrinterProvider).paperSize == '80mm'
        ? Paper.mm80
        : Paper.mm58;
  }

  ReceiptLayout get _layout =>
      _cachedLayout ??
      ReceiptRenderer.layout(_draft, _sample, paperChars: _paperChars);

  List<String> get _problems => _cachedProblems;

  bool get _canSave => _blocks.isNotEmpty && _name.trim().isNotEmpty;

  Future<void> _save() async {
    if (!_canSave) return;
    await ReceiptTemplateStore.save(
        widget.orgId, _draft.copyWith(blocks: _blocks));
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  /// Leaving with unsaved edits asks first. A block editor is too much work to
  /// lose to a back swipe.
  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave without saving?'),
        content: const Text('The changes you made to this slip will be lost.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep editing')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Discard', style: TextStyle(color: ctx.dangerColor)),
          ),
        ],
      ),
    );
    return leave == true;
  }

  Future<void> _testPrint() async {
    final printer = ref.read(thermalPrinterProvider);
    if (!printer.isConnected) {
      AppToast.showError(context, 'No printer is connected',
          title: 'Connect a printer first');
      return;
    }
    setState(() => _printing = true);
    try {
      final wide = printer.paperSize == '80mm';
      final bytes = EscPosEncoder.encode(
        ReceiptRenderer.layout(_draft, _sample,
            paperChars: wide ? Paper.mm80 : Paper.mm58),
        paperSize: wide ? PaperSize.mm80 : PaperSize.mm58,
        profile: await CapabilityProfile.load(),
      );
      if (!mounted) return;
      await ref.read(thermalPrinterProvider.notifier).printBytes(bytes);
      if (mounted) AppToast.showSuccess(context, 'Sent to the printer');
    } catch (e) {
      if (mounted) AppToast.showError(context, e, title: 'Could not test print');
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  Future<void> _edit(int index) async {
    final updated = await showModalBottomSheet<ReceiptBlock>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          _BlockSheet(block: _blocks[index], kind: widget.template.kind),
    );
    if (updated == null || !mounted) return;
    _changed(() => _blocks[index] = updated);
  }

  Future<void> _add() async {
    final type = await showModalBottomSheet<BlockType>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const _BlockTypeSheet(),
    );
    if (type == null || !mounted) return;

    final block = await showModalBottomSheet<ReceiptBlock>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          _BlockSheet(block: _starterFor(type), kind: widget.template.kind),
    );
    // Cancelling the settings sheet adds nothing, rather than leaving an
    // unwanted default block behind.
    if (block == null || !mounted) return;
    _changed(() {
      _blocks.add(block);
      _ids.add('b${_nextId++}');
    });
  }

  static ReceiptBlock _starterFor(BlockType type) {
    switch (type) {
      case BlockType.text:
        return const ReceiptBlock(
            type: BlockType.text, props: {'value': 'Your text here'});
      case BlockType.field:
        return const ReceiptBlock(type: BlockType.field, props: {
          'label': 'Table',
          'value': '{{order.table}}',
        });
      case BlockType.columns:
        return const ReceiptBlock(type: BlockType.columns, props: {
          'cells': [
            {'value': '{{order.id}}', 'width': 6},
            {'value': '{{order.token}}', 'width': 6, 'align': 'right'},
          ],
        });
      case BlockType.divider:
        return const ReceiptBlock(type: BlockType.divider, props: {'char': '-'});
      case BlockType.spacer:
        return const ReceiptBlock(type: BlockType.spacer, props: {'lines': 1});
      case BlockType.items:
        return const ReceiptBlock(type: BlockType.items, props: {
          'columns': ['name', 'qty', 'amount'],
        });
      case BlockType.totals:
        return const ReceiptBlock(type: BlockType.totals, props: {
          'rows': ['subtotal', 'discount', 'grandTotal'],
        });
      case BlockType.qr:
        return const ReceiptBlock(
            type: BlockType.qr, props: {'value': '{{payment.upiUri}}'});
      case BlockType.barcode:
        return const ReceiptBlock(
            type: BlockType.barcode, props: {'value': '{{order.id}}'});
      default:
        return ReceiptBlock(type: type);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = Responsive.isTablet(context);
    final problems = _problems;

    final preview = SingleChildScrollView(
      padding: const EdgeInsets.all(DS.space4),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: ReceiptPreview(layout: _layout),
        ),
      ),
    );

    final parts = ListView(
      padding: const EdgeInsets.fromLTRB(DS.space4, DS.space4, DS.space4, DS.space6),
      children: [
        _header(context),
        if (problems.isNotEmpty) ...[
          const SizedBox(height: DS.space3),
          _problemsCard(context, problems),
        ],
        const SizedBox(height: DS.space4),
        Text('Parts of this slip, top to bottom',
            style: TextStyle(
                fontSize: DS.fontCaption, color: context.textSecondary)),
        const SizedBox(height: DS.space2),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          // ignore: deprecated_member_use
          onReorder: (from, to) {
            _changed(() {
              final target = to > from ? to - 1 : to;
              _blocks.insert(target, _blocks.removeAt(from));
              _ids.insert(target, _ids.removeAt(from));
            });
          },
          children: [
            for (var i = 0; i < _blocks.length; i++)
              _blockTile(context, i, _blocks[i]),
          ],
        ),
        const SizedBox(height: DS.space3),
        OutlinedButton.icon(
          onPressed: _add,
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('Add a part'),
        ),
      ],
    );

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await _confirmDiscard();
        if (!leave || !context.mounted) return;
        Navigator.of(context).pop(false);
      },
      child: Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        title: Text(_name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Test print',
            onPressed: _printing ? null : _testPrint,
            icon: const Icon(Icons.print_rounded),
          ),
          TextButton(
            onPressed: !_dirty
                ? () => Navigator.of(context).pop(false)
                : (_canSave ? _save : null),
            child: Text(_dirty ? 'Save' : 'Done',
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      body: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 3, child: parts),
                VerticalDivider(width: 1, color: context.borderColor),
                Expanded(flex: 2, child: preview),
              ],
            )
          : Column(
              children: [
                SizedBox(height: 260, child: preview),
                Divider(height: 1, color: context.borderColor),
                Expanded(child: parts),
              ],
            ),
      ),
    );
  }

  Widget _header(BuildContext context) => Row(
        children: [
          Expanded(
            child: TextFormField(
              initialValue: _name,
              onChanged: (v) => _changed(() => _name = v),
              decoration: const InputDecoration(
                  labelText: 'Name', isDense: true),
            ),
          ),
          const SizedBox(width: DS.space3),
          DropdownButton<String>(
            value: _paper,
            onChanged: (v) => _changed(() => _paper = v ?? 'auto'),
            items: const [
              DropdownMenuItem(value: 'auto', child: Text('Printer decides')),
              DropdownMenuItem(value: '58', child: Text('58 mm')),
              DropdownMenuItem(value: '80', child: Text('80 mm')),
            ],
          ),
        ],
      );

  Widget _problemsCard(BuildContext context, List<String> problems) => Container(
        padding: const EdgeInsets.all(DS.space3),
        decoration: BoxDecoration(
          color: context.warningColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(DS.radiusMd),
          border: Border.all(color: context.warningColor.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline_rounded,
                    size: 16, color: context.warningColor),
                const SizedBox(width: DS.space2),
                Text('Worth a look',
                    style: TextStyle(
                        fontSize: DS.fontCaption,
                        fontWeight: FontWeight.w700,
                        color: context.warningColor)),
              ],
            ),
            const SizedBox(height: DS.space2),
            for (final p in problems)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text('\u2022 $p',
                    style: TextStyle(
                        fontSize: DS.fontMicro,
                        height: 1.45,
                        color: context.textSecondary)),
              ),
          ],
        ),
      );

  Widget _blockTile(BuildContext context, int index, ReceiptBlock b) {
    return Container(
      key: ValueKey(_ids[index]),
      margin: const EdgeInsets.only(bottom: DS.space2),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(DS.radiusMd),
        border: Border.all(color: context.borderColor),
      ),
      child: ListTile(
        dense: true,
        onTap: () => _edit(index),
        leading: ReorderableDragStartListener(
          index: index,
          child: Icon(Icons.drag_indicator_rounded,
              size: 20, color: context.textMuted),
        ),
        title: Text(_blockLabel(b.type),
            style: TextStyle(
                fontSize: DS.fontBody,
                fontWeight: FontWeight.w600,
                color: context.textPrimary)),
        subtitle: Text(_blockSummary(b),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
        trailing: IconButton(
          tooltip: 'Remove',
          icon: Icon(Icons.close_rounded, size: 18, color: context.textMuted),
          onPressed: () => _changed(() {
            _blocks.removeAt(index);
            _ids.removeAt(index);
          }),
        ),
      ),
    );
  }

  static String _blockLabel(BlockType type) {
    switch (type) {
      case BlockType.text:
        return 'Text';
      case BlockType.field:
        return 'Label and value';
      case BlockType.columns:
        return 'Row of columns';
      case BlockType.items:
        return 'The items';
      case BlockType.totals:
        return 'Totals';
      case BlockType.payments:
        return 'Split payments';
      case BlockType.divider:
        return 'Line across';
      case BlockType.spacer:
        return 'Blank space';
      case BlockType.logo:
        return 'Logo';
      case BlockType.qr:
        return 'QR code';
      case BlockType.barcode:
        return 'Barcode';
      case BlockType.cut:
        return 'Cut the paper';
      case BlockType.raw:
        return 'Printer command';
    }
  }

  static String _blockSummary(ReceiptBlock b) {
    final when = b.when.trim().isEmpty ? '' : '  \u00b7  only if ${b.when}';
    switch (b.type) {
      case BlockType.text:
      case BlockType.qr:
      case BlockType.barcode:
        return '${b.value}$when';
      case BlockType.field:
        return '${b.label}: ${b.value}$when';
      case BlockType.columns:
        return '${b.columns.map((c) => c.value).join('   ')}$when';
      case BlockType.totals:
        return '${b.rows.isEmpty ? 'the usual rows' : b.rows.join(', ')}$when';
      case BlockType.items:
        return '${((b.props['columns'] as List?) ?? const []).join(', ')}$when';
      case BlockType.divider:
        return '${b.props['char'] ?? '-'}$when';
      case BlockType.spacer:
        return '${b.props['lines'] ?? 1} line(s)$when';
      default:
        return when.trim().isEmpty ? '\u2014' : when.trim();
    }
  }
}

/// The "+ part" picker.
class _BlockTypeSheet extends StatelessWidget {
  const _BlockTypeSheet();

  static const List<BlockType> _offered = [
    BlockType.text,
    BlockType.field,
    BlockType.columns,
    BlockType.items,
    BlockType.totals,
    BlockType.payments,
    BlockType.divider,
    BlockType.spacer,
    BlockType.qr,
    BlockType.barcode,
    BlockType.cut,
  ];

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(DS.radiusXl)),
        ),
        child: SafeArea(
          top: false,
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: DS.space3),
            children: [
              for (final t in _offered)
                ListTile(
                  dense: true,
                  title: Text(
                      _ReceiptTemplateEditorScreenState._blockLabel(t),
                      style: TextStyle(
                          fontSize: DS.fontBody, color: context.textPrimary)),
                  onTap: () => Navigator.pop(context, t),
                ),
            ],
          ),
        ),
      );
}

/// Editing one part.
class _BlockSheet extends StatefulWidget {
  final ReceiptBlock block;
  final ReceiptKind kind;

  const _BlockSheet({required this.block, required this.kind});

  @override
  State<_BlockSheet> createState() => _BlockSheetState();
}

class _BlockSheetState extends State<_BlockSheet> {
  late Map<String, dynamic> _props;
  late BlockStyle _style;
  late TextEditingController _when;
  late TextEditingController _raw;
  bool _showRaw = false;

  @override
  void initState() {
    super.initState();
    _props = Map<String, dynamic>.from(widget.block.props);
    _style = widget.block.style;
    _when = TextEditingController(text: widget.block.when);
    _raw = TextEditingController(
        text: const JsonEncoder.withIndent('  ').convert(_props));
  }

  @override
  void dispose() {
    _when.dispose();
    _raw.dispose();
    super.dispose();
  }

  void _commit() {
    var props = _props;
    if (_showRaw) {
      try {
        final decoded = jsonDecode(_raw.text);
        if (decoded is Map) props = Map<String, dynamic>.from(decoded);
      } catch (_) {
        AppToast.showError(context, 'That is not valid JSON',
            title: 'Settings not saved');
        return;
      }
    }
    Navigator.pop(
      context,
      ReceiptBlock(
        type: widget.block.type,
        style: _style,
        when: _when.text.trim(),
        props: props,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.block.type;
    final maxH = MediaQuery.of(context).size.height * 0.88;

    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(DS.radiusXl)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  DS.space4, DS.space4, DS.space2, DS.space2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                        _ReceiptTemplateEditorScreenState._blockLabel(
                            widget.block.type),
                        style: TextStyle(
                            fontSize: DS.fontHeadline,
                            fontWeight: FontWeight.w800,
                            color: context.textPrimary)),
                  ),
                  IconButton(
                    tooltip: _showRaw ? 'Back to the simple view' : 'Advanced',
                    // Carry the edits across. Without this, switching view
                    // showed stale content and the save took whichever side
                    // happened to be visible — quietly throwing the other
                    // away.
                    onPressed: () => setState(() {
                      if (_showRaw) {
                        try {
                          final decoded = jsonDecode(_raw.text);
                          if (decoded is Map) {
                            _props = Map<String, dynamic>.from(decoded);
                          }
                        } catch (_) {
                          // Unreadable JSON: keep the simple view's props
                          // rather than losing them to a typo.
                        }
                      } else {
                        _raw.text = const JsonEncoder.withIndent('  ')
                            .convert(_props);
                      }
                      _showRaw = !_showRaw;
                    }),
                    icon: Icon(_showRaw
                        ? Icons.view_agenda_outlined
                        : Icons.code_rounded),
                  ),
                  IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded)),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: DS.space4),
                child: _showRaw ? _rawEditor(context) : _simpleEditor(context, t),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(DS.space4),
              child: SizedBox(
                width: double.infinity,
                height: DS.tapTargetComfortable,
                child: ElevatedButton(
                  onPressed: _commit,
                  child: const Text('Done',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rawEditor(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Every setting for this part, as it is stored. Useful when the '
            'simple view does not offer what you want.',
            style:
                TextStyle(fontSize: DS.fontMicro, color: context.textSecondary),
          ),
          const SizedBox(height: DS.space3),
          TextField(
            controller: _raw,
            maxLines: 14,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: DS.space3),
          _whenField(context),
        ],
      );

  Widget _simpleEditor(BuildContext context, BlockType t) {
    final children = <Widget>[];

    void textProp(String key, String label, {String? hint, int lines = 1}) {
      children.add(Padding(
        padding: const EdgeInsets.only(bottom: DS.space3),
        child: TextFormField(
          initialValue: (_props[key] ?? '').toString(),
          maxLines: lines,
          onChanged: (v) => setState(() => _props[key] = v),
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: InputDecoration(
              labelText: label, hintText: hint, isDense: true),
        ),
      ));
    }

    void numberProp(String key, String label, int fallback) {
      children.add(Padding(
        padding: const EdgeInsets.only(bottom: DS.space3),
        child: TextFormField(
          initialValue: '${_props[key] ?? fallback}',
          keyboardType: TextInputType.number,
          onChanged: (v) =>
              setState(() => _props[key] = int.tryParse(v) ?? fallback),
          decoration: InputDecoration(labelText: label, isDense: true),
        ),
      ));
    }

    void toggle(String key, String label, {bool fallback = false}) {
      children.add(SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: _props[key] == null ? fallback : _props[key] == true,
        onChanged: (v) => setState(() => _props[key] = v),
        title: Text(label,
            style:
                TextStyle(fontSize: DS.fontBody, color: context.textPrimary)),
      ));
    }

    void chips(String key, List<String> options, List<String> fallback) {
      final current = ((_props[key] as List?) ?? fallback)
          .map((e) => e.toString())
          .toList();
      children.add(Padding(
        padding: const EdgeInsets.only(bottom: DS.space3),
        child: Wrap(
          spacing: DS.space2,
          runSpacing: DS.space2,
          children: [
            for (final o in options)
              FilterChip(
                label: Text(o, style: const TextStyle(fontSize: DS.fontMicro)),
                selected: current.contains(o),
                onSelected: (on) => setState(() {
                  final next = [...current];
                  if (on) {
                    if (!next.contains(o)) next.add(o);
                  } else {
                    next.remove(o);
                  }
                  _props[key] = next;
                }),
              ),
          ],
        ),
      ));
    }

    switch (t) {
      case BlockType.text:
        textProp('value', 'Text', hint: 'Use {{store.name}} for a value', lines: 3);
        break;
      case BlockType.field:
        textProp('label', 'Label');
        textProp('value', 'Value', hint: '{{order.table}}');
        break;
      case BlockType.qr:
      case BlockType.barcode:
        textProp('value', 'What it encodes', hint: '{{payment.upiUri}}');
        break;
      case BlockType.divider:
        textProp('char', 'Character', hint: '-  =  *');
        break;
      case BlockType.spacer:
        numberProp('lines', 'Blank lines', 1);
        break;
      case BlockType.items:
        chips('columns', const ['name', 'qty', 'rate', 'amount', 'notes', 'station', 'veg'],
            const ['name', 'qty', 'amount']);
        toggle('header', 'Column headings', fallback: true);
        toggle('showNotes', 'Show item notes');
        if (widget.kind == ReceiptKind.kot) {
          toggle('groupByStation', 'Group by kitchen station');
        }
        break;
      case BlockType.totals:
        chips(
            'rows',
            const [
              'subtotal', 'discount', 'serviceCharge', 'cgst', 'sgst',
              'roundOff', 'grandTotal', 'paid', 'change', 'balance',
            ],
            const ['subtotal', 'grandTotal']);
        break;
      case BlockType.columns:
        children.add(Text(
          'Columns are edited in the advanced view for now \u2014 tap the code '
          'icon above.',
          style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary),
        ));
        break;
      default:
        children.add(Text('Nothing to set on this part.',
            style: TextStyle(
                fontSize: DS.fontMicro, color: context.textSecondary)));
    }

    children.add(const SizedBox(height: DS.space2));
    children.add(_styleRow(context));
    children.add(const SizedBox(height: DS.space3));
    children.add(_whenField(context));

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  Widget _styleRow(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('How it looks',
              style: TextStyle(
                  fontSize: DS.fontCaption,
                  fontWeight: FontWeight.w700,
                  color: context.textPrimary)),
          const SizedBox(height: DS.space2),
          Wrap(
            spacing: DS.space2,
            runSpacing: DS.space2,
            children: [
              for (final a in TextAlign_.values)
                ChoiceChip(
                  label: Text(a.name, style: const TextStyle(fontSize: DS.fontMicro)),
                  selected: _style.align == a,
                  onSelected: (_) => setState(() => _style = _style.copyWith(align: a)),
                ),
              for (final s in TextSize.values)
                ChoiceChip(
                  label: Text(s.name.toUpperCase(),
                      style: const TextStyle(fontSize: DS.fontMicro)),
                  selected: _style.size == s,
                  onSelected: (_) => setState(() => _style = _style.copyWith(size: s)),
                ),
              FilterChip(
                label: const Text('Bold', style: TextStyle(fontSize: DS.fontMicro)),
                selected: _style.bold,
                onSelected: (v) => setState(() => _style = _style.copyWith(bold: v)),
              ),
              FilterChip(
                label:
                    const Text('Underline', style: TextStyle(fontSize: DS.fontMicro)),
                selected: _style.underline,
                onSelected: (v) =>
                    setState(() => _style = _style.copyWith(underline: v)),
              ),
            ],
          ),
        ],
      );

  Widget _whenField(BuildContext context) {
    final expr = _when.text.trim();
    final result = expr.isEmpty ? null : ReceiptCondition.validate(expr);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _when,
          onChanged: (_) => setState(() {}),
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: const InputDecoration(
            labelText: 'Only print this part when\u2026 (optional)',
            hintText: 'bill.discount > 0',
            isDense: true,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          result == null
              ? 'Leave empty and it always prints.'
              : result.ok
                  ? 'Reads fine.'
                  : result.error!,
          style: TextStyle(
            fontSize: DS.fontMicro,
            color: result == null || result.ok
                ? context.textMuted
                : context.dangerColor,
          ),
        ),
        const SizedBox(height: DS.space2),
      ],
    );
  }
}
