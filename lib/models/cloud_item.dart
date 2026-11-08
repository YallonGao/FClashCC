import 'dart:convert';

/// One item as the cloud holds it: a title and an opaque body.
///
/// Kinds are strings the server never interprets, so a rule, a script, a DNS
/// block and a profile all travel the same way.
class CloudItem {
  const CloudItem({
    required this.kind,
    required this.id,
    required this.title,
    required this.content,
    required this.checksum,
  });

  final String kind;
  final String id;
  final String title;
  final List<int> content;
  final String checksum;

  int get size => content.length;

  static CloudItem? fromJson(Map<String, Object?> json) {
    final id = json['item_id'];
    if (id is! String || id.isEmpty) return null;
    final raw = json['content'];
    return CloudItem(
      kind: json['kind'] is String ? json['kind']! as String : '',
      id: id,
      title: json['title'] is String ? json['title']! as String : '',
      content: raw is String && raw.isNotEmpty ? base64Decode(raw) : const [],
      checksum: json['checksum'] is String ? json['checksum']! as String : '',
    );
  }
}
