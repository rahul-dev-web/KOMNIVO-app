import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';

class LiveOpsScreen extends StatefulWidget {
  const LiveOpsScreen({super.key, required this.preview, this.onBack, this.initialMatchId});
  final bool preview;
  final VoidCallback? onBack;
  final String? initialMatchId;
  @override
  State<LiveOpsScreen> createState() => _LiveOpsScreenState();
}

class _LiveOpsScreenState extends State<LiveOpsScreen> {
  static const _methods = MethodChannel('in.komnivo.app/liveops');
  static const _events = EventChannel('in.komnivo.app/liveops-events');
  final _matchId = TextEditingController();
  StreamSubscription<dynamic>? _subscription;
  String _state = 'Idle';
  String _latestText = 'The assistant has not started observing this screen.';
  String? _sessionId;
  bool _capturing = false;
  bool _voice = true;
  String _lastObservation = '';

  @override
  void initState() {
    super.initState();
    _matchId.text = widget.initialMatchId ?? '';
  }

  Future<void> _speak(String text) async {
    if (widget.preview || !_voice || text.trim().isEmpty) return;
    try {
      await _methods.invokeMethod<bool>('speak', {'text': text});
    } on PlatformException catch (error) {
      if (mounted) {
        showMessage(context, error.message ?? 'Voice guidance is unavailable.');
      }
    }
  }

  Future<void> _stopVoice() async {
    try {
      await _methods.invokeMethod<void>('stopSpeaking');
    } catch (_) {
      // The native activity may already be detached during route teardown.
    }
  }

  Future<void> _start() async {
    if (widget.preview) {
      showMessage(context, 'Connect the Android backend to run LiveOps.');
      return;
    }

    final matchId = _matchId.text.trim();
    final uuidPattern = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    if (!uuidPattern.hasMatch(matchId)) {
      showMessage(
        context,
        'Enter a valid KOMNIVO platform Match ID before starting LiveOps.',
      );
      return;
    }

    String? sessionId;
    try {
      if (mounted) setState(() => _state = 'Authorising platform match...');
      final session = await KomnivoRepository.instance.startLiveOpsSession(
        matchId: matchId,
        deviceInfo: const <String, dynamic>{
          'platform': 'android',
          'source': 'liveops_assistant',
        },
      );
      sessionId = session['session_id']?.toString();
      if (sessionId == null || sessionId.isEmpty) {
        throw Exception('The server did not return a LiveOps session ID.');
      }
      _sessionId = sessionId;

      // Create the authorised, match-bound session before asking Android to
      // capture. The session's event and Match ID are immutable on the server.
      final captureGranted = await _methods.invokeMethod<bool>('startCapture');
      if (captureGranted != true) {
        throw Exception('Screen capture permission was not granted.');
      }

      await Supabase.instance.client
          .from('liveops_sessions')
          .update({'state': 'capturing'})
          .eq('id', sessionId)
          .eq('operator_id', Supabase.instance.client.auth.currentUser!.id);

      _subscription = _events.receiveBroadcastStream().listen(
        _onObservation,
        onError: (Object error) async {
          final activeSessionId = _sessionId;
          if (mounted) {
            setState(() {
              _capturing = false;
              _state = 'Capture error';
              _latestText = error.toString();
            });
          }
          if (activeSessionId != null) {
            try {
              await Supabase.instance.client.from('liveops_sessions').update({
                'state': 'failed',
                'ended_at': DateTime.now().toUtc().toIso8601String(),
              }).eq('id', activeSessionId);
            } catch (_) {
              // The server remains authoritative if the device has gone offline.
            }
          }
        },
      );

      if (!mounted) return;
      setState(() {
        _capturing = true;
        _state = 'Capturing · Match bound';
      });
      if (_voice) {
        await _speak('LiveOps is active for the selected KOMNIVO match.');
      }
    } catch (error) {
      if (sessionId != null) {
        try {
          await _methods.invokeMethod<void>('stopCapture');
          await Supabase.instance.client.from('liveops_sessions').update({
            'state': 'failed',
            'ended_at': DateTime.now().toUtc().toIso8601String(),
          }).eq('id', sessionId);
        } catch (_) {
          // Preserve the original failure; the database enforces session scope.
        }
      }
      if (mounted) {
        setState(() {
          _capturing = false;
          _state = 'Start failed';
          _sessionId = null;
        });
        showMessage(context, error.toString());
      }
    }
  }

  Future<void> _onObservation(dynamic event) async {
    if (event is! Map) return;
    final state = event['state']?.toString() ?? 'unknown';
    final text = event['text']?.toString() ?? '';

    if (state == 'capture_stopped' || state == 'capture_error') {
      final sessionId = _sessionId;
      final nextState = state == 'capture_stopped' ? 'stopped' : 'failed';
      if (mounted) {
        setState(() {
          _capturing = false;
          _state = state == 'capture_stopped' ? 'Capture stopped by Android' : 'Capture error';
          if (text.isNotEmpty) _latestText = text;
        });
      }
      if (sessionId != null) {
        try {
          await Supabase.instance.client.from('liveops_sessions').update({
            'state': nextState,
            'ended_at': DateTime.now().toUtc().toIso8601String(),
          }).eq('id', sessionId);
        } catch (_) {
          // State transitions remain database-enforced.
        }
      }
      await _subscription?.cancel();
      return;
    }

    if (text.trim().isEmpty || state != 'text_detected') return;
    if (mounted) setState(() { _state = 'Screen text detected · local preview'; _latestText = text; });

    // The raw OCR string stays on-device. It may include notifications or unrelated
    // private content on Android 13 full-display capture. Only classified, user-approved
    // lobby/result fields should ever be persisted to the backend.
    if (text == _lastObservation) return;
    _lastObservation = text;

    if (_voice) await _speak('Screen text detected. Please review the visible information.');
  }

  Future<void> _stop() async {
    try {
      await _methods.invokeMethod<void>('stopCapture');
      await _subscription?.cancel();
      if (_sessionId != null) {
        await Supabase.instance.client.from('liveops_sessions').update({
          'state': 'stopped',
          'ended_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', _sessionId!);
      }
      await _methods.invokeMethod<void>('stopSpeaking');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() { _capturing = false; _state = 'Stopped'; _sessionId = null; });
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    unawaited(_stopVoice());
    _matchId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      SectionTitle('LiveOps Assistant', subtitle: 'Same-phone screen observation and voice guidance', trailing: widget.onBack == null ? null : IconButton(onPressed: widget.onBack, icon: const Icon(Icons.close))),
      const SizedBox(height: 14),
      if (widget.preview) const PreviewBanner(),
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(20), border: Border.all(color: KomnivoTheme.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 44, height: 44, decoration: BoxDecoration(color: const Color(0xFF282348), borderRadius: BorderRadius.circular(14)), child: const Icon(Icons.radar, color: KomnivoTheme.accent)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Match observation', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
              const SizedBox(height: 4), Text(_state, style: TextStyle(color: _capturing ? KomnivoTheme.cyan : KomnivoTheme.muted, fontSize: 12)),
            ])),
            if (_capturing) const Icon(Icons.circle, size: 10, color: Color(0xFF73D6A2)),
          ]),
          const SizedBox(height: 16),
          TextField(
            controller: _matchId,
            enabled: !_capturing,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Platform Match ID (required)',
              hintText: 'Paste the KOMNIVO Match UUID',
              helperText: 'This is not the Free Fire Room ID.',
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _voice,
            onChanged: (value) => setState(() => _voice = value),
            title: const Text('Voice guidance'),
            subtitle: const Text('Short spoken prompts; can be muted at any time.'),
          ),
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, child: _capturing
              ? FilledButton.icon(onPressed: _stop, icon: const Icon(Icons.stop_circle_outlined), label: const Text('Stop screen observation'))
              : FilledButton.icon(onPressed: _start, icon: const Icon(Icons.play_circle_outline), label: const Text('Start LiveOps session'))),
        ]),
      ),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(20), border: Border.all(color: KomnivoTheme.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Latest on-device text preview', style: TextStyle(fontWeight: FontWeight.w900)),
          const SizedBox(height: 9),
          Text(_latestText, style: const TextStyle(color: KomnivoTheme.muted, height: 1.5)),
          const SizedBox(height: 12),
          const Text('This preview stays on the device. The OCR engine is not yet classifying lobby or result fields, so nothing is submitted as match evidence.', style: TextStyle(color: KomnivoTheme.cyan, fontSize: 11, height: 1.4)),
        ]),
      ),
      const SizedBox(height: 14),
      const _PrivacyCard(),
    ],
  );
}

class _PrivacyCard extends StatelessWidget {
  const _PrivacyCard();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: const Color(0xFF192231), borderRadius: BorderRadius.circular(18), border: Border.all(color: KomnivoTheme.line)),
    child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Icon(Icons.privacy_tip_outlined, color: KomnivoTheme.cyan), SizedBox(width: 9), Text('Privacy and control', style: TextStyle(fontWeight: FontWeight.w900))]),
      SizedBox(height: 9),
      Text('Capture starts only after your action and Android system permission. Visible text is recognised locally and remains on-device. Android 13 may capture the full display, including notifications. Stop capture before opening private apps.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 12, height: 1.5)),
    ]),
  );
}
