// Imperative-modal renderer (Batch 4 — §4.3).
//
// Three modal kinds, all triggered by a backend `ui.modal` notification:
//   * [UiAlertPush]       → Material `AlertDialog` (system back-press +
//                           tap-outside honor `dismissible`).
//   * [UiActionSheetPush] → modal bottom-sheet list with leading icons
//                           (Android-style; matches the existing
//                           `UiSelect` picker for visual consistency).
//   * [UiBottomSheetPush] → modal bottom-sheet hosting an arbitrary
//                           `UiNode` rendered through [UiRenderer].
//
// Dismissal: tap-outside / back-press / drag-down emits the configured
// `dismissEventId` (or none, for AlertDialog without dismissible:false).
// Action picks call `onEvent` with the picked action's `eventId`.
//
// Why a top-level function instead of a widget: modals attach to a
// Navigator, not the widget tree. The owning panel renderer's
// BuildContext is the right anchor because (a) the panel is mounted
// when its plugin asks to show a modal, and (b) the modal closes
// automatically when the panel does (e.g. user pops the detail
// screen) — the screen owner doesn't have to remember to cancel.

import 'package:flutter/material.dart';

import 'app_tokens.dart';
import 'icon_catalog.dart';
import 'ui_node.dart';
import 'ui_renderer.dart';

/// Show a Batch-4 imperative modal. The `onEvent` callback fires
/// exactly once: either with the picked action's `eventId`, or with the
/// configured `dismissEventId` (if any) on tap-outside / back-press.
/// For [UiAlertPush] with `dismissible: false`, only the action buttons
/// can resolve the dialog.
Future<void> showUiModal({
  required BuildContext context,
  required UiModalPush push,
  required void Function(UiNodeEvent event) onEvent,
}) async {
  switch (push) {
    case UiAlertPush(:final alert):
      await _showAlert(context, alert, onEvent);
      break;
    case UiActionSheetPush(:final sheet):
      await _showActionSheet(context, sheet, onEvent);
      break;
    case UiBottomSheetPush(:final sheet):
      await _showBottomSheet(context, sheet, onEvent);
      break;
  }
}

Future<void> _showAlert(
  BuildContext context,
  UiAlertDialog alert,
  void Function(UiNodeEvent) onEvent,
) async {
  final picked = await showDialog<String>(
    context: context,
    barrierDismissible: alert.dismissible,
    useRootNavigator: true,
    builder: (dialogCtx) {
      return PopScope(
        // `dismissible: false` blocks the system back gesture too — not
        // just the tap-outside. Without PopScope the user could still
        // pop the route from the back gesture even though
        // `barrierDismissible` was off.
        canPop: alert.dismissible,
        child: AlertDialog(
          key: ValueKey<String>('ui-alert:${alert.id}'),
          title: Text(alert.title),
          content: alert.body == null ? null : Text(alert.body!),
          actions: [
            for (final action in alert.actions)
              _alertActionButton(dialogCtx, action),
          ],
        ),
      );
    },
  );
  // picked == null → user dismissed (tap-outside / back-press). Only
  // possible when `dismissible == true`. AlertDialog has no
  // dismissEventId per spec, so we drop the event silently.
  if (picked == null) return;
  onEvent(UiNodeEvent(nodeId: alert.id, type: picked));
}

Widget _alertActionButton(BuildContext ctx, UiAlertAction action) {
  switch (action.variant ?? UiAlertActionVariant.primary) {
    case UiAlertActionVariant.primary:
      return TextButton(
        key: ValueKey<String>('ui-alert-action:${action.eventId}'),
        onPressed: () => Navigator.of(ctx).pop(action.eventId),
        child: Text(action.label),
      );
    case UiAlertActionVariant.danger:
      // FilledButton.tonal in danger color reads as the destructive
      // option (matches the UiButton danger variant's visual weight).
      return TextButton(
        key: ValueKey<String>('ui-alert-action:${action.eventId}'),
        onPressed: () => Navigator.of(ctx).pop(action.eventId),
        style: TextButton.styleFrom(
          foregroundColor: Theme.of(ctx).colorScheme.error,
        ),
        child: Text(action.label),
      );
  }
}

Future<void> _showActionSheet(
  BuildContext context,
  UiActionSheet sheet,
  void Function(UiNodeEvent) onEvent,
) async {
  final picked = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    useRootNavigator: true,
    builder: (sheetCtx) {
      return SafeArea(
        key: ValueKey<String>('ui-action-sheet:${sheet.id}'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (sheet.title != null && sheet.title!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.sm,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    sheet.title!,
                    style: Theme.of(sheetCtx).textTheme.titleMedium,
                  ),
                ),
              ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: sheet.actions.length,
                itemBuilder: (ctx, i) {
                  final action = sheet.actions[i];
                  final iconData = action.icon == null
                      ? null
                      : resolveIconByName(action.icon!);
                  final accentColor = action.accent == null
                      ? null
                      : StyleSlotResolver.accent(ctx, action.accent!);
                  return ListTile(
                    key: ValueKey<String>(
                      'ui-action-sheet-action:${action.eventId}',
                    ),
                    leading: iconData == null
                        ? null
                        : Icon(iconData, color: accentColor),
                    title: Text(
                      action.label,
                      style: accentColor == null
                          ? null
                          : TextStyle(color: accentColor),
                    ),
                    onTap: () => Navigator.of(sheetCtx).pop(action.eventId),
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  );
  if (picked != null) {
    onEvent(UiNodeEvent(nodeId: sheet.id, type: picked));
    return;
  }
  // Dismissed without picking. Surface the configured event if any.
  final dismissId = sheet.dismissEventId;
  if (dismissId != null) {
    onEvent(UiNodeEvent(nodeId: sheet.id, type: dismissId));
  }
}

Future<void> _showBottomSheet(
  BuildContext context,
  UiBottomSheet sheet,
  void Function(UiNodeEvent) onEvent,
) async {
  // The sheet's child is rendered through `UiRenderer` — any
  // leaf-widget event (button tap, switch change, …) flows back through
  // the same `onEvent` channel as the picked-action shorthand. This
  // is intentional: a UiBottomSheet whose child includes a Button
  // doesn't need a separate "action" concept, the Button's regular
  // `tap` event is sufficient.
  final dismissed = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useRootNavigator: true,
    builder: (sheetCtx) {
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        minChildSize: 0.3,
        maxChildSize: 0.92,
        builder: (innerCtx, scrollController) {
          return SafeArea(
            key: ValueKey<String>('ui-bottom-sheet:${sheet.id}'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (sheet.title != null && sheet.title!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      AppSpacing.sm,
                      AppSpacing.lg,
                      AppSpacing.sm,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        sheet.title!,
                        style: Theme.of(innerCtx).textTheme.titleMedium,
                      ),
                    ),
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    controller: scrollController,
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: UiRenderer(tree: sheet.child, onEvent: onEvent),
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
  // showModalBottomSheet returns null on drag-down / tap-outside; we
  // never pop with a value from within (the child's UiRenderer fires
  // events directly through onEvent above). Either way the dismiss
  // event fires only on actual dismiss, not on an inner button tap.
  if (dismissed == null) {
    final dismissId = sheet.dismissEventId;
    if (dismissId != null) {
      onEvent(UiNodeEvent(nodeId: sheet.id, type: dismissId));
    }
  }
}
