// The playtest: the level, played in a window of its own.
//
// This panel is the launcher and the instrument, not the player. The game runs
// in a separate window (a separate process, see playtest_window.dart) sized to
// nearly the whole screen, because the panel it renders is 64x32 and the detail
// that matters - where a jump lands, whether a gap is clearable - is invisible at
// the size a side panel can offer.
//
// It opens in one of two ways, and the difference is who is driving: a person at
// the keys, or the computer, which is the auto playtest. The computer's run is
// the one that reads as a test report: how far it got, and where it came unstuck.

import 'package:flutter/material.dart';

import '../autoplay.dart';
import '../editor_state.dart';
import '../playtest.dart';

class PlaytestPanel extends StatelessWidget {
  const PlaytestPanel({super.key, required this.state});

  final EditorState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = state.playtestReport;
    final running = state.playtestRunning;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Playtest', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'The level plays in a window of its own, nearly the whole screen, so '
          'you can see what a jump does. The window plays the level as it was '
          'when it opened; editing here does not change it.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        _skillPicker(context),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: () => state.openPlaytestWindow(),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Play in a window'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => state.openPlaytestWindow(auto: true),
              icon: const Icon(Icons.smart_toy_outlined, size: 18),
              label: const Text('Auto playtest'),
            ),
            if (running) ...[
              OutlinedButton.icon(
                onPressed: () => state.restartPlaytestWindow(fromHere: true),
                icon: const Icon(Icons.flag_outlined, size: 18),
                label: const Text('Play from here'),
              ),
              OutlinedButton.icon(
                onPressed: () => state.restartPlaytestWindow(),
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('Restart'),
              ),
              TextButton.icon(
                onPressed: state.closePlaytestWindow,
                icon: const Icon(Icons.close, size: 18),
                label: const Text('Close window'),
              ),
            ],
          ],
        ),
        if (state.playtestError != null) ...[
          const SizedBox(height: 12),
          Text(
            state.playtestError!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        const Divider(height: 24),
        if (!running && report == null)
          Text(
            'Nothing playing. Auto playtest opens the same window with the '
            'computer at the controls: it runs right and jumps at pits, steps '
            'and enemies, and reports how far it got.',
            style: theme.textTheme.bodySmall,
          )
        else
          ..._readout(context, report, running),
      ],
    );
  }

  /// The computer's skill: how carefully the bot plays the auto playtest. A
  /// level can clear for a sharp bot and stop a careless one, so how it plays
  /// is part of the test and has to be chosen, not assumed.
  Widget _skillPicker(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Auto playtest skill', style: theme.textTheme.bodyMedium),
            DropdownButton<AutoSkill>(
              value: state.playtestSkill,
              isDense: true,
              onChanged: (skill) {
                if (skill != null) state.selectPlaytestSkill(skill);
              },
              items: [
                for (final skill in AutoSkill.values)
                  DropdownMenuItem(value: skill, child: Text(skill.label)),
              ],
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(state.playtestSkill.description, style: theme.textTheme.bodySmall),
      ],
    );
  }

  List<Widget> _readout(
      BuildContext context, PlaytestReport? report, bool running) {
    final theme = Theme.of(context);
    final rows = <Widget>[];

    rows.add(Row(
      children: [
        Icon(
          state.playtestAuto ? Icons.smart_toy_outlined : Icons.videogame_asset,
          size: 18,
        ),
        const SizedBox(width: 8),
        Text(
          state.playtestAuto
              ? 'auto playtest · '
                  '${state.playtestRunSkill?.label ?? state.playtestSkill.label}'
              : 'playtest',
          style: theme.textTheme.bodyMedium,
        ),
        const Spacer(),
        Text(running ? 'running' : 'closed', style: theme.textTheme.bodySmall),
      ],
    ));

    if (report == null) {
      rows.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text('waiting for the window to report...',
            style: theme.textTheme.bodySmall),
      ));
      return rows;
    }

    rows.add(const SizedBox(height: 6));
    rows.add(Text(
      'tick ${report.tick}   column ${report.playerX}   '
      'lives ${report.lives}   ${_statusName(report.status)}',
      style: theme.textTheme.bodyMedium,
    ));
    if (report.deaths > 0) {
      rows.add(Text(
        'died ${report.deaths}×${report.diedAt == null ? '' : ' (last at column ${report.diedAt})'}',
        style:
            theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
      ));
    }
    if (state.playtestAuto) {
      rows.add(const SizedBox(height: 6));
      rows.add(Text(
        report.stuckAt != null
            ? 'The computer could not get past column ${report.stuckAt}. '
                'That is worth a look, not a verdict: the bot is not a person, '
                'so a column it cannot pass is a question about the level - try '
                'a sharper skill before calling the level wrong.'
            : 'The computer is working its way right; it reached column '
                '${report.reached}.',
        style: theme.textTheme.bodySmall,
      ));
      rows.add(Text(report.summary(), style: theme.textTheme.bodySmall));
    }
    if (state.playtestStale) {
      rows.add(const SizedBox(height: 6));
      rows.add(Text(
        'The level has changed since this window opened, so the map is no '
        'longer following the run.',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.tertiary),
      ));
    }
    return rows;
  }

  static String _statusName(int status) {
    switch (status) {
      case kStatusPlaying:
        return 'playing';
      case kStatusDying:
        return 'dying';
      case kStatusWon:
        return 'won';
      case kStatusOver:
        return 'over';
    }
    return '$status';
  }
}
