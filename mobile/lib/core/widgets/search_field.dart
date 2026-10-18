import 'package:flutter/material.dart';

/// The standard list-search box: a leading magnifier, and a clear button that
/// only appears once there is something to clear. Shared so search behaves
/// and looks the same on every list that has one.
class SearchField extends StatefulWidget {
  final String hintText;
  final ValueChanged<String> onChanged;

  const SearchField({super.key, required this.hintText, required this.onChanged});

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _set(String value) {
    setState(() => _query = value);
    widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search_rounded, size: 20),
        hintText: widget.hintText,
        isDense: true,
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: () {
                  _controller.clear();
                  _set('');
                },
              ),
      ),
      onChanged: _set,
    );
  }
}
