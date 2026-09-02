import 'package:flutter/material.dart';

/// A labelled date-and-time picker. The value is Unix epoch seconds; null
/// shows "Not set". Shared by the inspector and the simplified user view.
class DateTimeField extends StatelessWidget {
  const DateTimeField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.help,
  });

  final String label;
  final int? value;
  final String? help;
  final ValueChanged<int> onChanged;

  static String _two(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final d = value == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(value! * 1000);
    final text = d == null
        ? 'Not set'
        : '${d.year}-${_two(d.month)}-${_two(d.day)} '
            '${_two(d.hour)}:${_two(d.minute)}';

    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(text),
      subtitle: Text(help == null ? label : '$label: $help'),
      onTap: () async {
        final now = DateTime.now();
        final initial = (d != null && d.isAfter(now)) ? d : now;
        final date = await showDatePicker(
          context: context,
          initialDate: initial,
          firstDate: now,
          lastDate: DateTime(2100),
        );
        if (date == null || !context.mounted) return;
        final time = await showTimePicker(
          context: context,
          initialTime: TimeOfDay.now(),
        );
        if (time == null) return;
        final dt =
            DateTime(date.year, date.month, date.day, time.hour, time.minute);
        onChanged(dt.millisecondsSinceEpoch ~/ 1000);
      },
    );
  }
}
