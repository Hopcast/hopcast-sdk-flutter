import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

const List<String> _adjectives = [
  'Swift', 'Clever', 'Gentle', 'Brave', 'Sly', 'Calm', 'Merry',
  'Wise', 'Proud', 'Light', 'Valiant', 'Curious', 'Rapid', 'Solar',
  'Lunar', 'Wild', 'Royal', 'Mystic', 'Playful', 'Bright',
];

const List<String> _animals = [
  'Fox', 'Lion', 'Eagle', 'Panther', 'Falcon', 'Wolf', 'Cheetah',
  'Heron', 'Tiger', 'Dolphin', 'Colibri', 'Caracal', 'Gazelle', 'Okapi',
  'Leopard', 'Penguin', 'Lynx', 'Cobra', 'Phoenix', 'Toucan',
];

const String _kNameKey = 'hopcast_demo_device_name';

/// A friendly name (Adjective + Animal), generated once and persisted per install.
///
/// It doubles as the identity shown to neighbours (the `deviceId`) and as the key
/// for the allow/block lists. A single, stable name per device is important: the
/// trust policy matches on it.
Future<String> friendlyDeviceName() async {
  final prefs = await SharedPreferences.getInstance();
  final existing = prefs.getString(_kNameKey);
  if (existing != null && existing.isNotEmpty) return existing;

  final rnd = Random();
  final name =
      '${_adjectives[rnd.nextInt(_adjectives.length)]} ${_animals[rnd.nextInt(_animals.length)]}';
  await prefs.setString(_kNameKey, name);
  return name;
}
