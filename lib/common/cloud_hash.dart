import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The same digest the server computes in `_checksum`: title, a NUL, content.
///
/// Content addressing is what lets a device ask "do you already have this"
/// without inventing an id for a rule or a DNS block, neither of which has a
/// stable one across devices.
String cloudChecksum({required String title, required List<int> content}) {
  final digest = sha256.convert([...utf8.encode(title), 0, ...content]);
  return digest.toString();
}
