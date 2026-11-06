import 'package:flutter/foundation.dart';

/// Process-wide read-only switch owned by the sync layer.
///
/// Profile writes go through a handful of provider methods rather than a
/// single action, so the gate sits here and those methods consult it. Keeping
/// it out of the provider graph avoids a cycle: the database layer must not
/// depend on the sync notifier that watches it.
abstract final class SyncGuard {
  static final ValueNotifier<bool> readOnly = ValueNotifier<bool>(false);

  /// Incremented every time a write is refused, so the shell can tell the user
  /// why the tap did nothing.
  static final ValueNotifier<int> blocked = ValueNotifier<int>(0);

  static bool get isReadOnly => readOnly.value;

  static void setReadOnly(bool value) {
    if (readOnly.value == value) return;
    readOnly.value = value;
  }

  /// Returns true when the caller may write. Callers that cannot surface an
  /// error should use this instead of throwing.
  static bool allow() {
    if (!readOnly.value) return true;
    blocked.value++;
    return false;
  }

  @visibleForTesting
  static void reset() {
    readOnly.value = false;
    blocked.value = 0;
  }
}
