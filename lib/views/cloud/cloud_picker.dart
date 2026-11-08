import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/sync.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Lists what the cloud holds for one kind and returns the chosen item.
///
/// No context is taken: the dialog helper resolves the right navigator so the
/// picker opens above whatever sheet or page raised it.
Future<CloudItem?> showCloudPicker({required String kind}) {
  return dialogs.showCommonDialog<CloudItem>(
    child: _CloudPickerDialog(kind: kind),
  );
}

class _CloudPickerDialog extends ConsumerStatefulWidget {
  const _CloudPickerDialog({required this.kind});

  final String kind;

  @override
  ConsumerState<_CloudPickerDialog> createState() => _CloudPickerDialogState();
}

class _CloudPickerDialogState extends ConsumerState<_CloudPickerDialog> {
  late final Future<List<CloudItem>> _items;

  @override
  void initState() {
    super.initState();
    _items = ref.read(syncProvider.notifier).listCloud(widget.kind);
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return AlertDialog(
      title: appLocalizations.pickFromCloud,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(appLocalizations.cancel),
        ),
      ],
      child: SizedBox(
        width: 320,
        height: 320,
        child: FutureBuilder<List<CloudItem>>(
          future: _items,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: ActivityIndicator(size: 24));
            }
            final items = snapshot.data ?? const <CloudItem>[];
            if (items.isEmpty) {
              return Center(
                child: Text(
                  appLocalizations.cloudEmpty,
                  textAlign: TextAlign.center,
                  style: AppTextStyle.caption1.of(context).toLighter,
                ),
              );
            }
            return ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return ListItem(
                  leading: const GlyphIcon(AppGlyphs.cloudSync),
                  title: Text(
                    item.title.isEmpty ? item.id.substring(0, 8) : item.title,
                    maxLines: 1,
                  ),
                  subtitle: Text(
                    '${_size(item.size)} · ${item.checksum.substring(0, 6)}',
                    style: AppTextStyle.caption2.of(context).toLighter,
                  ),
                  onTap: () => Navigator.of(context).pop(item),
                );
              },
            );
          },
        ),
      ),
    );
  }

  String _size(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}
