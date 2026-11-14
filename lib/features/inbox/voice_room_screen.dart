import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';

class VoiceRoomScreen extends StatefulWidget {
  const VoiceRoomScreen({super.key, required this.channelId, required this.channelName});
  final String channelId;
  final String channelName;

  @override
  State<VoiceRoomScreen> createState() => _VoiceRoomScreenState();
}

class _VoiceRoomScreenState extends State<VoiceRoomScreen> {
  Room? _room;
  bool _connecting = false;
  bool _connected = false;
  bool _muted = false;
  bool _permissionPermanentlyDenied = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  String _friendlyError(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '').trim();
    if (message.isEmpty) return 'Could not join this voice room. Please try again.';
    return message;
  }

  Future<void> _connect() async {
    if (_connecting || _connected) return;

    setState(() {
      _connecting = true;
      _error = null;
      _permissionPermanentlyDenied = false;
    });

    Room? pendingRoom;
    try {
      // Voice transmission must not begin until the user grants microphone access.
      final microphone = await Permission.microphone.request();
      if (!microphone.isGranted) {
        final blocked = microphone.isPermanentlyDenied || microphone.isRestricted;
        if (mounted) {
          setState(() {
            _permissionPermanentlyDenied = blocked;
            _error = kIsWeb
                ? 'Microphone access is blocked. Allow it in your browser site permissions, then retry.'
                : blocked
                    ? 'Microphone access is blocked. Enable it in KOMNIVO app settings, then retry.'
                    : 'Microphone permission is required to join a voice room.';
          });
        }
        return;
      }

      final response = await Supabase.instance.client.functions.invoke(
        'create-livekit-token',
        body: {'channel_id': widget.channelId},
      );
      if (response.status < 200 || response.status >= 300) {
        throw Exception('Voice room token could not be created (HTTP ${response.status}).');
      }

      final data = Map<String, dynamic>.from(response.data as Map);
      final url = data['url'] as String?;
      final token = data['token'] as String?;
      if (url == null || url.isEmpty || token == null || token.isEmpty) {
        throw Exception('The voice service returned an invalid connection token.');
      }

      pendingRoom = Room(
        roomOptions: const RoomOptions(adaptiveStream: true, dynacast: true),
      );
      await pendingRoom.connect(url, token);
      await pendingRoom.localParticipant?.setMicrophoneEnabled(true);

      if (!mounted) {
        await _releaseRoom(pendingRoom);
        pendingRoom = null;
        return;
      }

      setState(() {
        _room = pendingRoom;
        _connected = true;
        _muted = false;
      });
      // Ownership has moved to _room; do not dispose it in the error cleanup.
      pendingRoom = null;
    } catch (error) {
      if (pendingRoom != null) {
        await _releaseRoom(pendingRoom);
      }
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _releaseRoom(Room room) async {
    try {
      await room.localParticipant?.setMicrophoneEnabled(false);
    } catch (_) {
      // Continue cleanup even if the microphone track has already stopped.
    }
    try {
      await room.disconnect();
    } catch (_) {
      // A failed or already-closed connection needs no further recovery here.
    }
    try {
      await room.dispose();
    } catch (_) {
      // Dispose is best-effort during screen teardown.
    }
  }

  Future<void> _toggleMute() async {
    final room = _room;
    if (room == null) return;
    try {
      await room.localParticipant?.setMicrophoneEnabled(_muted);
      if (mounted) setState(() => _muted = !_muted);
    } catch (error) {
      if (mounted) showMessage(context, _friendlyError(error));
    }
  }

  Future<void> _leave() async {
    final room = _room;
    _room = null;
    _connected = false;
    if (room != null) await _releaseRoom(room);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    final room = _room;
    _room = null;
    if (room != null) unawaited(_releaseRoom(room));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Voice · ${widget.channelName}')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(
                width: 108,
                height: 108,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: KomnivoTheme.surfaceRaised,
                  border: Border.all(color: KomnivoTheme.accent.withValues(alpha: .55), width: 2),
                ),
                child: Icon(
                  _connected ? Icons.graphic_eq : Icons.headset_mic_outlined,
                  size: 48,
                  color: KomnivoTheme.accent,
                ),
              ),
              const SizedBox(height: 22),
              Text(
                widget.channelName,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 8),
              Text(
                _connecting
                    ? 'Requesting microphone and connecting…'
                    : _connected
                        ? 'Connected · microphone is live'
                        : _error ?? 'Not connected',
                textAlign: TextAlign.center,
                style: const TextStyle(color: KomnivoTheme.muted),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFFFF8193), fontSize: 12),
                ),
              ],
              const SizedBox(height: 28),
              if (_connecting)
                const CircularProgressIndicator()
              else if (_connected)
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  FilledButton.tonalIcon(
                    onPressed: _toggleMute,
                    icon: Icon(_muted ? Icons.mic_off : Icons.mic),
                    label: Text(_muted ? 'Unmute' : 'Mute'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _leave,
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB83D58)),
                    icon: const Icon(Icons.call_end),
                    label: const Text('Leave'),
                  ),
                ])
              else
                Column(children: [
                  FilledButton.icon(
                    onPressed: _connect,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Try again'),
                  ),
                  if (_permissionPermanentlyDenied && !kIsWeb) ...[
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: openAppSettings,
                      icon: const Icon(Icons.settings_outlined),
                      label: const Text('Open app settings'),
                    ),
                  ],
                ]),
            ]),
          ),
        ),
      ),
    );
  }
}
