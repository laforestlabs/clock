// The tools, the kinds they place, and the zoom.
//
// One row above the map, because the tool is what the next click means: the
// pickers appear next to the tool they belong to rather than in a panel
// somewhere else, so "Block" and "which block" are read together.
//
// Everything here writes to the editor's state and nothing else: what a tool
// does to a level is the state's business (see editor_state.dart).

import 'package:flutter/material.dart';

import '../editor_state.dart';
import 'map_view.dart';

class PaletteBar extends StatelessWidget {
  const PaletteBar({super.key, required this.state});

  final EditorState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              for (final tool in EditorTool.values)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: ChoiceChip(
                    selected: state.tool == tool,
                    onSelected: (_) => state.setTool(tool),
                    avatar: Icon(_toolIcon(tool), size: 16),
                    label: Text(tool.label),
                  ),
                ),
              const SizedBox(width: 20),
              ..._pickers(context),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
          child: Text(
            _hint(state.tool),
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  List<Widget> _pickers(BuildContext context) {
    final spec = state.spec;
    switch (state.tool) {
      case EditorTool.block:
        return [
          const Text('kind'),
          const SizedBox(width: 8),
          for (final kind in spec.blockKinds)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: ChoiceChip(
                selected: state.blockKind == kind.value,
                onSelected: (_) => state.setBlockKind(kind.value),
                avatar: CircleAvatar(
                  radius: 7,
                  backgroundColor:
                      blockKindSwatch(spec, kind.value) ?? Colors.grey,
                ),
                label: Text(kind.display),
              ),
            ),
        ];
      case EditorTool.enemy:
        return [
          const Text('kind'),
          const SizedBox(width: 8),
          for (final kind in spec.enemyKinds)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: ChoiceChip(
                selected: state.enemyKind == kind.value,
                onSelected: (_) => state.setEnemyKind(kind.value),
                label: Text(kind.display),
              ),
            ),
          const SizedBox(width: 12),
          const Text('facing'),
          const SizedBox(width: 8),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: -1, label: Text('left')),
              ButtonSegment(value: 0, label: Text('still')),
              ButtonSegment(value: 1, label: Text('right')),
            ],
            selected: {state.enemyDir},
            onSelectionChanged: (values) => state.setEnemyDir(values.first),
          ),
        ];
      case EditorTool.pipe:
        return [
          const Text('height'),
          IconButton(
            tooltip: 'shorter pipe',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: state.pipeH > 1
                ? () => state.setPipeH(state.pipeH - 1)
                : null,
            icon: const Icon(Icons.remove),
          ),
          Text('${state.pipeH}'),
          IconButton(
            tooltip: 'taller pipe',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: state.pipeH < spec.groundRow - 1
                ? () => state.setPipeH(state.pipeH + 1)
                : null,
            icon: const Icon(Icons.add),
          ),
          const SizedBox(width: 12),
          FilterChip(
            selected: state.pipePlant,
            onSelected: (value) => state.setPipePlant(value),
            label: const Text('piranha plant'),
          ),
        ];
      default:
        return _zoom();
    }
  }

  List<Widget> _zoom() => [
        const Text('zoom'),
        IconButton(
          tooltip: 'zoom out',
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          onPressed: () => state.setZoom(state.zoom - 2),
          icon: const Icon(Icons.zoom_out),
        ),
        SizedBox(
          width: 140,
          child: Slider(
            value: state.zoom.clamp(4, 40).toDouble(),
            min: 4,
            max: 40,
            divisions: 18,
            label: '${state.zoom.round()} px',
            onChanged: state.setZoom,
          ),
        ),
        IconButton(
          tooltip: 'zoom in',
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          onPressed: () => state.setZoom(state.zoom + 2),
          icon: const Icon(Icons.zoom_in),
        ),
        Text('${state.zoom.round()} px'),
      ];

  static String _hint(EditorTool tool) {
    switch (tool) {
      case EditorTool.select:
        return 'Select: click a column, a pipe, a coin or an enemy to see its fields.';
      case EditorTool.terrain:
        return 'Terrain: sets a column\'s ground to the row under the cursor.';
      case EditorTool.pit:
        return 'Pit: takes the ground out of a column.';
      case EditorTool.ground:
        return 'Ground: puts a column back to the plain ground row.';
      case EditorTool.block:
        return 'Block: the row under the cursor is the block\'s row; drag sideways for a run.';
      case EditorTool.coin:
        return 'Coin: places a 2x2 coin at the cursor.';
      case EditorTool.enemy:
        return 'Enemy: places an enemy standing on the row under the cursor.';
      case EditorTool.pipe:
        return 'Pipe: a three-column pipe with its left edge where you click (it replaces the one it overlaps).';
      case EditorTool.checkpoint:
        return 'Checkpoint: where a death after it puts the player back.';
      case EditorTool.start:
        return 'Start: the column the run begins on.';
      case EditorTool.erase:
        return 'Erase: removes the block, coin, enemy or pipe under the cursor.';
    }
  }

  static IconData _toolIcon(EditorTool tool) {
    switch (tool) {
      case EditorTool.select:
        return Icons.highlight_alt;
      case EditorTool.terrain:
        return Icons.terrain;
      case EditorTool.pit:
        return Icons.vertical_align_bottom;
      case EditorTool.ground:
        return Icons.horizontal_rule;
      case EditorTool.block:
        return Icons.crop_square;
      case EditorTool.coin:
        return Icons.monetization_on_outlined;
      case EditorTool.enemy:
        return Icons.pest_control;
      case EditorTool.pipe:
        return Icons.plumbing;
      case EditorTool.checkpoint:
        return Icons.flag_outlined;
      case EditorTool.start:
        return Icons.person_pin_circle_outlined;
      case EditorTool.erase:
        return Icons.cleaning_services_outlined;
    }
  }
}
