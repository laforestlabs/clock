// The widget list.
//
// Order is paint order: later entries draw over earlier ones, which is why
// reordering is exposed rather than hidden. Dragging a row changes what wins
// when two widgets overlap.

import 'package:flutter/material.dart';

import '../controller.dart';
import '../model/field_schema.dart';

class WidgetListPanel extends StatelessWidget {
  const WidgetListPanel({super.key, required this.controller});

  final DesignerController controller;

  static const Map<String, IconData> _icons = <String, IconData>{
    'clock': Icons.schedule,
    'date': Icons.calendar_today,
    'text': Icons.text_fields,
    'rect': Icons.crop_square,
    'line': Icons.horizontal_rule,
    'weather': Icons.wb_sunny_outlined,
    'icon': Icons.image_outlined,
    'agenda': Icons.event_note,
    'todo': Icons.checklist,
    'countdown': Icons.timer_outlined,
    'precip': Icons.water_drop_outlined,
  };

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final widgets = controller.doc.widgets;
        final theme = Theme.of(context);

        if (widgets.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No widgets yet.\nUse Add to place one.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ),
          );
        }

        return ReorderableListView.builder(
          buildDefaultDragHandles: false,
          itemCount: widgets.length,
          onReorder: (from, to) {
            // ReorderableListView reports the target index as if the dragged
            // row were still in place, so shift down when moving forwards.
            controller.reorder(from, to > from ? to - 1 : to);
          },
          itemBuilder: (context, index) {
            final w = widgets[index];
            final selected = index == controller.selected;
            final known = isKnownType(w.type);

            return ListTile(
              key: ValueKey<int>(index),
              dense: true,
              selected: selected,
              selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.14),
              leading: Icon(
                _icons[w.type] ?? Icons.help_outline,
                size: 20,
                color: known ? null : theme.colorScheme.error,
              ),
              title: Text(
                w.label,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                known
                    ? '${w.type}  ${w.rect.left.toInt()},${w.rect.top.toInt()}'
                        '  ${w.rect.width.toInt()}x${w.rect.height.toInt()}'
                    // An unrecognised type still lists, so the user can see and
                    // fix the typo instead of wondering why nothing draws.
                    : 'unknown type "${w.type}", not drawn',
                style: theme.textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: ReorderableDragStartListener(
                index: index,
                child: const Icon(Icons.drag_handle, size: 20),
              ),
              onTap: () => controller.select(index),
            );
          },
        );
      },
    );
  }
}

/// The "add widget" menu, built from the engine's own type list so a new
/// widget in the C core appears here with no Dart change.
class AddWidgetButton extends StatelessWidget {
  const AddWidgetButton({super.key, required this.controller});

  final DesignerController controller;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Add widget',
      icon: const Icon(Icons.add),
      onSelected: controller.addWidget,
      itemBuilder: (context) => controller.engine.widgetTypes
          .map(
            (type) => PopupMenuItem<String>(
              value: type,
              child: Row(
                children: <Widget>[
                  Icon(WidgetListPanel._icons[type] ?? Icons.help_outline,
                      size: 18),
                  const SizedBox(width: 12),
                  Text(type),
                ],
              ),
            ),
          )
          .toList(growable: false),
    );
  }
}
