import 'package:shared_preferences/shared_preferences.dart';

/// How to handle incoming requests from devices that are neither allowed nor blocked.
/// - [everyone] : accept incoming transfers automatically;
/// - [ask]      : prompt on every new device.
enum AcceptMode { everyone, ask }

/// Minimal, generic trust policy: allow list + block list keyed by friendly name,
/// plus the acceptance mode for unknown devices.
///
/// - allowed  -> transfer accepted automatically
/// - blocked  -> transfer rejected automatically
/// - neither  -> depends on the mode (accept everyone / ask each time)
///
/// This is app-level policy layered on top of the SDK's MANUAL acceptance policy;
/// the SDK simply surfaces each invitation and this class decides what to do.
class Trust {
  Trust._();
  static final Trust instance = Trust._();

  static const _kAllow = 'hopcast_demo_allow_list';
  static const _kBlock = 'hopcast_demo_block_list';
  static const _kMode = 'hopcast_demo_accept_mode';

  Future<Set<String>> _get(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(key) ?? const []).toSet();
  }

  Future<void> _set(String key, Set<String> values) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(key, values.toList());
  }

  Future<bool> isAllowed(String name) async => (await _get(_kAllow)).contains(name);
  Future<bool> isBlocked(String name) async => (await _get(_kBlock)).contains(name);

  Future<Set<String>> allowList() => _get(_kAllow);
  Future<Set<String>> blockList() => _get(_kBlock);

  /// Adds to the allow list (and removes from the block list).
  Future<void> allow(String name) async {
    final block = await _get(_kBlock)..remove(name);
    await _set(_kBlock, block);
    final allow = await _get(_kAllow)..add(name);
    await _set(_kAllow, allow);
  }

  /// Adds to the block list (and removes from the allow list).
  Future<void> block(String name) async {
    final allow = await _get(_kAllow)..remove(name);
    await _set(_kAllow, allow);
    final block = await _get(_kBlock)..add(name);
    await _set(_kBlock, block);
  }

  /// Removes the device from both lists (back to "ask").
  Future<void> clear(String name) async {
    final allow = await _get(_kAllow)..remove(name);
    await _set(_kAllow, allow);
    final block = await _get(_kBlock)..remove(name);
    await _set(_kBlock, block);
  }

  /// Acceptance mode for devices that are neither allowed nor blocked. Default: [everyone].
  Future<AcceptMode> acceptMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kMode) == 'ask' ? AcceptMode.ask : AcceptMode.everyone;
  }

  Future<void> setAcceptMode(AcceptMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMode, mode == AcceptMode.ask ? 'ask' : 'everyone');
  }
}
