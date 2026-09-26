// The level as numbers: the run's two columns, the counts against the caps the
// game holds, and the fields of whatever is selected.
//
// The counts are the point. The game drops records it cannot hold without
// saying so, so the number beside each cap is the reason a level can look right
// and play short.

import 'package:flutter/material.dart';

import '../editor_state.dart';
import '../jump_level.dart';
import '../wire.dart';

class InspectorPanel extends StatelessWidget {
  const InspectorPanel({super.key, required this.state});

  final EditorState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final level = state.level;
    final spec = state.spec;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('The run', style: theme.textTheme.titleSmall),
        _ColumnRow(
          label: 'start',
          column: level.startX,
          max: spec.cols - 1,
          onChanged: (value) => state.edit((l) => l.startX = value),
          onReveal: () => state.requestReveal(level.startX),
        ),
        _ColumnRow(
          label: 'checkpoint',
          column: level.checkpointX,
          max: spec.cols - 1,
          onChanged: (value) => state.edit((l) => l.checkpointX = value),
          onReveal: () => state.requestReveal(level.checkpointX),
        ),
        const Divider(height: 24),
        Text('Counts', style: theme.textTheme.titleSmall),
        _CountRow(
            label: 'coins',
            used: level.coins.length,
            cap: spec.coinSlots),
        _CountRow(
            label: 'enemies',
            used: level.enemies.length,
            cap: spec.enemySlots),
        _CountRow(
            label: 'pipes', used: level.pipes.length, cap: spec.pipeSlots),
        _CountRow(
            label: 'block runs',
            used: blockRunsOf(level).length,
            cap: spec.blockMax),
        _CountRow(
            label: 'ground runs',
            used: groundRunsOf(level).length,
            cap: spec.groundMax),
        const Divider(height: 24),
        Text('Selected', style: theme.textTheme.titleSmall),
        ..._selected(context),
      ],
    );
  }

  List<Widget> _selected(BuildContext context) {
    final theme = Theme.of(context);
    final selected = state.selection;
    final level = state.level;
    final spec = state.spec;
    if (selected == null) {
      return [
        Text('nothing selected', style: theme.textTheme.bodySmall),
      ];
    }

    final rows = <Widget>[];
    rows.add(Text('column ${selected.column}', style: theme.textTheme.bodyMedium));
    rows.add(_Row('surface', _surfaceLabel(level, selected.column)));

    switch (selected.kind) {
      case SelectionKind.column:
        final block = level.blockKindAt(selected.column);
        if (block != null) {
          final kind = spec.blockKindByValue(block);
          rows.add(_Row('block',
              '${kind?.display ?? block}, row ${level.blockRowAt(selected.column)}'));
          rows.add(FilledButton.tonalIcon(
            onPressed: () => state.eraseBlock(selected.column),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Remove block'),
          ));
        }
      case SelectionKind.pipe:
        final pipe = selected.pipe!;
        rows.add(_Stepper(
          label: 'left column',
          value: pipe.x,
          min: 0,
          max: spec.cols - spec.pipeW,
          onChanged: (value) => state.updateSelected((_, s) {
            s.pipe!.x = value;
          }),
        ));
        rows.add(_Stepper(
          label: 'height',
          value: pipe.h,
          min: 1,
          max: spec.groundRow - 1,
          onChanged: (value) => state.updateSelected((_, s) {
            s.pipe!.h = value;
          }),
        ));
        rows.add(SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('piranha plant'),
          value: pipe.plant != 0,
          onChanged: (value) => state.updateSelected((_, s) {
            s.pipe!.plant = value ? 1 : 0;
          }),
        ));
      case SelectionKind.coin:
        final coin = selected.coin!;
        rows.add(_Stepper(
          label: 'x',
          value: coin.x,
          min: 0,
          max: spec.cols - 2,
          onChanged: (value) => state.updateSelected((_, s) {
            s.coin!.x = value;
          }),
        ));
        rows.add(_Stepper(
          label: 'y',
          value: coin.y,
          min: 0,
          max: spec.rows - 2,
          onChanged: (value) => state.updateSelected((_, s) {
            s.coin!.y = value;
          }),
        ));
      case SelectionKind.enemy:
        final enemy = selected.enemy!;
        rows.add(_Stepper(
          label: 'x',
          value: enemy.x,
          min: 0,
          max: spec.cols - 1,
          onChanged: (value) => state.updateSelected((_, s) {
            s.enemy!.x = value;
          }),
        ));
        rows.add(_Stepper(
          label: 'row',
          value: enemy.row,
          min: 0,
          max: spec.rows - 1,
          onChanged: (value) => state.updateSelected((_, s) {
            s.enemy!.row = value;
          }),
        ));
        rows.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              const Expanded(child: Text('direction')),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: -1, label: Text('left')),
                  ButtonSegment(value: 0, label: Text('still')),
                  ButtonSegment(value: 1, label: Text('right')),
                ],
                selected: {enemy.dir},
                onSelectionChanged: (values) => state.updateSelected((_, s) {
                  s.enemy!.dir = values.first;
                }),
              ),
            ],
          ),
        ));
        rows.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              const Expanded(child: Text('kind')),
              DropdownButton<int>(
                value: enemy.kind,
                onChanged: (value) {
                  if (value == null) return;
                  state.updateSelected((_, s) {
                    s.enemy!.kind = value;
                  });
                },
                items: [
                  for (final kind in spec.enemyKinds)
                    DropdownMenuItem(
                        value: kind.value, child: Text(kind.display)),
                ],
              ),
            ],
          ),
        ));
    }

    rows.add(const SizedBox(height: 8));
    rows.add(OutlinedButton.icon(
      onPressed: state.deleteSelected,
      icon: const Icon(Icons.delete_outline, size: 18),
      label: const Text('Delete'),
    ));
    return rows;
  }

  String _surfaceLabel(JumpLevel level, int column) {
    final row = level.surfaceAt(column);
    if (row == kPit) return 'pit';
    final pipe = level.pipeAt(column);
    if (pipe != null) return 'row $row (pipe)';
    return 'row $row';
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _ColumnRow extends StatelessWidget {
  const _ColumnRow({
    required this.label,
    required this.column,
    required this.max,
    required this.onChanged,
    required this.onReveal,
  });

  final String label;
  final int column;
  final int max;
  final ValueChanged<int> onChanged;
  final VoidCallback onReveal;

  @override
  Widget build(BuildContext context) {
    return _Stepper(
      label: label,
      value: column,
      min: 0,
      max: max,
      onChanged: onChanged,
      onReveal: onReveal,
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onReveal,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  final VoidCallback? onReveal;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        IconButton(
          tooltip: 'lower $label',
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          onPressed: value > min ? () => onChanged(value - 1) : null,
          icon: const Icon(Icons.remove),
        ),
        Text('$value'),
        IconButton(
          tooltip: 'raise $label',
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          onPressed: value < max ? () => onChanged(value + 1) : null,
          icon: const Icon(Icons.add),
        ),
        if (onReveal != null)
          IconButton(
            tooltip: 'show $label on the map',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: onReveal,
            icon: const Icon(Icons.my_location),
          ),
      ],
    );
  }
}

class _CountRow extends StatelessWidget {
  const _CountRow({required this.label, required this.used, required this.cap});

  final String label;
  final int used;
  final int cap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final over = used > cap;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
          Text(
            '$used/$cap',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: over ? theme.colorScheme.error : null,
              fontWeight: over ? FontWeight.bold : null,
            ),
          ),
        ],
      ),
    );
  }
}
