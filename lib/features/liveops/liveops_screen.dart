import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';
import 'liveops_evidence_panel.dart';
import 'liveops_room_setup_classifier.dart';
import 'liveops_match_screen_classifier.dart';

enum _LiveOpsVisualState {
  idle,
  permissionPending,
  unknown,
  roomSetup,
  lobby,
  matchInProgress,
  resultScreen,
  pausedCaptureStopped,
  error,
}

extension on _LiveOpsVisualState {
  String get label => switch (this) {
    _LiveOpsVisualState.idle => 'Idle',
    _LiveOpsVisualState.permissionPending => 'Permission pending',
    _LiveOpsVisualState.unknown => 'Unknown / not classified',
    _LiveOpsVisualState.roomSetup => 'Room setup',
    _LiveOpsVisualState.lobby => 'Lobby',
    _LiveOpsVisualState.matchInProgress => 'Match in progress',
    _LiveOpsVisualState.resultScreen => 'Result screen',
    _LiveOpsVisualState.pausedCaptureStopped => 'Paused / capture stopped',
    _LiveOpsVisualState.error => 'Error',
  };
}

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
  String _state = 'Idle';
  String _latestText = 'The assistant has not started observing this screen.';
  String? _sessionId;
  String? _activeEventId;
  String? _activeMatchId;
  String? _activeLobbyCode;
  int? _activeMatchSequence;
  bool _capturing = false;
  bool _matchResultsSubmitted = false;
  bool _matchEvidenceSkipped = false;
  String _matchEvidenceSkipReason = '';
  bool _voice = true;
  _LiveOpsVisualState? _lastGuidanceState;
  DateTime? _lastGuidanceAt;
  final Map<_LiveOpsVisualState, DateTime> _lastGuidanceAtByState =
      <_LiveOpsVisualState, DateTime>{};
  static const Duration _statePromptCooldown = Duration(seconds: 30);
  static const Duration _minimumPromptInterval = Duration(seconds: 6);
  _LiveOpsVisualState _visualState = _LiveOpsVisualState.idle;
  DateTime? _stateObservedAt;
  double? _stateConfidence;
  String _stateSource = 'No observation yet';
  final LiveOpsStableScreenObserver _matchScreenObserver =
      LiveOpsStableScreenObserver();

  String get _stateConfidenceLabel {
    if (_stateConfidence == null) return 'Not classified';
    if (_stateConfidence! >= 1.0) {
      return _visualState == _LiveOpsVisualState.roomSetup
          ? 'High · strict 3/3 OCR markers'
          : 'High · stable 3/3 OCR observations';
    }
    return '${(_stateConfidence! * 100).toStringAsFixed(0)}%';
  }

  DateTime _readObservationTime(dynamic value) {
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    }
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed;
    }
    return DateTime.now();
  }

  void _setVisualState(
    _LiveOpsVisualState state, {
    DateTime? observedAt,
    double? confidence,
    required String source,
  }) {
    _visualState = state;
    _stateObservedAt = observedAt ?? DateTime.now();
    _stateConfidence = confidence;
    _stateSource = source;
  }

  String get _selectedLobbyId => widget.initialLobbyId?.trim() ?? '';
  bool get _hasSelectedLobbyContext => _selectedLobbyId.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _lobbyId.text = _selectedLobbyId;
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

  Future<void> _speakGuidanceForState(_LiveOpsVisualState state) async {
    final String? prompt = switch (state) {
      _LiveOpsVisualState.idle => null,
      _LiveOpsVisualState.permissionPending => null,
      _LiveOpsVisualState.roomSetup =>
        'Room setup detected. Enter the room details manually; I will not create the room.',
      _LiveOpsVisualState.lobby =>
        'Lobby detected. Review the visible players against the locked roster.',
      _LiveOpsVisualState.matchInProgress =>
        'Match is in progress. Focus on the game; I will stay quiet unless the screen changes.',
      _LiveOpsVisualState.resultScreen =>
        'Result screen detected. Review the visible summary manually; no score has been submitted.',
      _LiveOpsVisualState.unknown =>
        'Screen not recognised. Continue manually; I will stay quiet until a supported screen appears.',
      _LiveOpsVisualState.pausedCaptureStopped =>
        'Screen capture stopped. Restart LiveOps when you are ready.',
      _LiveOpsVisualState.error =>
        'Screen capture failed. Check permission and retry when ready.',
    };
    if (prompt == null || widget.preview || !_voice) return;
    if (_lastGuidanceState == state) return;

    final now = DateTime.now();
    final stateLastPrompt = _lastGuidanceAtByState[state];
    if (stateLastPrompt != null &&
        now.difference(stateLastPrompt) < _statePromptCooldown) {
      return;
    }
    final lastPrompt = _lastGuidanceAt;
    if (lastPrompt != null &&
        now.difference(lastPrompt) < _minimumPromptInterval) {
      return;
    }

    // Record only prompts that will actually be sent. If the global gap blocks
    // this state, the next observation may retry after the cooldown.
    _lastGuidanceState = state;
    _lastGuidanceAt = now;
    _lastGuidanceAtByState[state] = now;
    await _speak(prompt);
  }

  Future<void> _stopVoice() async {
    try {
      await _methods.invokeMethod<void>('stopSpeaking');
    } catch (_) {
      // The native activity may already be detached during route teardown.
    }
  }

  Future<void> _start() async {
    if (_matchEvidenceSkipped) {
      showMessage(context, 'This Match evidence step was skipped. Use Next Match to continue the Lobby.');
      return;
    }
    if (_matchResultsSubmitted) {
      showMessage(context, 'This Match already has official result rows. Use Next Match after submission; do not capture or edit it again.');
      return;
    }
    if (widget.preview) {
      showMessage(context, 'Connect the Android backend to run LiveOps.');
      return;
    }

    // Event Operations supplies the selected Lobby ID. Treat that route
    // context as immutable and never let an editable field redirect the host
    // to a different Lobby. Manual entry is only a recovery path when this
    // screen was opened without a selected Lobby.
    final lobbyId = _hasSelectedLobbyContext
        ? _selectedLobbyId
        : _lobbyId.text.trim();
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
      _activeEventId = session['event_id']?.toString();
      _activeMatchId = session['match_id']?.toString();
      _activeLobbyCode = session['lobby_code']?.toString();
      _activeMatchSequence = int.tryParse(session['match_sequence']?.toString() ?? '');

      // A session may be resumed after an app restart. Never restart capture when
      // official rows already exist for this Match ID.
      final submittedRows = await Supabase.instance.client
          .from('match_results')
          .select('id')
          .eq('match_id', _activeMatchId!)
          .limit(1);
      if (submittedRows.isNotEmpty) {
        if (mounted) setState(() {
          _matchResultsSubmitted = true;
          _matchEvidenceSkipped = false;
          _matchEvidenceSkipReason = '';
          _capturing = false;
          _state = 'Official result submitted · awaiting reviewer';
        });
        showMessage(context, 'Official result rows already exist for this Match. Use the Next Match action below when ready.');
        return;
      }
      final skipState = await Supabase.instance.client
          .from('liveops_sessions')
          .select('evidence_skipped_at,evidence_skip_reason')
          .eq('id', sessionId)
          .maybeSingle();
      if (skipState?['evidence_skipped_at'] != null) {
        final reason = skipState?['evidence_skip_reason']?.toString() ?? '';
        if (mounted) setState(() {
          _matchResultsSubmitted = false;
          _matchEvidenceSkipped = true;
          _matchEvidenceSkipReason = reason;
          _capturing = false;
          _state = 'Evidence step skipped · Next Match available';
        });
        showMessage(context, 'This Match evidence step was already skipped. No score was created; continue with Next Match.');
        return;
      }
      _matchResultsSubmitted = false;
      _matchEvidenceSkipped = false;
      _matchEvidenceSkipReason = '';

      // The Lobby selects or resumes its current ordered Match ID. Each evidence
      // batch and candidate remains bound to that exact Match ID.
      if (mounted) {
        setState(() {
          _setVisualState(
            _LiveOpsVisualState.permissionPending,
            source: 'Android MediaProjection consent',
          );
          _state = 'Waiting for Android screen-capture permission...';
        });
      }
      final captureGranted = await _methods.invokeMethod<bool>('startCapture');
      if (captureGranted != true) {
        throw Exception('Screen capture permission was not granted.');
      }

      await Supabase.instance.client
          .from('liveops_sessions')
          .update({'state': 'capturing'})
          .eq('id', sessionId)
          .eq('operator_id', Supabase.instance.client.auth.currentUser!.id);

      _lastGuidanceState = null;
      _lastGuidanceAt = null;
      _lastGuidanceAtByState.clear();
      _subscription = _events.receiveBroadcastStream().listen(
        _onObservation,
        onError: (Object error) async {
          final activeSessionId = _sessionId;
          if (mounted) {
            setState(() {
              _capturing = false;
              _setVisualState(
                _LiveOpsVisualState.error,
                source: 'Native EventChannel error',
              );
              _state = 'Capture error';
              _latestText = error.toString();
            });
          }
          await _speakGuidanceForState(_LiveOpsVisualState.error);
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
      _matchScreenObserver.reset();
      setState(() {
        _capturing = true;
        _matchResultsSubmitted = false;
        _setVisualState(
          _LiveOpsVisualState.unknown,
          source: 'Capture active; awaiting supported screen observations',
        );
        _state = 'Capturing · screen state not classified';
      });
      if (_voice) {
        _lastGuidanceAt = DateTime.now();
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
          _setVisualState(
            _LiveOpsVisualState.error,
            source: 'LiveOps start failure',
          );
          _state = 'Start failed';
          _sessionId = null;
        });
        showMessage(context, error.toString());
      }
      await _speakGuidanceForState(_LiveOpsVisualState.error);
    }
  }
  Future<void> _onObservation(dynamic event) async {
    if (event is! Map) return;
    final state = event['state']?.toString() ?? 'unknown';
    final text = event['text']?.toString() ?? '';
    final observedAt = _readObservationTime(event['observed_at']);

    if (state == 'capture_stopped' || state == 'capture_error') {
      final sessionId = _sessionId;
      final nextState = state == 'capture_stopped' ? 'paused' : 'failed';
      if (mounted) {
        setState(() {
          _capturing = false;
          _setVisualState(
            state == 'capture_stopped'
                ? _LiveOpsVisualState.pausedCaptureStopped
                : _LiveOpsVisualState.error,
            observedAt: observedAt,
            source: 'Android MediaProjection lifecycle',
          );
          _state = state == 'capture_stopped'
              ? 'Paused · ready for screenshot upload'
              : 'Capture error';
          if (text.isNotEmpty) _latestText = text;
        });
      }
      await _speakGuidanceForState(
        state == 'capture_stopped'
            ? _LiveOpsVisualState.pausedCaptureStopped
            : _LiveOpsVisualState.error,
      );
      if (sessionId != null) {
        try {
          await Supabase.instance.client.from('liveops_sessions').update({
            'state': nextState,
            if (nextState == 'failed') 'ended_at': DateTime.now().toUtc().toIso8601String(),
          }).eq('id', sessionId);
        } catch (_) {
          // State transitions remain database-enforced.
        }
      }
      await _subscription?.cancel();
      return;
    }

    if (state == 'capturing') {
      if (mounted) {
        setState(() {
          _setVisualState(
            _LiveOpsVisualState.unknown,
            observedAt: observedAt,
            source: 'Native capture active; no screen classification supplied',
          );
          _state = 'Capturing · screen state not classified';
          if (text.isNotEmpty) _latestText = text;
        });
      }
      return;
    }

    if (state == 'ocr_error') {
      if (mounted) {
        setState(() {
          _setVisualState(
            _LiveOpsVisualState.unknown,
            observedAt: observedAt,
            source: 'On-device OCR warning',
          );
          _state = 'Capture active · OCR warning';
          if (text.isNotEmpty) _latestText = text;
        });
      }
      return;
    }

    if (state == 'text_detected') {
      final roomSetup = LiveOpsRoomSetupClassifier.classify(text);
      if (roomSetup.isRoomSetup) {
        _matchScreenObserver.reset();
        if (mounted) {
          setState(() {
            _setVisualState(
              _LiveOpsVisualState.roomSetup,
              observedAt: observedAt,
              confidence: 1.0,
              source: 'On-device OCR · strict English Room Name + Password + Confirm signature',
            );
            _state = 'Room Setup detected · review the visible fields';
            _latestText = text;
          });
        }
        await _speakGuidanceForState(_LiveOpsVisualState.roomSetup);
      } else {
        final classification = LiveOpsMatchScreenClassifier.classify(text);
        final stableKind = _matchScreenObserver.observe(
          classification.kind,
          observedAt,
        );
        final confirmedLobby = stableKind == LiveOpsMatchScreenKind.lobby;
        final confirmedGameplay =
            stableKind == LiveOpsMatchScreenKind.matchInProgress;
        final confirmedResult =
            stableKind == LiveOpsMatchScreenKind.resultScreen;
        final retainingPriorState = stableKind != LiveOpsMatchScreenKind.unknown &&
            classification.kind != stableKind;
        final _LiveOpsVisualState nextVisualState;
        final String source;
        final String nextStatus;
        if (confirmedLobby) {
          nextVisualState = _LiveOpsVisualState.lobby;
          source = retainingPriorState
              ? 'On-device OCR · retaining confirmed Lobby while candidate stabilises (${_matchScreenObserver.pendingCount}/3)'
              : 'On-device OCR · stable 3/3 observations · strict custom-room team/invite/start signature';
          nextStatus = retainingPriorState
              ? 'Lobby retained · checking screen transition'
              : 'Custom-room Lobby detected · roster review required';
        } else if (confirmedGameplay) {
          nextVisualState = _LiveOpsVisualState.matchInProgress;
          source = retainingPriorState
              ? 'On-device OCR · retaining confirmed Gameplay while candidate stabilises (${_matchScreenObserver.pendingCount}/3)'
              : 'On-device OCR · stable 3/3 observations · strict BR Safe Zone + numeric HP/EP HUD signature';
          nextStatus = retainingPriorState
              ? 'Match in progress · checking screen transition'
              : 'Match in progress · generic prompts suppressed';
        } else if (confirmedResult) {
          nextVisualState = _LiveOpsVisualState.resultScreen;
          source = retainingPriorState
              ? 'On-device OCR · retaining confirmed Result Screen while candidate stabilises (${_matchScreenObserver.pendingCount}/3)'
              : 'On-device OCR · stable 3/3 observations · BOOYAH/DEFEAT + NAME + two result-stat headers';
          nextStatus = retainingPriorState
              ? 'Result Screen retained · checking screen transition'
              : 'Result Screen detected · review manually; no score extracted';
        } else {
          nextVisualState = _LiveOpsVisualState.unknown;
          final candidateLabel = classification.kind ==
                  LiveOpsMatchScreenKind.lobby
              ? 'Lobby'
              : classification.kind ==
                      LiveOpsMatchScreenKind.matchInProgress
                  ? 'Gameplay'
                  : classification.kind == LiveOpsMatchScreenKind.resultScreen
                      ? 'Result Screen'
                      : 'screen';
          source = classification.isClassified
              ? 'On-device OCR · $candidateLabel candidate ${_matchScreenObserver.pendingCount}/3 consecutive observations'
              : 'On-device OCR · ${classification.reason}';
          nextStatus = classification.isClassified
              ? 'Checking $candidateLabel screen · ${_matchScreenObserver.pendingCount}/3 stable observations'
              : 'Screen text detected · local preview';
        }

        if (mounted) {
          setState(() {
            _setVisualState(
              nextVisualState,
              observedAt: retainingPriorState ? _stateObservedAt : observedAt,
              // 1.0 denotes the full strict signature plus 3 consecutive
              // frames, not a statistically calibrated probability.
              confidence: confirmedLobby || confirmedGameplay || confirmedResult
                  ? 1.0
                  : null,
              source: source,
            );
            _state = nextStatus;
            _latestText = text;
          });
        }
        if (text.trim().isNotEmpty) {
          await _speakGuidanceForState(nextVisualState);
        }
      }
    } else {
      if (mounted) {
        setState(() {
          _setVisualState(
            _LiveOpsVisualState.unknown,
            observedAt: observedAt,
            source: 'Unrecognised native observation event',
          );
          _state = 'Capturing · unknown observation';
          if (text.isNotEmpty) _latestText = text;
        });
      }
      return;
    }
    // The raw OCR string stays on-device. It may include notifications or unrelated
    // private content on Android 13 full-display capture. Screen-state guidance is
    // emitted only on a state transition, not for every changing OCR frame.
  }

  Future<void> _startNextMatch() async {
    if (widget.preview || _capturing) {
      showMessage(context, 'Pause LiveOps before moving to the next Match.');
      return;
    }
    final previousSessionId = _sessionId;
    if (previousSessionId == null) {
      showMessage(context, 'No active Lobby session is available to advance.');
      return;
    }
    try {
      if (mounted) setState(() => _state = 'Loading next Lobby Match...');
      final next = await KomnivoRepository.instance.startNextLiveOpsLobbySession(
        previousSessionId: previousSessionId,
      );
      final nextSessionId = next['session_id']?.toString();
      final nextMatchId = next['match_id']?.toString();
      final nextSequence = int.tryParse(next['match_sequence']?.toString() ?? '');
      if (nextSessionId == null || nextSessionId.isEmpty ||
          nextMatchId == null || nextMatchId.isEmpty || nextSequence == null) {
        throw Exception('The server did not return a complete next Match session.');
      }
      if (!mounted) return;
      _matchScreenObserver.reset();
      _lastGuidanceState = null;
      _lastGuidanceAt = null;
      _lastGuidanceAtByState.clear();
      setState(() {
        _sessionId = nextSessionId;
        _setVisualState(
          _LiveOpsVisualState.idle,
          source: 'Next Match ready; waiting for screen capture',
        );
        _activeEventId = next['event_id']?.toString();
        _activeMatchId = nextMatchId;
        _activeLobbyCode = next['lobby_code']?.toString();
        _activeMatchSequence = nextSequence;
        _matchResultsSubmitted = false;
        _matchEvidenceSkipped = false;
        _matchEvidenceSkipReason = '';
        _capturing = false;
        _state = 'Next Match ready · sequence $nextSequence';
        _latestText = 'Match $nextSequence is ready. Press Start to begin a new Android screen-observation session.';
      });
      if (_voice) {
        _lastGuidanceAt = DateTime.now();
        await _speak('The next Match in this Lobby is ready. Press Start when you are ready to capture.');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _state = 'Current Match submitted · Next Match unavailable');
        showMessage(
          context,
          error.toString().replaceFirst('Exception: ', ''),
        );
      }
    }
  }

  Future<void> _stop() async {
    _matchScreenObserver.reset();
    try {
      await _methods.invokeMethod<void>('stopCapture');
      await _subscription?.cancel();
      if (_sessionId != null) {
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
        _setVisualState(
          _LiveOpsVisualState.pausedCaptureStopped,
          source: 'Operator paused screen observation',
        );
        _state = 'Paused · ready for screenshot upload';
      });
      await _speakGuidanceForState(_LiveOpsVisualState.pausedCaptureStopped);
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
          const SizedBox(height: 6),
          Text('Screen state: ${_visualState.label}', style: const TextStyle(color: KomnivoTheme.cyan, fontSize: 12, fontWeight: FontWeight.w800)),
          Text('Confidence: $_stateConfidenceLabel · Source: $_stateSource', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
          Text(
            'Observed: ${_stateObservedAt?.toLocal().toString().split('.').first ?? '—'}',
            style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _lobbyId,
            enabled: !_capturing,
            readOnly: _hasSelectedLobbyContext,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: _hasSelectedLobbyContext
                  ? 'Selected platform Lobby ID'
                  : 'Platform Lobby ID (required)',
              hintText: _hasSelectedLobbyContext
                  ? 'Bound from Event Operations'
                  : 'Paste the KOMNIVO Lobby UUID',
              helperText: _hasSelectedLobbyContext
                  ? 'This Lobby was selected in Event Operations and is locked for this session. The server selects the active Match ID.'
                  : 'Manual recovery entry. The server selects the active Match ID; it is never supplied by the client.',
              prefixIcon: _hasSelectedLobbyContext
                  ? const Icon(Icons.lock_outline)
                  : null,
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
          if (_capturing)
            SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _stop, icon: const Icon(Icons.pause_circle_outline), label: const Text('Pause observation for evidence upload')))
          else if (_matchResultsSubmitted)
            const Text('Official result rows are already submitted. Use the Next Match action in the evidence panel to continue this Lobby.', style: TextStyle(color:KomnivoTheme.cyan,fontSize:11,height:1.4))
          else if (_matchEvidenceSkipped)
            Text('Evidence skipped for this Match: $_matchEvidenceSkipReason. No result or score was created. Use Next Match below.', style: const TextStyle(color:KomnivoTheme.cyan,fontSize:11,height:1.4))
          else
            SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _start, icon: const Icon(Icons.play_circle_outline), label: Text(_sessionId == null ? 'Start LiveOps session' : 'Start / resume this Match'))),
        ]),
      ),
      if (_sessionId != null && _activeEventId != null && _activeMatchId != null) ...[
        const SizedBox(height: 14),
        LiveOpsEvidencePanel(
          sessionId: _sessionId!,
          lobbyId: _lobbyId.text.trim(),
          eventId: _activeEventId!,
          matchId: _activeMatchId!,
          matchSequence: _activeMatchSequence ?? 1,
          capturing: _capturing,
          onPause: _stop,
          onNextMatch: _startNextMatch,
          onEvidenceSkipped: (reason) {
            if (!mounted) return;
            setState(() {
              _matchEvidenceSkipped = true;
              _matchEvidenceSkipReason = reason;
              _matchResultsSubmitted = false;
              _capturing = false;
              _state = 'Evidence step skipped · Next Match available';
            });
          },
          evidenceSkipped: _matchEvidenceSkipped,
          preview: widget.preview,
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
          const Text('Continuous screen text stays on-device. Only screenshots you explicitly select and confirm are uploaded. Their OCR is provisional source material, not an official result.', style: TextStyle(color: KomnivoTheme.cyan, fontSize: 11, height: 1.4)),
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
      Text('Screen observation starts only after your action and Android permission. Pause before opening the gallery. Select 1–8 standing screenshots, inspect the local OCR preview and confirm the upload. Hide notifications and unrelated private content before selecting screenshots.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 12, height: 1.5)),
    ]),
  );
}
