// What the level checks out as, and what the reachability sweep could not clear.
//
// Two lists in one panel, because they answer one question - what is wrong with
// this level - and because the difference between them matters: a structural
// finding is a fact about the level (a coin outside the field, a spawn inside a
// block), while a scan finding is a hint (no single jump timing cleared this
// pit). The scan's line says so; the tag on each row says which is which.

import 'package:flutter/material.dart';

import '../editor_state.dart';
import '../validate.dart';

class FindingsPanel extends StatelessWidget {
  const FindingsPanel({super.key, required this.state});

  final EditorState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final findings = state.findings;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: Text('Findings', style: theme.textTheme.titleSmall),
              ),
              if (state.scanning)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                TextButton.icon(
                  onPressed: state.checkReachability,
                  icon: const Icon(Icons.travel_explore, size: 18),
                  label: const Text('Check reachability'),
                ),
            ],
          ),
        ),
        if (state.scanning)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: LinearProgressIndicator(value: state.scanProgress),
          ),
        Expanded(
          child: findings.isEmpty
              ? Center(
                  child: Text(
                    'nothing to report',
                    style: theme.textTheme.bodySmall,
                  ),
                )
              : ListView.builder(
                  itemCount: findings.length,
                  itemBuilder: (context, index) => _FindingRow(
                    finding: findings[index],
                    onTap: () {
                      final column = findings[index].column;
                      if (column != null) state.revealFinding(column);
                    },
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Text(
            'A scan is a hint, not a verdict: it presses Jump once, so a gap '
            'meant to be crossed in two hops (landing on a block mid-gap) '
            'reports as unclearable.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _FindingRow extends StatelessWidget {
  const _FindingRow({required this.finding, required this.onTap});

  final Finding finding;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isError = finding.severity == FindingSeverity.error;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.warning_amber_outlined,
              size: 18,
              color: isError
                  ? theme.colorScheme.error
                  : theme.colorScheme.tertiary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(finding.message, style: theme.textTheme.bodyMedium),
                  if (finding.column != null)
                    Text(
                      'column ${finding.column}'
                      '${finding.fromScan ? '  ·  scan' : ''}',
                      style: theme.textTheme.bodySmall,
                    )
                  else if (finding.fromScan)
                    Text('scan', style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
