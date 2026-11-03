import 'package:flutter/services.dart';

const _commands = MethodChannel('throwcast/commands');
const _events = EventChannel('throwcast/events');

/// JSON lines to and from the native engine, which runs inside this app's process.
Stream<String> engineEvents() => _events.receiveBroadcastStream().cast<String>();
Future<void> engineSend(String json) => _commands.invokeMethod('send', json);
Future<void> setMenuBarIcon(bool enabled) => _commands.invokeMethod('menuBar', enabled);
Future<void> setDockIcon(bool visible) => _commands.invokeMethod('dockIcon', visible);
Future<void> setCastingIcon(bool casting) => _commands.invokeMethod('casting', casting);
