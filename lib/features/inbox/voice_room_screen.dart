import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
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
  bool _connecting = true;
  bool _connected = false;
  bool _muted = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    try {
      final response = await Supabase.instance.client.functions.invoke(
        'create-livekit-token',
        body: {'channel_id': widget.channelId},
      );
      if (response.status < 200 || response.status >= 300) {
        throw Exception('Voice room token could not be created.');
      }
      final data = Map<String, dynamic>.from(response.data as Map);
      final room = Room();
      await room.connect(
        data['url'] as String,
        data['token'] as String,
        roomOptions: const RoomOptions(adaptiveStream: true, dynacast: true),
      );
      await room.localParticipant?.setMicrophoneEnabled(true);
      if (!mounted) {
        await room.disconnect();
        await room.dispose();
        return;
      }
      setState(() {
        _room = room;
        _connected = true;
        _connecting = false;
      });
    } catch (error) {
      if (mounted) setState(() { _error = error.toString(); _connecting = false; });
    }
  }

  Future<void> _toggleMute() async {
    final room = _room;
    if (room == null) return;
    try {
      await room.localParticipant?.setMicrophoneEnabled(_muted);
      if (mounted) setState(() => _muted = !_muted);
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    }
  }

  Future<void> _leave() async {
    final room = _room;
    _room = null;
    if (room != null) {
      await room.localParticipant?.setMicrophoneEnabled(false);
      await room.disconnect();
      await room.dispose();
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    final room = _room;
    if (room != null) {
      room.disconnect();
      room.dispose();
    }
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
                width: 108, height: 108,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: KomnivoTheme.surfaceRaised,
                  border: Border.all(color: KomnivoTheme.accent.withValues(alpha: .55), width: 2),
                ),
                child: Icon(_connected ? Icons.graphic_eq : Icons.headset_mic_outlined, size: 48, color: KomnivoTheme.accent),
              ),
              const SizedBox(height: 22),
              Text(widget.channelName, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
              const SizedBox(height: 8),
              Text(
                _connecting ? 'Connecting to secure voice room…' : _connected ? 'Connected · microphone is live' : _error ?? 'Not connected',
                textAlign: TextAlign.center,
                style: const TextStyle(color: KomnivoTheme.muted),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFFF8193), fontSize: 12)),
              ],
              const SizedBox(height: 28),
              if (_connecting) const CircularProgressIndicator()
              else if (_connected) Row(mainAxisAlignment: MainAxisAlignment.center, children: [
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
              ]) else FilledButton.icon(onPressed: _leave, icon: const Icon(Icons.close), label: const Text('Close')),
            ]),
          ),
        ),
      ),
    );
  }
}
