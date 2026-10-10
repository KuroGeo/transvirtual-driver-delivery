import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/delivery.dart';
import '../../core/brand_theme.dart';

typedef FailureSubmit =
    Future<bool> Function({required String reason, String? note});

class FailureSubmission {
  const FailureSubmission({required this.reason, this.note});

  final String reason;
  final String? note;
}

/// Presents only the form route. A successful return leaves detail navigation
/// to its owner; false/error preserves this route's selection and draft.
Future<FailureSubmission?> showDeliveryFailureSheet(
  BuildContext context, {
  required Stop stop,
  required FailureSubmit onSubmit,
}) => showModalBottomSheet<FailureSubmission>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  isDismissible: true,
  enableDrag: false,
  backgroundColor: Colors.transparent,
  sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : const AnimationStyle(
          duration: Duration(milliseconds: 190),
          reverseDuration: Duration(milliseconds: 160),
        ),
  builder: (context) => DeliveryFailureSheet(stop: stop, onSubmit: onSubmit),
);

class DeliveryFailureSheet extends StatefulWidget {
  const DeliveryFailureSheet({
    super.key,
    required this.stop,
    required this.onSubmit,
  });

  final Stop stop;
  final FailureSubmit onSubmit;

  @override
  State<DeliveryFailureSheet> createState() => _DeliveryFailureSheetState();
}

class _DeliveryFailureSheetState extends State<DeliveryFailureSheet> {
  static const _reasons = [
    ('Recipient unavailable', 'recipient-unavailable'),
    ('Business closed', 'business-closed'),
    ('Address not found', 'address-not-found'),
    ('Other', 'other'),
  ];

  final _note = TextEditingController();
  String? _reason;
  String? _validationError;
  String? _saveError;
  bool _saving = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _close() {
    if (!_saving) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _save() async {
    if (_saving || widget.stop.status != DeliveryStatus.pending) return;
    final chosen = _reason;
    final text = _note.text.trim();
    if (chosen == null || (chosen == 'Other' && text.isEmpty)) {
      setState(() {
        _validationError = chosen == 'Other'
            ? 'Enter a reason to continue.'
            : 'Choose a reason to continue.';
      });
      return;
    }
    final submission = FailureSubmission(
      reason: chosen == 'Other' ? text : chosen,
      note: chosen == 'Other' || text.isEmpty ? null : text,
    );
    setState(() {
      _saving = true;
      _validationError = null;
      _saveError = null;
    });
    var saved = false;
    try {
      saved = await widget.onSubmit(
        reason: submission.reason,
        note: submission.note,
      );
    } catch (_) {
      // A caller may throw instead of returning false. Keep the same draft.
    }
    if (!mounted) return;
    if (saved) {
      Navigator.of(context).pop(submission);
    } else {
      setState(() {
        _saving = false;
        _saveError =
            'Could not save. Your choices and note are kept. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<FailureSubmission>(
    canPop: !_saving,
    child: Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              _close();
              return null;
            },
          ),
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final inset = MediaQuery.viewInsetsOf(context).bottom;
            final available = constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : MediaQuery.sizeOf(context).height;
            // Retain a visible scrim even when enlarged text makes the form
            // taller than the screen; its contents scroll above the keyboard.
            final height = ((available - inset) * 0.92)
                .clamp(0.0, available)
                .toDouble();
            return Padding(
              padding: EdgeInsets.only(bottom: inset),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: height),
                child: Material(
                  key: const ValueKey('failure-sheet'),
                  color: OceanColors.cream,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(24),
                    ),
                    side: BorderSide(color: OceanColors.border),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: SafeArea(
                    top: false,
                    child: SingleChildScrollView(
                      key: const ValueKey('failure-scroll'),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: Container(
                              width: 32,
                              height: 4,
                              decoration: BoxDecoration(
                                color: OceanColors.border,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Report failed delivery',
                                  style: Theme.of(context).textTheme.titleLarge
                                      ?.copyWith(
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: -0.5,
                                      ),
                                ),
                              ),
                              IconButton(
                                key: const ValueKey('failure-close'),
                                tooltip: 'Close failure form',
                                onPressed: _saving ? null : _close,
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                          Text(
                            '${widget.stop.customerName} · ${widget.stop.reference}',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: OceanColors.muted),
                          ),
                          const SizedBox(height: 24),
                          const Text(
                            'What happened? (required)',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 10),
                          for (final (reason, slug) in _reasons) ...[
                            _ReasonOption(
                              key: ValueKey('failure-reason-$slug'),
                              label: reason,
                              selected: _reason == reason,
                              onPressed: _saving
                                  ? null
                                  : () => setState(() {
                                      _reason = reason;
                                      _validationError = null;
                                    }),
                            ),
                            const SizedBox(height: 8),
                          ],
                          const SizedBox(height: 12),
                          TextField(
                            key: const ValueKey('failure-note'),
                            controller: _note,
                            enabled: !_saving,
                            minLines: 3,
                            maxLines: 5,
                            keyboardType: TextInputType.multiline,
                            textInputAction: TextInputAction.newline,
                            decoration: InputDecoration(
                              labelText: _reason == 'Other'
                                  ? 'Describe the reason (required)'
                                  : 'Add a note (optional)',
                              hintText: 'Useful details for the dispatcher',
                              alignLabelWithHint: true,
                            ),
                            onChanged: (_) {
                              if (_validationError != null) {
                                setState(() => _validationError = null);
                              }
                            },
                          ),
                          if (_validationError != null) ...[
                            const SizedBox(height: 10),
                            _FormError(message: _validationError!),
                          ],
                          if (_saveError != null) ...[
                            const SizedBox(height: 12),
                            _FormError(message: _saveError!),
                          ],
                          const SizedBox(height: 20),
                          Text(
                            'This will mark the stop as failed. The delivery status cannot be changed afterwards.',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: OceanColors.muted,
                                  height: 1.4,
                                ),
                          ),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            key: const ValueKey('failure-save'),
                            onPressed: _saving ? null : _save,
                            style: FilledButton.styleFrom(
                              backgroundColor: OceanColors.red,
                              foregroundColor: Colors.white,
                              minimumSize: const Size.fromHeight(56),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 16,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            icon: const Icon(Icons.warning_amber_rounded),
                            label: Text(
                              _saving ? 'Saving…' : 'Mark delivery as failed',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

class _ReasonOption extends StatelessWidget {
  const _ReasonOption({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    checked: selected,
    inMutuallyExclusiveGroup: true,
    child: Material(
      color: selected
          ? OceanColors.orange.withValues(alpha: 0.08)
          : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? OceanColors.orange : OceanColors.border,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? OceanColors.orange : OceanColors.muted,
                size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(label)),
            ],
          ),
        ),
      ),
    ),
  );
}

class _FormError extends StatelessWidget {
  const _FormError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Text(
      message,
      style: const TextStyle(color: OceanColors.red, height: 1.4),
    ),
  );
}
