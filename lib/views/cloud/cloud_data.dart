import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/sync.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Kind names travel as server strings; the UI needs them in the reader's
/// language wherever an item is shown.
String cloudKindLabel(AppLocalizations appLocalizations, String kind) {
  return switch (kind) {
    'profile' => appLocalizations.profiles,
    'rule' => appLocalizations.rules,
    'script' => appLocalizations.script,
    _ => kind,
  };
}

Glyph cloudKindGlyph(String kind) {
  return switch (kind) {
    'profile' => AppGlyphs.profiles,
    'rule' => AppGlyphs.rules,
    'script' => AppGlyphs.code,
    _ => AppGlyphs.cloudSync,
  };
}

/// What the cloud holds for one kind, with the two things a device can do to
/// it: pull a copy down, or delete the cloud copy. Uploading is the third, and
/// it works on the whole local set so one tap covers a fresh device.
class CloudDataView extends ConsumerStatefulWidget {
  const CloudDataView({super.key, required this.kind});

  final String kind;

  @override
  ConsumerState<CloudDataView> createState() => _CloudDataViewState();
}

class _CloudDataViewState extends ConsumerState<CloudDataView> {
  late Future<List<CloudItem>> _items;

  @override
  void initState() {
    super.initState();
    _items = _load();
  }

  Future<List<CloudItem>> _load() {
    return ref.read(syncProvider.notifier).listCloud(widget.kind);
  }

  void _reload() {
    setState(() => _items = _load());
  }

  Future<void> _uploadAll() async {
    final appLocalizations = context.appLocalizations;
    final label = cloudKindLabel(appLocalizations, widget.kind);
    final confirmed = await dialogs.showMessage(
      title: appLocalizations.uploadToCloud,
      message: TextSpan(text: appLocalizations.cloudUploadAll(label)),
      confirmText: appLocalizations.uploadToCloud,
      cancelText: appLocalizations.cancel,
    );
    if (confirmed != true || !mounted) return;
    await ref.read(syncProvider.notifier).uploadAll(widget.kind);
    if (!mounted) return;
    _reload();
  }

  Future<void> _download(CloudItem item) async {
    await ref.read(syncProvider.notifier).addFromCloud(item);
  }

  Future<void> _delete(CloudItem item) async {
    final appLocalizations = context.appLocalizations;
    final confirmed = await dialogs.showMessage(
      title: appLocalizations.tip,
      message: TextSpan(text: appLocalizations.deleteTip(item.title)),
      confirmText: appLocalizations.delete,
      cancelText: appLocalizations.cancel,
      destructive: true,
    );
    if (confirmed != true) return;
    final removed = await ref
        .read(syncProvider.notifier)
        .deleteCloudItem(kind: widget.kind, itemId: item.id);
    if (!mounted || !removed) return;
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final busy = ref.watch(syncProvider.select((state) => state.busy));
    return Scaffold(
      title: cloudKindLabel(appLocalizations, widget.kind),
      isLoading: busy,
      actions: [
        IconButton(
          tooltip: appLocalizations.uploadToCloud,
          onPressed: busy ? null : _uploadAll,
          icon: const GlyphIcon(AppGlyphs.upload),
        ),
      ],
      body: FutureBuilder<List<CloudItem>>(
        future: _items,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: ActivityIndicator.page());
          }
          final items = snapshot.data ?? const <CloudItem>[];
          if (items.isEmpty) {
            return Center(
              child: Text(
                appLocalizations.cloudEmpty,
                textAlign: TextAlign.center,
                style: AppTextStyle.body.of(context).toLighter,
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(
              vertical: 8,
            ).copyWith(bottom: 16 + context.bottomInset),
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
                trailing: IconButton(
                  tooltip: appLocalizations.delete,
                  onPressed: busy ? null : () => _delete(item),
                  icon: const GlyphIcon(AppGlyphs.delete),
                ),
                onTap: busy ? null : () => _download(item),
              );
            },
          );
        },
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
