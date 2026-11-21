import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';

class LiveOpsScreen extends StatefulWidget {
  const LiveOpsScreen({super.key, required this.preview, this.onBack, this.initialLobbyId, this.initialMatchId});
  final bool preview;
  final VoidCallback? onBack;
  final String? initialLobbyId;
  /// Kept temporarily for legacy navigation compatibility; it is not used to start LiveOps.
  final String? initialMatchId;
  @override
  State<LiveOpsScreen> createState() => _LiveOpsScreenState();
}

class _LiveOpsScreenState extends State<LiveOpsScreen> {
  static const _methods = MethodChannel('in.komnivo.app/liveops');
  static const _events = EventChannel('in.komnivo.app/liveops-events');
  final _lobbyId = TextEditingController();
  StreamSubscription<dynamic>? _subscription;
  String? _activeEventId;
  bool _preparingEvidence = false;
  bool _uploadingEvidence = false;
  List<Map<String, dynamic>> _selectedEvidence = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _uploadedBatches = <Map<String, dynamic>>[];
  String _state = 'Idle';
  String _latestText = 'The assistant has not started observing this screen.';
  String? _sessionId;
  String? _activeMatchId;
  String? _activeLobbyCode;
  int? _activeMatchSequence;
  bool _capturing = false;
  bool _voice = true;
  String _lastObservation = '';

  @override
  void initState() {
    super.initState();
    _lobbyId.text = widget.initialLobbyId ?? '';
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

    final lobbyId = _lobbyId.text.trim();
    final uuidPattern = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    if (!uuidPattern.hasMatch(lobbyId)) {
      showMessage(context, 'Enter a valid KOMNIVO platform Lobby ID before starting LiveOps.');
      return;
    }

    String? sessionId;
    try {
      if (mounted) setState(() => _state = 'Authorising platform lobby...');
      final session = await KomnivoRepository.instance.startLiveOpsLobbySession(
        lobbyId: lobbyId,
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
      _activeMatchId = session['match_id']?.toString();
      _activeLobbyCode = session['lobby_code']?.toString();
      _activeMatchSequence = int.tryParse(session['match_sequence']?.toString() ?? '');
      _activeEventId = session['event_id']?.toString();

      // The lobby selects the LiveOps session; the server binds the first ordered
      // Match ID. Each screenshot/result batch must remain bound to that Match ID.
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
        _state = 'Capturing · Lobby bound';
      });
      await _loadEvidenceBatches(sessionId);
      if (_voice) {
        await _speak('LiveOps is active for lobby ${_activeLobbyCode ?? 'selected'} and Match ${_activeMatchSequence ?? 1}.');
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
      final nextState = state == 'capture_stopped' ? 'paused' : 'failed';
      if (mounted) {
        setState(() {
          _capturing = false;
          _state = state == 'capture_stopped' ? 'Paused · ready for screenshot upload' : 'Capture error';
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
        // Keep the session paused rather than ended so the operator can upload
        // selected screenshots and resume the same Lobby/Match binding.
        await Supabase.instance.client.from('liveops_sessions').update({
          'state': 'paused',
        }).eq('id', _sessionId!).eq('operator_id', Supabase.instance.client.auth.currentUser!.id);
      }
      await _methods.invokeMethod<void>('stopSpeaking');
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() {
        _capturing = false;
        _state = 'Paused · ready for screenshot upload';
      });
    }
  }

  Future<void> _loadEvidenceBatches(String sessionId) async {
    try {
      final rows = await Supabase.instance.client
          .from('liveops_evidence_batches')
          .select('id,match_id,screenshot_count,status,created_at')
          .eq('session_id', sessionId)
          .order('created_at', ascending: false)
          .limit(12);
      if (!mounted) return;
      setState(() {
        _uploadedBatches = List<Map<String, dynamic>>.from(rows);
      });
    } catch (_) {
      // The current session remains usable even if evidence history is unavailable.
    }
  }

  Future<void> _chooseEvidenceScreenshots() async {
    if (widget.preview || _sessionId == null || _activeMatchId == null || _activeEventId == null) {
      showMessage(context, 'Start a LiveOps Lobby session before selecting screenshots.');
      return;
    }
    if (_capturing) {
      showMessage(context, 'Pause screen observation before opening the gallery. This prevents private apps or notifications from being captured.');
      return;
    }
    if (_preparingEvidence || _uploadingEvidence) return;

    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) return;
      if (picked.files.length > 8) {
        showMessage(context, 'A single evidence batch supports 1 to 8 screenshots. Select at most eight.');
        return;
      }

      setState(() {
        _preparingEvidence = true;
        _selectedEvidence = <Map<String, dynamic>>[];
      });
      final prepared = <Map<String, dynamic>>[];
      final seenHashes = <String>{};
      for (final file in picked.files) {
        final bytes = file.bytes;
        final extension = (file.extension ?? file.name.split('.').last).toLowerCase();
        final contentType = switch (extension) {
          'jpg' || 'jpeg' => 'image/jpeg',
          'png' => 'image/png',
          'webp' => 'image/webp',
          _ => '',
        };
        if (bytes == null || bytes.isEmpty) {
          throw Exception('Could not read ${file.name}. Re-select this screenshot.');
        }
        if (contentType.isEmpty) {
          throw Exception('${file.name} is not a supported JPG, PNG or WebP screenshot.');
        }
        if (bytes.length > 10 * 1024 * 1024) {
          throw Exception('${file.name} exceeds the 10 MiB per-image limit.');
        }

        final scan = await _methods.invokeMapMethod<String, dynamic>(
          'recognizeEvidenceImage',
          <String, dynamic>{'bytes': bytes, 'extension': extension},
        );
        final sha256 = scan?['sha256']?.toString() ?? '';
        if (!RegExp(r'^[0-9a-f]{64}
    _subscription?.cancel();
    unawaited(_stopVoice());
    _lobbyId.dispose();
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
              const Text('Lobby observation', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
              const SizedBox(height: 4), Text(_state, style: TextStyle(color: _capturing ? KomnivoTheme.cyan : KomnivoTheme.muted, fontSize: 12)),
            ])),
            if (_capturing) const Icon(Icons.circle, size: 10, color: Color(0xFF73D6A2)),
          ]),
          const SizedBox(height: 16),
          TextField(
            controller: _lobbyId,
            enabled: !_capturing,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Platform Lobby ID (required)',
              hintText: 'Paste the KOMNIVO Lobby UUID',
              helperText: 'Lobby ID starts LiveOps. Match ID is returned separately for scoring and results.',
            ),
          ),
          if (_activeMatchId != null) ...[
            const SizedBox(height: 8),
            Text('Active Lobby: ${_activeLobbyCode ?? '—'}', style: const TextStyle(color: KomnivoTheme.cyan, fontSize: 12, fontWeight: FontWeight.w800)),
            Text('Current Match ID: $_activeMatchId', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
            Text('Match sequence: ${_activeMatchSequence ?? 1}', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
          ],
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
              ? FilledButton.icon(onPressed: _stop, icon: const Icon(Icons.pause_circle_outline), label: const Text('Pause observation for evidence upload'))
              : FilledButton.icon(onPressed: _start, icon: const Icon(Icons.play_circle_outline), label: Text(_sessionId == null ? 'Start LiveOps session' : 'Resume LiveOps observation'))),
        ]),
      ),
      if (_sessionId != null) ...[
        const SizedBox(height: 14),
        _EvidenceUploadCard(
          selected: _selectedEvidence,
          batches: _uploadedBatches,
          preparing: _preparingEvidence,
          uploading: _uploadingEvidence,
          capturing: _capturing,
          onPause: _stop,
          onChoose: _chooseEvidenceScreenshots,
          onUpload: _uploadEvidenceScreenshots,
        ),
      ],
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(20), border: Border.all(color: KomnivoTheme.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Latest on-device text preview', style: TextStyle(fontWeight: FontWeight.w900)),
          const SizedBox(height: 9),
          Text(_latestText, style: const TextStyle(color: KomnivoTheme.muted, height: 1.5)),
          const SizedBox(height: 12),
          const Text('Continuous screen text remains on this device. Only screenshots you explicitly select and confirm are uploaded. Their OCR text is saved as provisional evidence and still needs team/placement review; it is not an official result.', style: TextStyle(color: KomnivoTheme.cyan, fontSize: 11, height: 1.4)),
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
      Text('Screen observation starts only after your action and Android permission. Continuous OCR remains on-device. To upload evidence, pause observation, select 1–8 standing screenshots, inspect the local OCR preview and confirm the upload. Hide notifications and unrelated private content before selecting screenshots.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 12, height: 1.5)),
    ]),
  );
}
).hasMatch(sha256)) {
          throw Exception('On-device screenshot verification failed for ${file.name}.');
        }
        if (!seenHashes.add(sha256)) {
          throw Exception('${file.name} is an exact duplicate of another selected screenshot.');
        }
        prepared.add(<String, dynamic>{
          'name': file.name,
          'extension': extension,
          'content_type': contentType,
          'file_size': bytes.length,
          'bytes': bytes,
          'sha256': sha256,
          'ocr_text': scan?['ocr_text']?.toString() ?? '',
        });
      }
      if (!mounted) return;
      setState(() => _selectedEvidence = prepared);
    } catch (error) {
      if (mounted) showMessage(context, error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _preparingEvidence = false);
    }
  }

  Future<void> _uploadEvidenceScreenshots() async {
    if (widget.preview || _capturing || _uploadingEvidence || _selectedEvidence.isEmpty) return;
    final sessionId = _sessionId;
    final lobbyId = _lobbyId.text.trim();
    final matchId = _activeMatchId;
    final eventId = _activeEventId;
    final user = Supabase.instance.client.auth.currentUser;
    if (sessionId == null || lobbyId.isEmpty || matchId == null || eventId == null || user == null) {
      showMessage(context, 'The active LiveOps session could not be verified. Start the Lobby session again.');
      return;
    }

    final client = Supabase.instance.client;
    final uploadedPaths = <String>[];
    final items = <Map<String, dynamic>>[];
    final requestId = 'evidence_${DateTime.now().microsecondsSinceEpoch}_${math.Random.secure().nextInt(1 << 24)}';
    setState(() => _uploadingEvidence = true);
    try {
      for (var index = 0; index < _selectedEvidence.length; index++) {
        final item = _selectedEvidence[index];
        final suffix = math.Random.secure().nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
        final path = '${user.id}/${eventId}/${matchId}/${sessionId}/${requestId}_${index + 1}_${suffix}.${item['extension']}';
        await client.storage.from('match-evidence').uploadBinary(
          path,
          item['bytes'] as Uint8List,
          fileOptions: FileOptions(
            contentType: item['content_type']?.toString(),
            upsert: false,
          ),
        );
        uploadedPaths.add(path);
        items.add(<String, dynamic>{
          'path': path,
          'content_type': item['content_type'],
          'file_size': item['file_size'],
          'sha256': item['sha256'],
          'ocr_text': item['ocr_text'],
          'observed_at': DateTime.now().toUtc().toIso8601String(),
        });
      }

      final batch = await KomnivoRepository.instance.registerLiveOpsEvidenceBatch(
        sessionId: sessionId,
        lobbyId: lobbyId,
        matchId: matchId,
        idempotencyKey: requestId,
        items: items,
      );
      await _loadEvidenceBatches(sessionId);
      if (!mounted) return;
      setState(() => _selectedEvidence = <Map<String, dynamic>>[]);
      final count = batch['screenshot_count']?.toString() ?? items.length.toString();
      showMessage(context, '$count screenshots registered for Match ${_activeMatchSequence ?? 1}. OCR is provisional; team rows still need review.');
    } catch (error) {
      if (uploadedPaths.isNotEmpty) {
        try {
          await client.storage.from('match-evidence').remove(uploadedPaths);
        } catch (_) {
          // The server blocks deletion of any object already registered to a capture.
        }
      }
      if (mounted) showMessage(context, 'Screenshot upload failed: ${error.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _uploadingEvidence = false);
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    unawaited(_stopVoice());
    _lobbyId.dispose();
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
              const Text('Lobby observation', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
              const SizedBox(height: 4), Text(_state, style: TextStyle(color: _capturing ? KomnivoTheme.cyan : KomnivoTheme.muted, fontSize: 12)),
            ])),
            if (_capturing) const Icon(Icons.circle, size: 10, color: Color(0xFF73D6A2)),
          ]),
          const SizedBox(height: 16),
          TextField(
            controller: _lobbyId,
            enabled: !_capturing,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Platform Lobby ID (required)',
              hintText: 'Paste the KOMNIVO Lobby UUID',
              helperText: 'Lobby ID starts LiveOps. Match ID is returned separately for scoring and results.',
            ),
          ),
          if (_activeMatchId != null) ...[
            const SizedBox(height: 8),
            Text('Active Lobby: ${_activeLobbyCode ?? '—'}', style: const TextStyle(color: KomnivoTheme.cyan, fontSize: 12, fontWeight: FontWeight.w800)),
            Text('Current Match ID: $_activeMatchId', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
            Text('Match sequence: ${_activeMatchSequence ?? 1}', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11)),
          ],
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
          const Text('This preview stays on the device. Lobby-bound session startup and the first Match ID are connected. Screenshot batches, OCR classification, duplicate reconciliation and Next-to-next-Match progression are still pending; nothing is submitted as match evidence yet.', style: TextStyle(color: KomnivoTheme.cyan, fontSize: 11, height: 1.4)),
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

class _EvidenceUploadCard extends StatelessWidget {
  const _EvidenceUploadCard({
    required this.selected,
    required this.batches,
    required this.preparing,
    required this.uploading,
    required this.capturing,
    required this.onPause,
    required this.onChoose,
    required this.onUpload,
  });

  final List<Map<String, dynamic>> selected;
  final List<Map<String, dynamic>> batches;
  final bool preparing;
  final bool uploading;
  final bool capturing;
  final VoidCallback onPause;
  final VoidCallback onChoose;
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: KomnivoTheme.surface,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: KomnivoTheme.line),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [
        Icon(Icons.photo_library_outlined, color: KomnivoTheme.cyan),
        SizedBox(width: 9),
        Expanded(child: Text('Standing screenshot evidence', style: TextStyle(fontWeight: FontWeight.w900))),
      ]),
      const SizedBox(height: 7),
      const Text(
        'Select 1–8 screenshots for the active Match ID. JPG, PNG and WebP are supported, up to 10 MiB each. OCR runs on-device before upload.',
        style: TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.45),
      ),
      const SizedBox(height: 11),
      if (capturing)
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: uploading ? null : onPause,
            icon: const Icon(Icons.pause_circle_outline),
            label: const Text('Pause observation before opening gallery'),
          ),
        )
      else
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: preparing || uploading ? null : onChoose,
            icon: preparing
                ? const SizedBox(width: 16,height: 16,child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.add_photo_alternate_outlined),
            label: Text(preparing ? 'Reading screenshots on-device…' : 'Choose screenshots'),
          ),
        ),
      if (selected.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text('${selected.length} selected · OCR preview', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
        const SizedBox(height: 5),
        ...selected.asMap().entries.map((entry) {
          final item = entry.value;
          final ocr = item['ocr_text']?.toString() ?? '';
          return Container(
            margin: const EdgeInsets.only(bottom: 7),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF191E2C),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${entry.key + 1}. ${item['name']}', style: const TextStyle(fontWeight: FontWeight.w800,fontSize: 11)),
              const SizedBox(height: 3),
              Text(
                '${((item['file_size'] as int? ?? 0) / 1024).toStringAsFixed(0)} KB · SHA-256 checked',
                style: const TextStyle(color: KomnivoTheme.muted,fontSize: 10),
              ),
              const SizedBox(height: 5),
              Text(
                ocr.isEmpty ? 'No text detected. The screenshot will still be attached as evidence.' : ocr,
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: KomnivoTheme.muted,fontSize: 10,height: 1.4),
              ),
            ]),
          );
        }),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: uploading || capturing ? null : onUpload,
            icon: uploading
                ? const SizedBox(width: 16,height: 16,child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.cloud_upload_outlined),
            label: Text(uploading ? 'Uploading evidence…' : 'Confirm and upload ${selected.length} screenshots'),
          ),
        ),
      ],
      if (batches.isNotEmpty) ...[
        const SizedBox(height: 13),
        const Text('Previously uploaded batches', style: TextStyle(fontWeight: FontWeight.w800,fontSize: 11)),
        const SizedBox(height: 4),
        ...batches.take(5).map((batch) => Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Row(children: [
            const Icon(Icons.verified_outlined,size:14,color:KomnivoTheme.cyan),
            const SizedBox(width:7),
            Expanded(child: Text(
              '${batch['screenshot_count'] ?? 0} screenshots · ${batch['status'] ?? 'uploaded'}',
              style: const TextStyle(color:KomnivoTheme.muted,fontSize:10),
            )),
            Text(
              DateTime.tryParse(batch['created_at']?.toString() ?? '')?.toLocal().toString().split('.').first ?? '',
              style: const TextStyle(color:KomnivoTheme.muted,fontSize:9),
            ),
          ]),
        )),
      ],
    ]),
  );
}

