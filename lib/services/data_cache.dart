class DataCache {
  static final Map<String, _CacheEntry> _store = {};

  static const Duration _defaultTtl = Duration(hours: 6);

  static T? get<T>(String key) {
    final entry = _store[key];
    if (entry == null) return null;
    if (entry.isExpired) {
      _store.remove(key);
      return null;
    }
    return entry.value as T?;
  }

  static void set<T>(String key, T value, {Duration? ttl}) {
    _store[key] = _CacheEntry(
      value,
      DateTime.now().add(ttl ?? _defaultTtl),
    );
  }

  static void clear() {
    _store.clear();
  }

  static void clearPrefix(String prefix) {
    _store.removeWhere((k, _) => k.startsWith(prefix));
  }
}

class _CacheEntry {
  final dynamic value;
  final DateTime expiresAt;

  _CacheEntry(this.value, this.expiresAt);

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}
