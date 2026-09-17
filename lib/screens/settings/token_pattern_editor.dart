/// The owner designs their token number here.
///
/// Self-contained on purpose: the Receipts & Slips screen (R4) embeds it, and
/// so can the printer settings screen, without either of them knowing how a
/// token is stored. It shows the result before it is saved, because a format
/// you cannot see is a format you find out about from a customer.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/classic_theme.dart';
import '../../core/design_tokens.dart';
import '../../core/token_pattern.dart';
import '../../providers/daily_token_provider.dart';

class TokenPatternEditor extends ConsumerStatefulWidget {
  /// Scopes the series. Pass the resolved outlet id.
  final String orgId;

  /// Called after a successful save, so the host screen can show its own
  /// confirmation.
  final VoidCallback? onSaved;

  const TokenPatternEditor({super.key, required this.orgId, this.onSaved});

  @override
  ConsumerState<TokenPatternEditor> createState() => _TokenPatternEditorState();
}

class _TokenPatternEditorState extends ConsumerState<TokenPatternEditor> {
  final TextEditingController _pattern = TextEditingController();
  final TextEditingController _prefix = TextEditingController();
  final TextEditingController _counter = TextEditingController();
  final TextEditingController _start = TextEditingController();
  final TextEditingController _max = TextEditingController();

  TokenResetRule _rule = TokenResetRule.daily;
  bool _loading = true;
  bool _saving = false;
  String _nextToken = '';

  /// The counter code as it was saved. Changing it starts a new series, so the
  /// owner is told before they save rather than finding out from the slips.
  String _savedCounter = '';

  bool get _counterChanged => _counter.text.trim() != _savedCounter.trim();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pattern.dispose();
    _prefix.dispose();
    _counter.dispose();
    _start.dispose();
    _max.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final notifier = ref.read(dailyTokenProvider.notifier);
    final cfg = await notifier.loadConfig(widget.orgId);
    final next = await notifier.peekNextToken(orgId: widget.orgId);
    if (!mounted) return;
    setState(() {
      _pattern.text = cfg.pattern;
      _prefix.text = cfg.prefix;
      _counter.text = cfg.counterCode;
      _savedCounter = cfg.counterCode;
      _start.text = cfg.start.toString();
      _max.text = cfg.max == 0 ? '' : cfg.max.toString();
      _rule = cfg.resetRule;
      _nextToken = next;
      _loading = false;
    });
  }

  TokenSeriesConfig get _draft => TokenSeriesConfig(
        pattern: _pattern.text,
        resetRule: _rule,
        start: int.tryParse(_start.text.trim()) ?? 1,
        max: int.tryParse(_max.text.trim()) ?? 0,
        counterCode: _counter.text.trim(),
        prefix: _prefix.text.trim(),
      );

  Future<void> _save() async {
    final cfg = _draft;
    if (!TokenPattern.isSafe(cfg)) return;
    setState(() => _saving = true);
    await ref.read(dailyTokenProvider.notifier).saveConfig(widget.orgId, cfg);
    final next =
        await ref.read(dailyTokenProvider.notifier).peekNextToken(orgId: widget.orgId);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _nextToken = next;
      _savedCounter = cfg.counterCode;
    });
    widget.onSaved?.call();
  }

  void _insert(String slotName) {
    final slot = slotName == 'seq' ? '{seq:3}' : '{$slotName}';
    final sel = _pattern.selection;
    final text = _pattern.text;
    final at = (sel.start >= 0 && sel.start <= text.length) ? sel.start : text.length;
    final updated = text.replaceRange(at, at, slot);
    _pattern.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: at + slot.length),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(DS.space5),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    final cfg = _draft;
    final issues = TokenPattern.validate(cfg);
    final safe = TokenPattern.isSafe(cfg);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Token number',
            style: TextStyle(
                fontSize: DS.fontHeadline,
                fontWeight: FontWeight.w800,
                color: context.textPrimary)),
        const SizedBox(height: 2),
        Text(
          'The number you call out and print on the slip. Change the shape '
          'here; the counter keeps running.',
          style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary),
        ),
        const SizedBox(height: DS.space4),

        _preview(context, cfg),
        const SizedBox(height: DS.space4),

        _field(context, 'Pattern', _pattern, hint: TokenSeriesConfig.defaultPattern),
        const SizedBox(height: DS.space2),
        Wrap(
          spacing: DS.space2,
          runSpacing: DS.space2,
          children: [
            for (final slot in TokenPattern.slots)
              Tooltip(
                message: slot.hint,
                child: ActionChip(
                  label: Text(slot.label,
                      style: const TextStyle(
                          fontSize: DS.fontMicro, fontWeight: FontWeight.w700)),
                  onPressed: () => _insert(slot.name),
                ),
              ),
          ],
        ),

        const SizedBox(height: DS.space4),
        Row(
          children: [
            Expanded(
                child: _field(context, 'Store prefix', _prefix,
                    hint: 'T', caption: 'Fills {prefix}')),
            const SizedBox(width: DS.space3),
            Expanded(
              child: _field(context, 'Counter code', _counter,
                  hint: 'A',
                  caption: 'This till only. Give each till its own.',
                  maxLength: 3),
            ),
          ],
        ),

        const SizedBox(height: DS.space4),
        Text('Start again',
            style: TextStyle(
                fontSize: DS.fontBody,
                fontWeight: FontWeight.w700,
                color: context.textPrimary)),
        const SizedBox(height: DS.space2),
        // Flutter 3.32+: a RadioGroup ancestor owns groupValue/onChanged for
        // every radio beneath it; the per-radio properties are deprecated.
        RadioGroup<TokenResetRule>(
          groupValue: _rule,
          onChanged: (v) => setState(() => _rule = v ?? _rule),
          child: Column(
            children: [
              for (final rule in TokenResetRule.values)
                RadioListTile<TokenResetRule>(
                  value: rule,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(rule.label,
                      style: TextStyle(
                          fontSize: DS.fontBody,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary)),
                  subtitle: Text(rule.explanation,
                      style: TextStyle(
                          fontSize: DS.fontMicro, color: context.textSecondary)),
                ),
            ],
          ),
        ),

        const SizedBox(height: DS.space3),
        Row(
          children: [
            Expanded(
                child: _field(context, 'First number', _start,
                    hint: '1', numeric: true)),
            const SizedBox(width: DS.space3),
            Expanded(
                child: _field(context, 'Highest number', _max,
                    hint: 'no limit',
                    caption: 'Wraps back to the first',
                    numeric: true)),
          ],
        ),

        if (issues.isNotEmpty) ...[
          const SizedBox(height: DS.space3),
          _issues(context, issues, safe),
        ],

        const SizedBox(height: DS.space4),
        SizedBox(
          width: double.infinity,
          height: DS.tapTargetComfortable,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: ClassicTheme.primaryAccent,
              foregroundColor: Colors.white,
              disabledBackgroundColor: context.borderColor,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(DS.radiusMd)),
            ),
            onPressed: (!safe || _saving) ? null : _save,
            child: Text(_saving ? 'Saving\u2026' : 'Save token format',
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(height: DS.space2),
        Text(
          _counterChanged
              ? 'This till\u2019s counter code has changed, so saving starts a '
                  'new series from the first number.'
              : 'Saving does not restart the counter \u2014 the next order '
                  'continues the series in the new shape.',
          style: TextStyle(
              fontSize: DS.fontMicro,
              color: _counterChanged
                  ? ClassicTheme.warningAmber
                  : context.textMuted),
        ),
      ],
    );
  }

  Widget _preview(BuildContext context, TokenSeriesConfig cfg) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(DS.space4),
        decoration: BoxDecoration(
          color: context.sunkenSurface,
          borderRadius: BorderRadius.circular(DS.radiusMd),
          border: Border.all(color: context.borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('LOOKS LIKE',
                style: TextStyle(
                    fontSize: DS.fontMicro,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700,
                    color: context.textSecondary)),
            const SizedBox(height: DS.space2),
            Text(
              TokenPattern.example(cfg),
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w900,
                fontFamily: 'monospace',
                color: context.textPrimary,
              ),
            ),
            if (_nextToken.isNotEmpty) ...[
              const SizedBox(height: DS.space2),
              Text('Next order on this till: $_nextToken',
                  style: TextStyle(
                      fontSize: DS.fontCaption, color: context.textSecondary)),
            ],
          ],
        ),
      );

  Widget _issues(BuildContext context, List<String> issues, bool safe) {
    final colour = safe ? ClassicTheme.warningAmber : ClassicTheme.dangerRed;
    return Container(
      padding: const EdgeInsets.all(DS.space3),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(DS.radiusMd),
        border: Border.all(color: colour.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(safe ? Icons.info_outline_rounded : Icons.error_outline_rounded,
                  size: 16, color: colour),
              const SizedBox(width: DS.space2),
              Text(safe ? 'Worth knowing' : 'Cannot save this yet',
                  style: TextStyle(
                      fontSize: DS.fontCaption,
                      fontWeight: FontWeight.w700,
                      color: colour)),
            ],
          ),
          const SizedBox(height: DS.space2),
          for (final issue in issues)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('\u2022 $issue',
                  style: TextStyle(
                      fontSize: DS.fontMicro,
                      height: 1.45,
                      color: context.textSecondary)),
            ),
        ],
      ),
    );
  }

  Widget _field(
    BuildContext context,
    String label,
    TextEditingController controller, {
    String? hint,
    String? caption,
    bool numeric = false,
    int? maxLength,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            onChanged: (_) => setState(() {}),
            keyboardType: numeric ? TextInputType.number : TextInputType.text,
            inputFormatters:
                numeric ? [FilteringTextInputFormatter.digitsOnly] : null,
            maxLength: maxLength,
            style: TextStyle(
                color: context.textPrimary,
                fontSize: DS.fontBody,
                fontFamily: numeric ? null : 'monospace'),
            decoration: InputDecoration(
              labelText: label,
              labelStyle: TextStyle(color: context.textSecondary),
              hintText: hint,
              hintStyle:
                  TextStyle(color: context.textMuted, fontSize: DS.fontCaption),
              counterText: '',
              filled: true,
              fillColor: context.inputFill,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(DS.radiusMd),
                borderSide: BorderSide(color: context.borderColor),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(DS.radiusMd),
                borderSide: BorderSide(color: context.borderColor),
              ),
            ),
          ),
          if (caption != null) ...[
            const SizedBox(height: 4),
            Text(caption,
                style:
                    TextStyle(fontSize: DS.fontMicro, color: context.textMuted)),
          ],
        ],
      );
}
