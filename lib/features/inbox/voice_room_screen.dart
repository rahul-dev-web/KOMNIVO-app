import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';
import '../profile/member_profile_screen.dart';

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
  CancelListenFunc? _roomEventsSubscription;
  List<Map<String, dynamic>> _participants = <Map<String, dynamic>>[];
  Set<String> _activeSpeakerIds = <String>{};

  @override
  void initState() {
    super.initState();
    // Joining is an explicit user action. The microphone permission prompt
    // must never appear simply because the user opened a channel page.
  }

  String _friendlyError(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '').trim();
    if (message.isEmpty) return 'Could not join this voice room. Please try again.';
    return message;
  }

  void _syncRoomParticipants(Room room, {bool notify = true}) {
    final participants = <Map<String, dynamic>>[];
    final local = room.localParticipant;
    if (local != null) {
      participants.add({
        'identity': local.identity,
        'name': local.name,
        'isLocal': true,
        'isSpeaking': _activeSpeakerIds.contains(local.identity),
      });
    }
    for (final participant in room.remoteParticipants.values) {
      participants.add({
        'identity': participant.identity,
        'name': participant.name,
        'isLocal': false,
        'isSpeaking': _activeSpeakerIds.contains(participant.identity),
      });
    }
    participants.sort((a, b) {
      if (a['isLocal'] == true) return -1;
      if (b['isLocal'] == true) return 1;
      return (a['name']?.toString() ?? '').toLowerCase()
          .compareTo((b['name']?.toString() ?? '').toLowerCase());
    });
    if (notify && mounted) {
      setState(() => _participants = participants);
    } else {
      _participants = participants;
    }
  }

  void _watchRoom(Room room) {
    _roomEventsSubscription?.call();
    _roomEventsSubscription = room.events.listen((event) {
      if (event is ActiveSpeakersChangedEvent) {
        _activeSpeakerIds = event.speakers.map((participant) => participant.identity).toSet();
        _syncRoomParticipants(room);
      } else if (event is ParticipantConnectedEvent || event is ParticipantDisconnectedEvent) {
        _syncRoomParticipants(room);
      }
    });
    _syncRoomParticipants(room, notify: false);
  }

  String _participantInitials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((part) => part.isNotEmpty).toList();
    if (parts.isEmpty) return 'K';
    return parts.take(2).map((part) => part.substring(0, 1).toUpperCase()).join();
  }

  Future<void> _openParticipantProfile(String identity) async {
    if (identity.isEmpty || !mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => MemberProfileScreen(userId: identity)),
    );
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
      _watchRoom(pendingRoom);

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
    await _roomEventsSubscription?.call();
    _roomEventsSubscription = null;
    _participants = <Map<String, dynamic>>[];
    if (room != null) await _releaseRoom(room);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    final room = _room;
    _room = null;
    final subscription = _roomEventsSubscription;
    _roomEventsSubscription = null;
    if (subscription != null) unawaited(subscription());
    if (room != null) unawaited(_releaseRoom(room));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final joinedCount = _participants.length;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('Voice · ${widget.channelName}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900)),
          const Text('LIVE VOICE ROOM', style: TextStyle(color: KomnivoTheme.muted, fontSize: 8, fontWeight: FontWeight.w800, letterSpacing: 1)),
        ]),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [KomnivoTheme.background, KomnivoTheme.surface.withValues(alpha: .55), KomnivoTheme.background],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              Container(
                padding: const EdgeInsets.all(19),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [KomnivoTheme.surfaceRaised, const Color(0xFF25213D)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: KomnivoTheme.accent.withValues(alpha: .36)),
                ),
                child: Row(children: [
                  Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      color: KomnivoTheme.accent.withValues(alpha: .18),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Icon(_connected ? Icons.graphic_eq_rounded : Icons.headset_mic_rounded,
                      size: 30, color: KomnivoTheme.cyan),
                  ),
                  const SizedBox(width: 14),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(widget.channelName, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 4),
                    Text(
                      _connecting
                          ? 'Connecting to voice…'
                          : _connected
                              ? 'You are connected · microphone ${_muted ? 'muted' : 'live'}'
                              : _error ?? 'Join the room to talk with your community.',
                      style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.35),
                    ),
                  ])),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                    decoration: BoxDecoration(
                      color: _connected ? KomnivoTheme.cyan.withValues(alpha: .13) : KomnivoTheme.surface,
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: _connected ? KomnivoTheme.cyan.withValues(alpha: .45) : KomnivoTheme.line),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(width: 6, height: 6, decoration: BoxDecoration(
                        color: _connected ? KomnivoTheme.cyan : KomnivoTheme.muted,
                        shape: BoxShape.circle,
                      )),
                      const SizedBox(width: 5),
                      Text(_connected ? 'LIVE' : 'IDLE',
                        style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900,
                          color: _connected ? KomnivoTheme.cyan : KomnivoTheme.muted)),
                    ]),
                  ),
                ]),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFB83D58).withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFB83D58).withValues(alpha: .4)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.error_outline, color: Color(0xFFFF8193), size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_error!, style: const TextStyle(color: Color(0xFFFFB2BE), fontSize: 11))),
                  ]),
                ),
              ],
              const SizedBox(height: 22),
              Row(children: [
                const Expanded(child: Text('IN THE ROOM', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11, letterSpacing: 1))),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(color: KomnivoTheme.surfaceRaised, borderRadius: BorderRadius.circular(20)),
                  child: Text('${joinedCount} ${joinedCount == 1 ? 'member' : 'members'}',
                    style: const TextStyle(color: KomnivoTheme.cyan, fontSize: 10, fontWeight: FontWeight.w900)),
                ),
              ]),
              const SizedBox(height: 10),
              if (!_connected)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
                  decoration: BoxDecoration(
                    color: KomnivoTheme.surface.withValues(alpha: .7),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: KomnivoTheme.line),
                  ),
                  child: Column(children: [
                    const Icon(Icons.hearing_outlined, size: 34, color: KomnivoTheme.muted),
                    const SizedBox(height: 9),
                    const Text('Join to see who is here', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    const Text('Members appear here as soon as you connect. New arrivals and departures update live.',
                      textAlign: TextAlign.center, style: TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.4)),
                  ]),
                )
              else if (_participants.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('Waiting for members…', style: TextStyle(color: KomnivoTheme.muted))),
                )
              else
                Wrap(
                  spacing: 9,
                  runSpacing: 9,
                  children: _participants.map((participant) {
                    final identity = participant['identity']?.toString() ?? '';
                    final name = participant['name']?.toString().trim().isNotEmpty == true
                        ? participant['name'].toString().trim()
                        : 'KOMNIVO member';
                    final isLocal = participant['isLocal'] == true;
                    final speaking = participant['isSpeaking'] == true;
                    return InkWell(
                      onTap: () => _openParticipantProfile(identity),
                      borderRadius: BorderRadius.circular(17),
                      child: Container(
                        width: 148,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
                        decoration: BoxDecoration(
                          color: KomnivoTheme.surface,
                          borderRadius: BorderRadius.circular(17),
                          border: Border.all(
                            color: speaking ? KomnivoTheme.cyan : KomnivoTheme.line,
                            width: speaking ? 1.5 : 1,
                          ),
                          boxShadow: speaking ? [
                            BoxShadow(color: KomnivoTheme.cyan.withValues(alpha: .12), blurRadius: 14, spreadRadius: 1),
                          ] : null,
                        ),
                        child: Column(children: [
                          Stack(alignment: Alignment.bottomRight, children: [
                            CircleAvatar(
                              radius: 25,
                              backgroundColor: speaking ? KomnivoTheme.cyan.withValues(alpha: .18) : KomnivoTheme.surfaceRaised,
                              child: Text(_participantInitials(name),
                                style: TextStyle(color: speaking ? KomnivoTheme.cyan : null, fontWeight: FontWeight.w900, fontSize: 16)),
                            ),
                            Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: speaking ? KomnivoTheme.cyan : KomnivoTheme.muted,
                                shape: BoxShape.circle,
                                border: Border.all(color: KomnivoTheme.surface, width: 2),
                              ),
                            ),
                          ]),
                          const SizedBox(height: 9),
                          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900)),
                          const SizedBox(height: 4),
                          Text(
                            isLocal ? 'YOU' : speaking ? 'SPEAKING NOW' : 'IN VOICE',
                            style: TextStyle(fontSize: 8, letterSpacing: .7, fontWeight: FontWeight.w900,
                              color: speaking ? KomnivoTheme.cyan : KomnivoTheme.muted),
                          ),
                        ]),
                      ),
                    );
                  }).toList(),
                ),
              const SizedBox(height: 22),
              if (_connecting)
                const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
              else if (_connected)
                Row(children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _toggleMute,
                      icon: Icon(_muted ? Icons.mic_off_rounded : Icons.mic_rounded),
                      label: Text(_muted ? 'Unmute microphone' : 'Mute microphone'),
                      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 15)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: _leave,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFB83D58),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 15),
                    ),
                    icon: const Icon(Icons.call_end_rounded),
                    label: const Text('Leave'),
                  ),
                ])
              else
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _connect,
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                    icon: const Icon(Icons.headset_mic_rounded),
                    label: Text(_error == null ? 'Join voice room' : 'Try again'),
                  ),
                ),
              if (_permissionPermanentlyDenied && !kIsWeb) ...[
                const SizedBox(height: 8),
                Center(child: TextButton.icon(
                  onPressed: openAppSettings,
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('Open app settings'),
                )),
              ],
              const SizedBox(height: 8),
              const Text(
                'Tap a member card to open their profile. Your microphone only becomes active after you join.',
                textAlign: TextAlign.center,
                style: TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
