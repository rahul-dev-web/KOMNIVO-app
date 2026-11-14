import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_theme.dart';

class AiAssistantScreen extends StatefulWidget {
  const AiAssistantScreen({
    super.key,
    required this.mode,
    this.communityId,
    this.eventId,
  });

  final String mode;
  final String? communityId;
  final String? eventId;

  @override
  State<AiAssistantScreen> createState() => _AiAssistantScreenState();
}

class _AiAssistantScreenState extends State<AiAssistantScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<_ChatItem> _items = [];
  String? _conversationId;
  bool _sending = false;
  bool _restoring = true;
  String? _resolvingProposalId;

  bool get _organizer => widget.mode == 'organizer';

  @override
  void initState() {
    super.initState();
    _items.add(_ChatItem(
      false,
      _organizer
          ? 'Main KOMNIVO Organizer AI hoon. Tournament roadmap, rules, registrations, scrims aur points table planning mein help kar sakta hoon. Abhi chat read-only hai; main koi event ya setting change nahi kar sakta.'
          : 'Namaste! Main KOMNIVO Player AI hoon. App, teams, tournament rules aur registration process samajhne mein help karunga.',
    ));
    _restoreConversation();
  }

  Future<void> _restoreConversation() async {
    try {
      final client = Supabase.instance.client;
      var query = client.from('ai_conversations')
          .select('id')
          .eq('owner_user_id', client.auth.currentUser!.id)
          .eq('mode', widget.mode)
          .eq('status', 'active');

      if (widget.communityId == null) {
        query = query.isFilter('community_id', null);
      } else {
        query = query.eq('community_id', widget.communityId!);
      }
      if (widget.eventId == null) {
        query = query.isFilter('event_id', null);
      } else {
        query = query.eq('event_id', widget.eventId!);
      }

      final rows = await query.order('updated_at', ascending: false).limit(1);
      if (rows.isEmpty) return;
      final conversationId = rows.first['id']?.toString();
      if (conversationId == null || conversationId.isEmpty) return;

      final results = await Future.wait([
        client.from('ai_messages')
            .select('role,content,metadata')
            .eq('conversation_id', conversationId)
            .inFilter('role', ['user', 'assistant'])
            .order('created_at')
            .limit(60),
        client.from('ai_proposals')
            .select('id,action_type,proposal,source_refs,status,expires_at')
            .eq('conversation_id', conversationId)
            .order('created_at'),
      ]);
      if (!mounted) return;
      final messages = List<Map<String, dynamic>>.from(results[0] as List);
      final proposals = List<Map<String, dynamic>>.from(results[1] as List);
      final proposalCards = proposals.map((row) {
        final payload = row['proposal'] is Map
            ? Map<String, dynamic>.from(row['proposal'] as Map)
            : <String, dynamic>{};
        final gameName = payload['game_name']?.toString() ?? 'Free Fire MAX';
        return _ChatItem(
          false,
          'Organizer AI event proposal',
          proposal: {
            'id': row['id'],
            'status': row['status'],
            'expires_at': row['expires_at'],
            'source_refs': row['source_refs'] ?? [],
            'game_name': gameName,
            ...payload,
          },
        );
      }).toList();

      setState(() {
        _conversationId = conversationId;
        _items
          ..clear()
          ..addAll(messages.map((row) {
            return _ChatItem(
              row['role'] == 'user',
              row['content']?.toString() ?? '',
            );
          }))
          ..addAll(proposalCards);
      });
      _scrollToBottom();
    } catch (_) {
      // Chat remains usable when history lookup is unavailable.
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  void _startNewConversation() {
    setState(() {
      _conversationId = null;
      _items
        ..clear()
        ..add(_ChatItem(
          false,
          _organizer
              ? 'New Organizer AI chat. Main current event ke rules, teams aur match status se related planning mein help karunga.'
              : 'New Player AI chat. KOMNIVO ya tournament se related kuch bhi poochho.',
        ));
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<String?> _chooseDocumentVisibility() async {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Who can use this document?'),
        content: const Text('Choose who may receive answers grounded in this uploaded file. You can change the choice by uploading a new version later.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'organizer_only'),
            child: const Text('Organisers only'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'participants'),
            child: const Text('Event participants'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'public'),
            child: const Text('Public event members'),
          ),
        ],
      ),
    );
  }

  String _contentType(String extension) {
    switch (extension.toLowerCase()) {
      case 'pdf': return 'application/pdf';
      case 'docx': return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xlsx': return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'xls': return 'application/vnd.ms-excel';
      case 'csv': return 'text/csv';
      case 'txt': return 'text/plain';
      case 'md': return 'text/markdown';
      case 'png': return 'image/png';
      case 'jpg':
      case 'jpeg': return 'image/jpeg';
      case 'webp': return 'image/webp';
      default: return 'application/octet-stream';
    }
  }

  Future<void> _uploadDocument() async {
    if (!_organizer || _sending || _restoring || widget.communityId == null && widget.eventId == null) {
      return;
    }
    final visibility = await _chooseDocumentVisibility();
    if (visibility == null || !mounted) return;

    String? uploadedPath;
    bool metadataCreated = false;
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'docx', 'xlsx', 'xls', 'csv', 'txt', 'md', 'png', 'jpg', 'jpeg', 'webp'],
      );
      if (file == null) return;

      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        throw Exception('Could not read this file. Try selecting it again.');
      }
      if (bytes.length > 25 * 1024 * 1024) {
        throw Exception('AI documents must be 25 MB or smaller.');
      }

      final client = Supabase.instance.client;
      final user = client.auth.currentUser;
      if (user == null) throw Exception('Sign in again before uploading a document.');
      final extension = (file.extension ?? '').toLowerCase();
      final mime = _contentType(extension);
      final safeName = file.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final unique = '${DateTime.now().microsecondsSinceEpoch}_${math.Random.secure().nextInt(1 << 20)}';
      final path = '${user.id}/${widget.eventId ?? widget.communityId}/${unique}_${safeName}';
      uploadedPath = path;

      setState(() {
        _sending = true;
        _items.add(_ChatItem(true, 'Uploading document: ${file.name}'));
      });
      _scrollToBottom();

      await client.storage.from('ai-documents').uploadBinary(
        path,
        bytes,
        fileOptions: FileOptions(contentType: mime, upsert: false),
      );

      final document = await client.from('ai_documents').insert({
        'owner_user_id': user.id,
        'community_id': widget.communityId,
        'event_id': widget.eventId,
        'storage_path': path,
        'original_filename': file.name,
        'content_type': mime,
        'file_size': bytes.length,
        'visibility': visibility,
        'processing_status': 'uploaded',
      }).select('id').single();
      metadataCreated = true;

      final processed = await client.functions.invoke(
        'komnivo-ai-process-document',
        body: {'document_id': document['id']},
      );
      final data = processed.data is Map
          ? Map<String, dynamic>.from(processed.data as Map)
          : <String, dynamic>{};
      if (processed.status < 200 || processed.status >= 300) {
        throw Exception(data['error']?.toString() ?? 'Document extraction failed.');
      }

      if (!mounted) return;
      final count = data['chunk_count']?.toString() ?? '0';
      final sources = (data['sources'] is List)
          ? (data['sources'] as List).map((value) => value.toString()).take(6).join(', ')
          : '';
      setState(() => _items.add(_ChatItem(
        false,
        'Document processed: ${file.name}. Extracted ${data['extracted_characters'] ?? 0} characters into $count searchable source chunks. ${sources.isEmpty ? '' : 'Sources: $sources. '}Now ask me questions about this document.',
      )));
    } catch (error) {
      if (uploadedPath != null && !metadataCreated) {
        try {
          await Supabase.instance.client.storage.from('ai-documents').remove([uploadedPath]);
        } catch (_) {
          // A failed cleanup leaves an unreferenced private object for later review.
        }
      }
      if (mounted) {
        setState(() => _items.add(_ChatItem(
          false,
          'Document upload/processing failed. ${error.toString().replaceFirst('Exception: ', '')}',
          isError: true,
        )));
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _scrollToBottom();
      }
    }
  }

  Future<void> _send() async {
    final message = _input.text.trim();
    if (message.isEmpty || _sending || _restoring) return;
    setState(() {
      _sending = true;
      _items.add(_ChatItem(true, message));
      _input.clear();
    });
    _scrollToBottom();

    try {
      final response = await Supabase.instance.client.functions.invoke(
        'komnivo-ai',
        body: {
          'mode': widget.mode,
          'message': message,
          if (_conversationId != null) 'conversation_id': _conversationId,
          if (widget.communityId != null) 'community_id': widget.communityId,
          if (widget.eventId != null) 'event_id': widget.eventId,
        },
      );
      final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : <String, dynamic>{};
      if (response.status < 200 || response.status >= 300) {
        throw Exception(data['error']?.toString() ?? 'AI request failed (' + response.status.toString() + ').');
      }
      _conversationId = data['conversation_id']?.toString();
      final reply = data['reply']?.toString() ?? 'No response received.';
      final proposals = data['proposals'] is List
          ? List<Map<String, dynamic>>.from((data['proposals'] as List).whereType<Map>())
          : <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _items.add(_ChatItem(false, reply));
        for (final proposal in proposals) {
          _items.add(_ChatItem(false, 'Organizer AI event proposal', proposal: proposal));
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _items.add(_ChatItem(
        false,
        'Request complete nahi ho saka. ${error.toString().replaceFirst("Exception: ", "")}',
        isError: true,
      )));
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _scrollToBottom();
      }
    }
  }

  Future<void> _resolveProposal(String proposalId, String decision) async {
    if (_resolvingProposalId != null) return;
    setState(() => _resolvingProposalId = proposalId);
    try {
      final response = await Supabase.instance.client.functions.invoke(
        'komnivo-ai-proposal-action',
        body: {'proposal_id': proposalId, 'decision': decision},
      );
      final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : <String, dynamic>{};
      if (response.status < 200 || response.status >= 300) {
        throw Exception(data['error']?.toString() ?? 'Proposal action failed.');
      }
      if (!mounted) return;

      final index = _items.indexWhere((item) => item.proposal?['id']?.toString() == proposalId);
      if (index >= 0) {
        final current = _items[index];
        final updatedProposal = <String, dynamic>{
          ...?current.proposal,
          'status': decision == 'reject' ? 'rejected' : 'executed',
          'result': data,
        };
        setState(() => _items[index] = current.copyWith(proposal: updatedProposal));
      }
      if (decision == 'approve') {
        setState(() => _items.add(_ChatItem(
          false,
          'Approved. Draft event “${data['name'] ?? 'event'}” has been created. Status: DRAFT. It is not published yet. Open the organiser workspace to review and publish it when ready.',
        )));
      } else {
        setState(() => _items.add(const _ChatItem(false, 'Proposal rejected. No event was created.')));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _items.add(_ChatItem(
          false,
          'Proposal could not be resolved. ${error.toString().replaceFirst('Exception: ', '')}',
          isError: true,
        )));
      }
    } finally {
      if (mounted) setState(() => _resolvingProposalId = null);
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          const Icon(Icons.auto_awesome, color: KomnivoTheme.cyan),
          const SizedBox(width: 10),
          Expanded(child: Text(_organizer ? 'Organizer AI' : 'Player AI')),
          IconButton(
            tooltip: 'New chat',
            onPressed: _sending || _restoring ? null : _startNewConversation,
            icon: const Icon(Icons.add_comment_outlined),
          ),
        ]),
      ),
      body: Column(children: [
        if (_organizer)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            color: KomnivoTheme.surface,
            child: const Text(
              'Read-only testing mode · AI suggestions do not change tournament data.',
              style: TextStyle(color: KomnivoTheme.muted, fontSize: 11),
            ),
          ),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(14, 18, 14, 18),
            itemCount: _items.length + ((_sending || _restoring) ? 1 : 0),
            itemBuilder: (context, index) {
              if ((_sending || _restoring) && index == _items.length) {
                return const Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                );
              }
              final item = _items[index];
              if (item.proposal != null) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _EventProposalCard(
                    proposal: item.proposal!,
                    busy: _resolvingProposalId == item.proposal!['id']?.toString(),
                    onApprove: () => _resolveProposal(item.proposal!['id'].toString(), 'approve'),
                    onReject: () => _resolveProposal(item.proposal!['id'].toString(), 'reject'),
                  ),
                );
              }
              return Align(
                alignment: item.fromUser ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.86),
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  decoration: BoxDecoration(
                    color: item.fromUser
                        ? const Color(0xFF263B57)
                        : item.isError
                            ? const Color(0xFF48282E)
                            : KomnivoTheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: KomnivoTheme.line),
                  ),
                  child: SelectableText(
                    item.text,
                    style: const TextStyle(fontSize: 14, height: 1.45, color: Colors.white),
                  ),
                ),
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: _organizer ? 'Tournament ke baare mein poochho…' : 'Kuch bhi poochho…',
                    filled: true,
                    fillColor: KomnivoTheme.surface,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (_organizer)
                IconButton(
                  tooltip: 'Upload rulebook, spreadsheet or screenshot',
                  onPressed: _sending || _restoring ? null : _uploadDocument,
                  icon: const Icon(Icons.attach_file, color: KomnivoTheme.cyan),
                ),
              IconButton.filled(
                onPressed: _sending || _restoring ? null : _send,
                icon: const Icon(Icons.arrow_upward_rounded),
                style: IconButton.styleFrom(backgroundColor: KomnivoTheme.cyan, foregroundColor: Colors.black),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _ChatItem {
  const _ChatItem(this.fromUser, this.text, {this.isError = false, this.proposal});

  final bool fromUser;
  final String text;
  final bool isError;
  final Map<String, dynamic>? proposal;

  _ChatItem copyWith({Map<String, dynamic>? proposal}) => _ChatItem(
    fromUser,
    text,
    isError: isError,
    proposal: proposal ?? this.proposal,
  );
}

class _EventProposalCard extends StatelessWidget {
  const _EventProposalCard({
    required this.proposal,
    required this.busy,
    required this.onApprove,
    required this.onReject,
  });

  final Map<String, dynamic> proposal;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final status = proposal['status']?.toString() ?? 'pending_approval';
    final name = proposal['name']?.toString() ?? 'Tournament';
    final format = proposal['format']?.toString() ?? 'squad';
    final capacity = proposal['capacity']?.toString() ?? '—';
    final game = proposal['game_name']?.toString() ?? 'Game';
    final startsAt = DateTime.tryParse(proposal['starts_at']?.toString() ?? '');
    final close = DateTime.tryParse(proposal['registration_closes_at']?.toString() ?? '');
    final sources = proposal['source_refs'] is List
        ? (proposal['source_refs'] as List).whereType<Map>().map((row) {
            final file = row['document']?.toString() ?? '';
            final source = row['source']?.toString() ?? '';
            return [file, source].where((part) => part.isNotEmpty).join(' — ');
          }).where((value) => value.isNotEmpty).toList()
        : <String>[];
    final pending = status == 'pending_approval';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: KomnivoTheme.cyan.withValues(alpha: 0.55)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.auto_awesome, color: KomnivoTheme.cyan),
          const SizedBox(width: 8),
          const Expanded(child: Text('EVENT DRAFT PROPOSAL', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.8, fontSize: 11))),
          Text(
            status.replaceAll('_', ' ').toUpperCase(),
            style: TextStyle(
              color: pending ? KomnivoTheme.cyan : KomnivoTheme.muted,
              fontSize: 10,
              fontWeight: FontWeight.w800,
            ),
          ),
        ]),
        const SizedBox(height: 13),
        Text(name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        const SizedBox(height: 5),
        Text(proposal['description']?.toString() ?? '', style: const TextStyle(color: KomnivoTheme.muted, height: 1.35)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _ProposalChip(icon: Icons.sports_esports, label: game),
          _ProposalChip(icon: Icons.groups_outlined, label: format.toUpperCase()),
          _ProposalChip(icon: Icons.people_outline, label: '$capacity teams'),
        ]),
        const SizedBox(height: 10),
        if (startsAt != null)
          _ProposalInfo(icon: Icons.event_outlined, label: 'Starts: ${startsAt.toLocal()}'),
        if (close != null)
          _ProposalInfo(icon: Icons.lock_clock_outlined, label: 'Registration closes: ${close.toLocal()}'),
        if (sources.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text('Based on uploaded sources', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11)),
          const SizedBox(height: 4),
          ...sources.take(4).map((source) => _ProposalInfo(icon: Icons.description_outlined, label: source)),
        ],
        const SizedBox(height: 10),
        const Text(
          'Approving creates a DRAFT event only. It will not open registration or publish automatically.',
          style: TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.35),
        ),
        if (pending) ...[
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: busy ? null : onReject,
                child: const Text('Reject'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: busy ? null : onApprove,
                child: Text(busy ? 'Processing…' : 'Approve draft'),
              ),
            ),
          ]),
        ],
      ]),
    );
  }
}

class _ProposalChip extends StatelessWidget {
  const _ProposalChip({required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
    decoration: BoxDecoration(color: const Color(0xFF20263A), borderRadius: BorderRadius.circular(12)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: KomnivoTheme.cyan),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
    ]),
  );
}

class _ProposalInfo extends StatelessWidget {
  const _ProposalInfo({required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 14, color: KomnivoTheme.muted),
      const SizedBox(width: 7),
      Expanded(child: Text(label, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11))),
    ]),
  );
}
