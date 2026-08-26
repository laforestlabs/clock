import 'package:flutter/material.dart';

/// A labelled colour picker: a text field for the hex value plus a swatch
/// palette. Shared by the inspector and the simplified user view.
class ColorField extends StatelessWidget {
  const ColorField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.help,
  });

  final String label;
  final String? value;
  final String? help;
  final ValueChanged<String?> onChanged;

  /// Palette chosen to stay legible through a two-way mirror: saturated and
  /// bright, with no mid greys, which vanish at 20 percent transmission.
  static const List<String> _swatches = <String>[
    '#FFFFFF',
    '#00E5FF',
    '#66D9EF',
    '#FF9F43',
    '#FFC24D',
    '#E06C5A',
    '#5AA0E0',
    '#A0E060',
    '#8899AA',
    '#1E2A33',
  ];

  Color? get _parsed {
    final v = value;
    if (v == null || v.isEmpty) return null;
    final hex = v.startsWith('#') ? v.substring(1) : v;
    if (hex.length != 6) return null;
    final n = int.tryParse(hex, radix: 16);
    return n == null ? null : Color(0xFF000000 | n);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: _parsed ?? Colors.transparent,
                border: Border.all(color: Colors.white24),
                borderRadius: BorderRadius.circular(4),
              ),
              child: _parsed == null
                  ? const Icon(Icons.clear, size: 14, color: Colors.white38)
                  : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextFormField(
                key: ValueKey<String>('$label${value ?? ""}'),
                initialValue: value ?? '',
                decoration: InputDecoration(
                  labelText: label,
                  helperText: help,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onFieldSubmitted: onChanged,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: _swatches
              .map(
                (hex) => InkWell(
                  onTap: () => onChanged(hex),
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: Color(
                          0xFF000000 | int.parse(hex.substring(1), radix: 16)),
                      border: Border.all(color: Colors.white24),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              )
              .toList(growable: false),
        ),
      ],
    );
  }
}
