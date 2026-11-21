import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';
import 'liveops_candidate_panel.dart';

class LiveOpsEvidencePanel extends StatefulWidget {
  const LiveOpsEvidencePanel({
    super.key,
    required this.sessionId,
    required this.lobbyId,
    required this.eventId,
    required this.matchId,
    required this.matchSequence,
    required this.capturing,
    required this.onPause,
    required this.onNextMatch,
    this.preview = false,
  });

  final String sessionId;
  final String lobbyId;
  final String eventId;
  final String matchId;
  final int matchSequence;
  final bool capturing;
  final VoidCallback onPause;
  final VoidCallback onNextMatch;
  final bool preview;

  @override
  State<LiveOpsEvidencePanel> createState() => _LiveOpsEvidencePanelState();
}

class _LiveOpsEvidencePanelState extends State<LiveOpsEvidencePanel> {
  static const _methods = MethodChannel('in.komnivo.app/liveops');
  bool _preparing = false;
  bool _uploading = false;
  List<Map<String, dynamic>> _selected = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _batches = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _loadBatches();
  }

  @override
  void didUpdateWidget(covariant LiveOpsEvidencePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId || oldWidget.matchId != widget.matchId) {
      _selected = <Map<String, dynamic>>[];
      _loadBatches();
    }
  }

  Future<void> _loadBatches() async {
    if (widget.preview) return;
    try {
      final rows = await Supabase.instance.client
          .from('liveops_evidence_batches')
          .select('id,match_id,screenshot_count,status,created_at')
          .eq('session_id', widget.sessionId)
          .eq('match_id', widget.matchId)
          .order('created_at', ascending: false)
          .limit(12);
      if (!mounted) return;
      setState(() => _batches = List<Map<String, dynamic>>.from(rows));
    } catch (error) {
      if (mounted) showMessage(context, 'Could not load screenshot history: ' + error.toString());
    }
  }

  bool _isSha256(String value) {
    if (value.length != 64) return false;
    return value.codeUnits.every((unit) =>
        (unit >= 48 && unit <= 57) || (unit >= 97 && unit <= 102));
  }

  Future<void> _chooseScreenshots() async {
    if (widget.preview || widget.capturing || _preparing || _uploading) return;
    try {
      // file_picker 12+ exposes pickFiles as a static method returning a
      // List<PlatformFile>; selected bytes are read explicitly from each file.
      final files = await FilePicker.pickFiles(type: FileType.image);
      if (files.isEmpty) return;
      if (files.length > 8) {
        showMessage(context, 'A batch supports 1 to 8 screenshots. Select at most eight.');
        return;
      }
      setState(() { _preparing = true; _selected = <Map<String, dynamic>>[]; });
      final prepared = <Map<String, dynamic>>[];
      final seenHashes = <String>{};
      for (final file in files) {
        final reportedSize = await file.length();
        if (reportedSize != null && reportedSize > 10 * 1024 * 1024) {
          throw Exception(file.name + ' exceeds 10 MiB.');
        }
        final Uint8List bytes = await file.readAsBytes();
        final extension = (file.extension ?? file.name.split('.').last).toLowerCase();
        final String contentType = switch (extension) {
          'jpg' || 'jpeg' => 'image/jpeg',
          'png' => 'image/png',
          'webp' => 'image/webp',
          _ => '',
        };
        if (bytes.isEmpty) {
          throw Exception('Could not read ' + file.name + '.');
        }
        if (contentType.isEmpty) {
          throw Exception(file.name + ' is not a supported JPG, PNG or WebP screenshot.');
        }
        if (bytes.length > 10 * 1024 * 1024) {
          throw Exception(file.name + ' exceeds 10 MiB.');
        }
        final scan = await _methods.invokeMapMethod<String, dynamic>(
          'recognizeEvidenceImage',
          <String, dynamic>{'bytes': bytes, 'extension': extension},
        );
        final sha256 = scan?['sha256']?.toString() ?? '';
        if (!_isSha256(sha256)) {
          throw Exception('On-device screenshot verification failed for ' + file.name + '.');
        }
        if (!seenHashes.add(sha256)) {
          throw Exception(file.name + ' duplicates another selected screenshot.');
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
      setState(() => _selected = prepared);
    } catch (error) {
      if (mounted) showMessage(context, error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _uploadScreenshots() async {
    if (widget.preview || widget.capturing || _uploading || _selected.isEmpty) return;
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      showMessage(context, 'Sign in again before uploading screenshot evidence.');
      return;
    }
    final client = Supabase.instance.client;
    final uploadedPaths = <String>[];
    final rpcItems = <Map<String, dynamic>>[];
    final requestId = 'evidence_' + DateTime.now().microsecondsSinceEpoch.toString() + '_' +
        math.Random.secure().nextInt(1 << 24).toString();
    setState(() => _uploading = true);
    try {
      for (var index = 0; index < _selected.length; index++) {
        final item = _selected[index];
        final suffix = math.Random.secure().nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
        final fileName = requestId + '_' + (index + 1).toString() + '_' + suffix + '.' + item['extension'].toString();
        final path = <String>[user.id, widget.eventId, widget.matchId, widget.sessionId, fileName].join('/');
        await client.storage.from('match-evidence').uploadBinary(
          path,
          item['bytes'] as Uint8List,
          fileOptions: FileOptions(contentType: item['content_type'].toString(), upsert: false),
        );
        uploadedPaths.add(path);
        rpcItems.add(<String, dynamic>{
          'path': path,
          'content_type': item['content_type'],
          'file_size': item['file_size'],
          'sha256': item['sha256'],
          'ocr_text': item['ocr_text'],
          'observed_at': DateTime.now().toUtc().toIso8601String(),
        });
      }
      final batch = await KomnivoRepository.instance.registerLiveOpsEvidenceBatch(
        sessionId: widget.sessionId,
        lobbyId: widget.lobbyId,
        matchId: widget.matchId,
        idempotencyKey: requestId,
        items: rpcItems,
      );
      await _loadBatches();
      if (!mounted) return;
      setState(() => _selected = <Map<String, dynamic>>[]);
      final count = batch['screenshot_count']?.toString() ?? rpcItems.length.toString();
      showMessage(context, count + ' screenshots registered for Match ' +
          widget.matchSequence.toString() + '. OCR is provisional; review required.');
    } catch (error) {
      if (uploadedPaths.isNotEmpty) {
        try {
          await client.storage.from('match-evidence').remove(uploadedPaths);
        } catch (_) {
          // Registered evidence is protected from client-side deletion.
        }
      }
      if (mounted) showMessage(context, 'Screenshot upload failed: ' +
          error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(20), border: Border.all(color: KomnivoTheme.line)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [Icon(Icons.photo_library_outlined, color: KomnivoTheme.cyan), SizedBox(width: 9), Expanded(child: Text('Standing screenshot evidence', style: TextStyle(fontWeight: FontWeight.w900)))]),
      const SizedBox(height: 7),
      const Text('Select 1–8 screenshots for the active Match ID. JPG, PNG and WebP are supported, up to 10 MiB each. OCR runs on-device before upload.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.45)),
      const SizedBox(height: 11),
      if (widget.capturing)
        SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: _uploading ? null : widget.onPause, icon: const Icon(Icons.pause_circle_outline), label: const Text('Pause observation before opening gallery')))
      else
        SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: _preparing || _uploading ? null : _chooseScreenshots, icon: _preparing ? const SizedBox(width: 16,height: 16,child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.add_photo_alternate_outlined), label: Text(_preparing ? 'Reading screenshots on-device…' : 'Choose screenshots'))),
      if (_selected.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(_selected.length.toString() + ' selected · OCR preview', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
        const SizedBox(height: 5),
        ..._selected.asMap().entries.map((entry) {
          final item = entry.value;
          final ocr = item['ocr_text']?.toString() ?? '';
          return Container(
            margin: const EdgeInsets.only(bottom: 7), padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFF191E2C), borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text((entry.key + 1).toString() + '. ' + item['name'].toString(), style: const TextStyle(fontWeight: FontWeight.w800,fontSize: 11)),
              const SizedBox(height: 3),
              Text(((item['file_size'] as int? ?? 0) / 1024).toStringAsFixed(0) + ' KB · SHA-256 checked', style: const TextStyle(color: KomnivoTheme.muted,fontSize: 10)),
              const SizedBox(height: 5),
              Text(ocr.isEmpty ? 'No text detected. The screenshot will still be attached as evidence.' : ocr, maxLines: 5, overflow: TextOverflow.ellipsis, style: const TextStyle(color: KomnivoTheme.muted,fontSize: 10,height: 1.4)),
            ]),
          );
        }),
        SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _uploading || widget.capturing ? null : _uploadScreenshots, icon: _uploading ? const SizedBox(width: 16,height: 16,child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.cloud_upload_outlined), label: Text(_uploading ? 'Uploading evidence…' : 'Confirm and upload ' + _selected.length.toString() + ' screenshots'))),
      ],
      if (_batches.isNotEmpty) ...[
        const SizedBox(height: 13),
        const Text('Previously uploaded batches', style: TextStyle(fontWeight: FontWeight.w800,fontSize: 11)),
        const SizedBox(height: 4),
        ..._batches.take(5).map((batch) => Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Row(children: [
            const Icon(Icons.verified_outlined,size:14,color:KomnivoTheme.cyan), const SizedBox(width:7),
            Expanded(child: Text((batch['screenshot_count'] ?? 0).toString() + ' screenshots · ' + (batch['status'] ?? 'uploaded').toString(), style: const TextStyle(color:KomnivoTheme.muted,fontSize:10))),
            Text(DateTime.tryParse(batch['created_at']?.toString() ?? '')?.toLocal().toString().split('.').first ?? '', style: const TextStyle(color:KomnivoTheme.muted,fontSize:9)),
          ]),
        )),
      ],
      if (_batches.isNotEmpty) ...[
        const SizedBox(height: 14),
        LiveOpsCandidatePanel(
          sessionId: widget.sessionId,
          matchId: widget.matchId,
          capturing: widget.capturing,
          onNextMatch: widget.onNextMatch,
        ),
      ],
    ]),
  );
}
