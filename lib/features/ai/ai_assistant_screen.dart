import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_theme.dart';
import 'tournament_form_card.dart';

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
  String? _activeCommunityId;
  List<Map<String, String>> _managedCommunities = [];
  bool _loadingManagedCommunities = true;
  String? _communityLoadError;
  bool _sending = false;
  bool _restoring = true;
  String? _resolvingProposalId;

  bool get _organizer => widget.mode == 'organizer';
  bool get _showOrganizerActions => _organizer || _managedCommunities.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _items.add(_ChatItem(
      false,
      _organizer
          ? 'Main KOMNIVO Organizer AI hoon. Selected community ke authorised tournament, registration, team, schedule aur result data ko samajhne aur organise karne mein help karta hoon. Tournament creation ke liye structured form aur explicit approval use hoga.'
          : 'Namaste! Main KOMNIVO Player AI hoon. App, teams, tournament rules aur registration process samajhne mein help karunga.',
    ));
    _restoreConversation();
    _loadManagedCommunities();
  }

  Future<void> _loadManagedCommunities() async {
    try {
      final client = Supabase.instance.client;
      final user = client.auth.currentUser;
      if (user == null) throw Exception('Sign in again to load your communities.');

      final results = await Future.wait([
        client.from('communities').select('id').eq('owner_user_id', user.id),
        client.from('community_members')
            .select('community_id')
            .eq('user_id', user.id)
            .inFilter('role', ['owner', 'admin', 'organiser']),
      ]);
      final communityIds = <String>{};
      for (final row in results[0] as List) {
        if (row is Map && row['id'] != null) communityIds.add(row['id'].toString());
      }
      for (final row in results[1] as List) {
        if (row is Map && row['community_id'] != null) {
          communityIds.add(row['community_id'].toString());
        }
      }

      final List rows = communityIds.isEmpty
          ? <Map<String, dynamic>>[]
          : await client.from('communities')
              .select('id,name')
              .inFilter('id', communityIds.toList())
              .order('name');
      if (!mounted) return;
      setState(() {
        _managedCommunities = rows.map((row) => <String, String>{
          'id': row['id'].toString(),
          'name': row['name']?.toString() ?? 'Unnamed community',
        }).toList();
        _communityLoadError = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _communityLoadError =
            error.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _loadingManagedCommunities = false);
    }
  }

  Future<void> _restoreConversation() async {
    try {
      final client = Supabase.instance.client;
      var query = client.from('ai_conversations')
          .select('id,community_id')
          .eq('owner_user_id', client.auth.currentUser!.id)
          .eq('mode', widget.mode)
          .eq('status', 'active');

      // Global Player AI can continue the most recent chat even after
      // the user selects and binds that chat to an owned community.
      if (widget.communityId != null) {
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
      _activeCommunityId = rows.first['community_id']?.toString();

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
        _organizer
            ? client.from('tournament_proposals')
                .select('id,payload,source_refs,status,expires_at,event_id,community_id')
                .eq('conversation_id', conversationId)
                .order('created_at')
            : Future.value(<Map<String, dynamic>>[]),
      ]);
      if (!mounted) return;
      final messages = List<Map<String, dynamic>>.from(results[0] as List);
      final proposals = List<Map<String, dynamic>>.from(results[1] as List);
      final structuredRows = List<Map<String, dynamic>>.from(results[2] as List);
      final eventIds = structuredRows
          .map((row) => row['event_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      final eventStatuses = <String, String>{};
      if (eventIds.isNotEmpty) {
        final eventRows = await client.from('events')
            .select('id,status')
            .inFilter('id', eventIds.toList());
        for (final eventRow in eventRows) {
          eventStatuses[eventRow['id'].toString()] = eventRow['status'].toString();
        }
      }
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
      final structuredCards = structuredRows.map((row) {
        final payload = row['payload'] is Map
            ? Map<String, dynamic>.from(row['payload'] as Map)
            : <String, dynamic>{};
        return _ChatItem(
          false,
          'Tournament draft proposal',
          proposal: {
            ...payload,
            'id': row['id'],
            'workflow_type': 'tournament',
            'status': row['event_id'] != null
                ? (eventStatuses[row['event_id'].toString()] == 'published'
                    ? 'published'
                    : eventStatuses[row['event_id'].toString()] == 'draft'
                        ? 'draft'
                        : row['status'])
                : row['status'],
            'expires_at': row['expires_at'],
            'event_id': row['event_id'],
            'community_id': row['community_id'],
            'source_refs': row['source_refs'] ?? [],
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
          ..addAll(proposalCards)
          ..addAll(structuredCards);
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
      _activeCommunityId = null;
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
        content: const Text('Choose who may receive answers grounded in this uploaded file. This visibility applies to this uploaded copy.'),
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

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async => _sendMessage(_input.text.trim());

  Future<void> _openTournamentForm() async {
    if (!_showOrganizerActions || _sending || _restoring || _loadingManagedCommunities) return;
    if (_managedCommunities.isEmpty) {
      _showActionMessage(_communityLoadError ?? 'No community with organiser access was found.');
      return;
    }
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => TournamentFormScreen(
          communities: _managedCommunities,
          initialCommunityId: _activeCommunityId ?? widget.communityId,
          conversationId: _organizer ? _conversationId : null,
        ),
      ),
    );
    if (!mounted || result == null) return;
    final proposal = result['proposal'] is Map
        ? Map<String, dynamic>.from(result['proposal'] as Map)
        : <String, dynamic>{};
    if (_organizer) {
      _conversationId = result['conversation_id']?.toString() ?? _conversationId;
      _activeCommunityId = proposal['community_id']?.toString() ?? _activeCommunityId;
    }
    final config = proposal['event_config'] is Map
        ? Map<String, dynamic>.from(proposal['event_config'] as Map)
        : <String, dynamic>{};
    final roadmap = config['roadmap'] is Map
        ? Map<String, dynamic>.from(config['roadmap'] as Map)
        : <String, dynamic>{};
    final stageNames = config['stage_names'] is List
        ? (config['stage_names'] as List).map((value) => value.toString()).join(', ')
        : '';
    final rulebook = config['rulebook'] is Map
        ? Map<String, dynamic>.from(config['rulebook'] as Map)
        : <String, dynamic>{};
    final summary = StringBuffer()
      ..writeln('Tournament proposal saved successfully. Please review the saved configuration:')
      ..writeln()
      ..writeln('${proposal['name'] ?? 'Tournament'}')
      ..writeln('Game: ${proposal['game_name'] ?? '—'} · Mode: ${proposal['format'] ?? '—'} · Capacity: ${proposal['capacity'] ?? '—'} teams')
      ..writeln('Stages: ${config['stage_count'] ?? '—'}${stageNames.isEmpty ? '' : ' ($stageNames)'}')
      ..writeln('Registration: ${proposal['registration_opens_at'] ?? '—'} → ${proposal['registration_closes_at'] ?? '—'}')
      ..writeln('Tournament starts: ${proposal['starts_at'] ?? '—'}')
      ..writeln('Entry: ${config['entry_type'] ?? 'free'}${config['entry_type'] == 'paid' ? ' · Fee ₹${config['entry_fee'] ?? '—'}' : ''}')
      ..writeln('Prize pool: ₹${config['prize_pool_amount'] ?? 0} · Distribution: ${config['prize_distribution']?.toString().isNotEmpty == true ? config['prize_distribution'] : 'Not specified'}')
      ..writeln('Rules: ${config['rules_source'] == 'standard' ? (rulebook['title'] ?? 'Standard rulebook') : 'Custom rules'}')
      ..writeln('Roadmap: ${roadmap.isEmpty ? 'Not configured' : '${roadmap['group_size']} teams/group, ${roadmap['qualifiers_per_group']} qualifiers/group, next round ${roadmap['next_round_team_count']} teams'}')
      ..writeln()
      ..writeln('Choose **Publish Tournament** or **Keep as Draft** below. You can also type “yes, publish” or “no, keep as draft”. Publishing creates the tournament channels, but registration stays closed.');
    setState(() => _items.add(_ChatItem(
      false,
      summary.toString(),
      proposal: proposal,
    )));
    _scrollToBottom();
  }

  void _showPaidScrimComingSoon() {
    if (!_showOrganizerActions || _sending || _restoring) return;
    _showActionMessage(
      'Paid Scrim creation is coming soon. The entry point is ready; its fields, fee rules and approval workflow will be added after the organiser specification is finalised.',
    );
  }

  void _showActionMessage(String message) {
    if (!mounted) return;
    setState(() => _items.add(_ChatItem(false, message)));
    _scrollToBottom();
  }

  Future<bool> _handleTournamentConfirmation(String message) async {
    final normalized = message.toLowerCase().trim()
        .replaceAll(RegExp(r'[.!?]+$'), '')
        .replaceAll(',', ' ')
        .replaceAll(RegExp(r'  +'), ' ');
    const affirmative = {
      'yes', 'y', 'yeah', 'yep', 'haan', 'han', 'ha', 'ji haan',
      'publish', 'publish tournament', 'yes publish', 'yes  publish',
      'haan publish', 'haan publish karo', 'haan publish kar do',
      'publish kar do', 'go ahead and publish', 'confirm publish',
      'sure', 'go ahead', 'confirm', 'ok publish', 'okay publish',
      'publish it', 'kar do',
    };
    const negative = {
      'no', 'n', 'nope', 'nahi', 'nahin', 'na', 'draft',
      'keep draft', 'keep as draft', 'no keep as draft',
      'save as draft', 'draft rakho', 'draft hi rakho',
      'publish mat karo', 'not now', 'not yet', 'later',
      'baad mein', 'abhi nahi', 'keep it private',
    };
    final decision = affirmative.contains(normalized)
        ? 'publish'
        : negative.contains(normalized)
            ? 'keep_draft'
            : null;
    if (decision == null || !_showOrganizerActions) return false;

    final actionable = _items
        .where((item) => item.proposal?['workflow_type'] == 'tournament')
        .where((item) => ['pending_approval', 'approved', 'draft']
            .contains(item.proposal?['status']?.toString()))
        .toList();
    if (actionable.isEmpty) return false;

    setState(() {
      _items.add(_ChatItem(true, message));
      if (_input.text.isNotEmpty) _input.clear();
    });
    if (actionable.length != 1) {
      _showActionMessage(
        'There are multiple unpublished tournament drafts in this chat. Use the Publish Tournament or Keep as Draft button on the exact tournament card you mean. I have not changed any tournament.',
      );
      return true;
    }
    final proposalId = actionable.single.proposal?['id']?.toString();
    if (proposalId == null || proposalId.isEmpty) {
      _showActionMessage(
        'I could not identify the saved tournament draft. Nothing was published. Please use the action on its preview card.',
      );
      return true;
    }
    await _resolveProposal(proposalId, decision);
    return true;
  }

  Future<void> _sendMessage(String message, {String? communityId}) async {
    if (message.isEmpty || _sending || _restoring) return;
    if (await _handleTournamentConfirmation(message)) return;

    final selectedCommunityId = communityId ?? _activeCommunityId ?? widget.communityId;
    setState(() {
      _sending = true;
      _items.add(_ChatItem(true, message));
      if (communityId != null) _activeCommunityId = communityId;
      if (_input.text.isNotEmpty) _input.clear();
    });
    _scrollToBottom();

    try {
      final response = await Supabase.instance.client.functions.invoke(
        'komnivo-ai',
        body: {
          'mode': widget.mode,
          'message': message,
          if (_conversationId != null) 'conversation_id': _conversationId,
          if (selectedCommunityId != null) 'community_id': selectedCommunityId,
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
        'Request complete nahi ho saka. \${error.toString().replaceFirst("Exception: ", "")}',
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
    Map<String, dynamic>? selectedProposal;
    for (final item in _items) {
      if (item.proposal?['id']?.toString() == proposalId) {
        selectedProposal = item.proposal;
        break;
      }
    }
    if (selectedProposal == null) return;
    final proposalDetails = selectedProposal;
    final isStructuredTournament = proposalDetails['workflow_type'] == 'tournament';
    final keepAsDraft = decision == 'keep_draft';
    final publish = decision == 'publish';
    final eventAlreadyDraft = isStructuredTournament &&
        (proposalDetails['status'] == 'draft' || proposalDetails['status'] == 'approved');
    if (keepAsDraft && eventAlreadyDraft) {
      final index = _items.indexWhere((item) => item.proposal?['id']?.toString() == proposalId);
      if (index >= 0) {
        final current = _items[index];
        setState(() => _items[index] = current.copyWith(proposal: {
          ...?current.proposal,
          'status': 'draft',
          'draft_kept': true,
        }));
      }
      setState(() => _items.add(_ChatItem(
        false,
        'Tournament “${proposalDetails['name'] ?? 'event'}” is already saved as a private DRAFT. No public channels or player notifications were created. Publish it later when ready.',
      )));
      return;
    }
    setState(() => _resolvingProposalId = proposalId);
    try {
      final response = await Supabase.instance.client.functions.invoke(
        isStructuredTournament ? 'organizer-tournament-workflow' : 'komnivo-ai-proposal-action',
        body: isStructuredTournament
            ? {
                'action': publish ? 'publish_proposal' : 'resolve_proposal',
                'community_id': proposalDetails['community_id'],
                'proposal_id': proposalId,
                if (!publish) 'decision': keepAsDraft ? 'approve' : decision,
              }
            : {'proposal_id': proposalId, 'decision': decision},
      );
      final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : <String, dynamic>{};
      if (response.status < 200 || response.status >= 300) {
        throw Exception(data['error']?.toString() ?? 'Tournament action failed.');
      }
      if (!mounted) return;

      final index = _items.indexWhere((item) => item.proposal?['id']?.toString() == proposalId);
      if (index >= 0) {
        final current = _items[index];
        final updatedProposal = <String, dynamic>{
          ...?current.proposal,
          'status': decision == 'reject'
              ? 'rejected'
              : publish
                  ? 'published'
                  : isStructuredTournament
                      ? 'draft'
                      : 'executed',
          'result': data,
          if (data['event_id'] != null) 'event_id': data['event_id'],
          if (data['channels'] is List) 'published_channels': data['channels'],
        };
        setState(() => _items[index] = current.copyWith(proposal: updatedProposal));
      }

      if (publish) {
        final channels = data['channels'] is List ? (data['channels'] as List).length : 0;
        setState(() => _items.add(_ChatItem(
          false,
          'Tournament “${data['name'] ?? proposalDetails['name'] ?? 'event'}” published. Its tournament category and $channels channels are ready. Registration is still closed; open it separately when the schedule and registration setup are ready.',
        )));
      } else if (keepAsDraft) {
        setState(() => _items.add(_ChatItem(
          false,
          'Tournament “${data['name'] ?? proposalDetails['name'] ?? 'event'}” is saved as a private DRAFT. No public tournament channels or player notifications were created. You can publish it later from this chat.',
        )));
      } else if (decision == 'reject') {
        setState(() => _items.add(const _ChatItem(false, 'Proposal rejected. No event was created.')));
      } else {
        setState(() => _items.add(_ChatItem(
          false,
          'Draft event “${data['name'] ?? 'event'}” has been created. It is not published yet.',
        )));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _items.add(_ChatItem(
          false,
          'Tournament action could not be completed. ${error.toString().replaceFirst("Exception: ", "")}',
          isError: true,
        )));
      }
    } finally {
      if (mounted) setState(() => _resolvingProposalId = null);
    }
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
              'Authorised organiser data stays in chat. Tournament writes use a structured form and explicit approval.',
              style: TextStyle(color: KomnivoTheme.muted, fontSize: 11),
            ),
          ),
        if (_showOrganizerActions)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: OrganizerChatActions(
              tournamentEnabled: !_sending && !_restoring && !_loadingManagedCommunities,
              paidScrimEnabled: !_sending && !_restoring,
              onCreateTournament: _openTournamentForm,
              onCreatePaidScrim: _showPaidScrimComingSoon,
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
                    onKeepDraft: () => _resolveProposal(item.proposal!['id'].toString(), 'keep_draft'),
                    onPublish: () => _resolveProposal(item.proposal!['id'].toString(), 'publish'),
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
            padding: const EdgeInsets.fromLTRB(12, 5, 12, 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
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
            ]),
          ),
        ),
      ]),
    );
  }
}

class OrganizerChatActions extends StatelessWidget {
  const OrganizerChatActions({
    super.key,
    required this.tournamentEnabled,
    required this.paidScrimEnabled,
    required this.onCreateTournament,
    required this.onCreatePaidScrim,
  });

  final bool tournamentEnabled;
  final bool paidScrimEnabled;
  final VoidCallback onCreateTournament;
  final VoidCallback onCreatePaidScrim;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('organizer-chat-actions-panel'),
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: KomnivoTheme.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ORGANIZER QUICK ACTIONS',
            style: TextStyle(
              color: KomnivoTheme.muted,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: .7,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 7,
            children: [
              OutlinedButton.icon(
                key: const Key('organizer-create-tournament'),
                onPressed: tournamentEnabled ? onCreateTournament : null,
                icon: const Icon(Icons.emoji_events_outlined, size: 17),
                label: const Text('Create Tournament'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: KomnivoTheme.cyan,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                ),
              ),
              OutlinedButton.icon(
                key: const Key('organizer-create-paid-scrim'),
                onPressed: paidScrimEnabled ? onCreatePaidScrim : null,
                icon: const Icon(Icons.payments_outlined, size: 17),
                label: const Text('Create Paid Scrim'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: KomnivoTheme.accent,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChatItem {
  const _ChatItem(
    this.fromUser,
    this.text, {
    this.isError = false,
    this.proposal,
  });

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
    required this.onKeepDraft,
    required this.onPublish,
  });

  final Map<String, dynamic> proposal;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onKeepDraft;
  final VoidCallback onPublish;

  @override
  Widget build(BuildContext context) {
    final status = proposal['status']?.toString() ?? 'pending_approval';
    final isTournament = proposal['workflow_type'] == 'tournament';
    final name = proposal['name']?.toString() ?? 'Tournament';
    final format = proposal['format']?.toString() ?? 'squad';
    final capacity = proposal['capacity']?.toString() ?? '—';
    final game = proposal['game_name']?.toString() ?? 'Game';
    final startsAt = DateTime.tryParse(proposal['starts_at']?.toString() ?? '');
    final opens = DateTime.tryParse(proposal['registration_opens_at']?.toString() ?? '');
    final close = DateTime.tryParse(proposal['registration_closes_at']?.toString() ?? '');
    final eventConfig = proposal['event_config'] is Map
        ? Map<String, dynamic>.from(proposal['event_config'] as Map)
        : <String, dynamic>{};
    final roadmap = eventConfig['roadmap'] is Map
        ? Map<String, dynamic>.from(eventConfig['roadmap'] as Map)
        : <String, dynamic>{};
    final rulebook = eventConfig['rulebook'] is Map
        ? Map<String, dynamic>.from(eventConfig['rulebook'] as Map)
        : <String, dynamic>{};
    final rules = proposal['rules_json'] is Map
        ? Map<String, dynamic>.from(proposal['rules_json'] as Map)
        : <String, dynamic>{};
    final scoring = proposal['scoring_config'] is Map
        ? Map<String, dynamic>.from(proposal['scoring_config'] as Map)
        : <String, dynamic>{};
    final stageNames = eventConfig['stage_names'] is List
        ? (eventConfig['stage_names'] as List).map((value) => value.toString()).toList()
        : <String>[];
    final entryType = eventConfig['entry_type']?.toString() ?? 'free';
    final stageCount = eventConfig['stage_count']?.toString() ?? '—';
    final prizePool = eventConfig['prize_pool_amount']?.toString() ?? '0';
    final sources = proposal['source_refs'] is List
        ? (proposal['source_refs'] as List).whereType<Map>().map((row) {
            final file = row['document']?.toString() ?? '';
            final source = row['source']?.toString() ?? '';
            return [file, source].where((part) => part.isNotEmpty).join(' — ');
          }).where((value) => value.isNotEmpty).toList()
        : <String>[];
    final pending = status == 'pending_approval';
    final draft = status == 'draft' || status == 'approved';

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
          Expanded(child: Text(
            isTournament ? 'TOURNAMENT PREVIEW' : 'EVENT DRAFT PROPOSAL',
            style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.8, fontSize: 11),
          )),
          Text(
            status.replaceAll('_', ' ').toUpperCase(),
            style: TextStyle(
              color: status == 'published' ? KomnivoTheme.cyan : KomnivoTheme.muted,
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
          _ProposalChip(icon: Icons.people_outline, label: '$capacity slots'),
          _ProposalChip(icon: Icons.account_tree_outlined, label: '$stageCount stages'),
          _ProposalChip(icon: Icons.payments_outlined, label: entryType == 'paid' ? 'Paid entry' : 'Free entry'),
          _ProposalChip(icon: Icons.card_giftcard_outlined, label: '₹$prizePool prize pool'),
        ]),
        const SizedBox(height: 10),
        if (opens != null)
          _ProposalInfo(icon: Icons.how_to_reg_outlined, label: 'Registration opens: ${opens.toLocal()}'),
        if (close != null)
          _ProposalInfo(icon: Icons.lock_clock_outlined, label: 'Registration closes: ${close.toLocal()}'),
        if (startsAt != null)
          _ProposalInfo(icon: Icons.event_outlined, label: 'Tournament starts: ${startsAt.toLocal()}'),
        if (stageNames.isNotEmpty)
          _ProposalInfo(icon: Icons.account_tree_outlined, label: 'Stage names: ${stageNames.join(' → ')}'),
        if (roadmap.isNotEmpty)
          _ProposalInfo(
            icon: Icons.groups_outlined,
            label: 'Roadmap: group size ${roadmap['group_size']}, ${roadmap['qualifiers_per_group']} qualifiers/group, ${roadmap['qualified_team_count']} qualified + ${roadmap['direct_invites']} direct invites → ${roadmap['next_round_team_count']} teams',
          ),
        _ProposalInfo(
          icon: Icons.rule_outlined,
          label: 'Rules: ${eventConfig['rules_source'] == 'standard' ? '${rulebook['title'] ?? 'Standard rulebook'} ${rulebook['version'] ?? ''}' : 'Custom rules'}',
        ),
        if (rules['custom_text'] != null)
          _ProposalInfo(icon: Icons.description_outlined, label: 'Custom rules: ${rules['custom_text']}'),
        if (scoring.isNotEmpty)
          _ProposalInfo(icon: Icons.calculate_outlined, label: 'Scoring configuration: ${scoring.entries.map((entry) => '${entry.key}: ${entry.value}').join(' · ')}'),
        if ((eventConfig['prize_distribution']?.toString() ?? '').isNotEmpty)
          _ProposalInfo(icon: Icons.card_giftcard_outlined, label: 'Prize distribution: ${eventConfig['prize_distribution']}'),
        if ((eventConfig['entry_fee']?.toString() ?? '').isNotEmpty)
          _ProposalInfo(icon: Icons.payments_outlined, label: 'Entry fee: ₹${eventConfig['entry_fee']}'),
        if ((proposal['banner_path']?.toString() ?? '').isNotEmpty || (eventConfig['banner_path']?.toString() ?? '').isNotEmpty)
          const _ProposalInfo(icon: Icons.image_outlined, label: 'Tournament banner uploaded'),
        if (sources.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text('Based on uploaded sources', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11)),
          const SizedBox(height: 4),
          ...sources.take(4).map((source) => _ProposalInfo(icon: Icons.description_outlined, label: source)),
        ],
        const SizedBox(height: 10),
        Text(
          isTournament
              ? 'Keep as Draft creates a private, editable event. Publish creates the tournament category and channels. Registration remains closed until you open it separately.'
              : 'Approving creates a DRAFT event only. It will not open registration or publish automatically.',
          style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.35),
        ),
        if (isTournament && (pending || draft)) ...[
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: proposal['draft_kept'] == true
                  ? const Text('PRIVATE DRAFT SAVED', style: TextStyle(color: KomnivoTheme.cyan, fontSize: 10, fontWeight: FontWeight.w900))
                  : OutlinedButton(
                      onPressed: busy ? null : onKeepDraft,
                      child: Text(busy ? 'Saving…' : 'Keep as Draft'),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : onPublish,
                icon: const Icon(Icons.campaign_outlined),
                label: Text(busy ? 'Publishing…' : 'Publish Tournament'),
              ),
            ),
          ]),
        ] else if (!isTournament && pending) ...[
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
        ] else if (isTournament && status == 'published') ...[
          const SizedBox(height: 8),
          const Text('Published successfully. Registration has not been opened.', style: TextStyle(color: KomnivoTheme.cyan, fontSize: 11, fontWeight: FontWeight.w700)),
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
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xFF29234B),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: KomnivoTheme.line),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: KomnivoTheme.cyan),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
    ]),
  );
}

class _ProposalInfo extends StatelessWidget {
  const _ProposalInfo({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 13, color: KomnivoTheme.muted),
      const SizedBox(width: 7),
      Expanded(child: Text(label, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.35))),
    ]),
  );
}
), '');
    const affirmative = {
      'yes', 'y', 'yeah', 'yep', 'haan', 'han', 'ha', 'ji haan',
      'publish', 'publish tournament', 'yes publish', 'haan publish', 'sure', 'go ahead', 'confirm', 'ok publish', 'okay publish', 'publish it',
      'haan publish karo', 'haan publish kar do', 'publish kar do',
      'go ahead and publish', 'confirm publish', 'kar do',
    };
    const negative = {
      'no', 'n', 'nope', 'nahi', 'nahin', 'na', 'draft',
      'keep draft', 'keep as draft', 'save as draft', 'draft rakho',
      'draft hi rakho', 'publish mat karo', 'not now', 'not yet', 'later', 'baad mein', 'abhi nahi', 'keep it private',
    };
    final decision = affirmative.contains(normalized)
        ? 'publish'
        : negative.contains(normalized)
            ? 'keep_draft'
            : null;
    if (decision == null || !_showOrganizerActions) return false;

    final actionable = _items
        .where((item) => item.proposal?['workflow_type'] == 'tournament')
        .where((item) => ['pending_approval', 'approved', 'draft']
            .contains(item.proposal?['status']?.toString()))
        .toList();
    if (actionable.isEmpty) return false;

    setState(() {
      _items.add(_ChatItem(true, message));
      if (_input.text.isNotEmpty) _input.clear();
    });
    if (actionable.length != 1) {
      _showActionMessage(
        'There are multiple unpublished tournament drafts in this chat. Use the Publish Tournament or Keep as Draft button on the exact tournament card you mean. I have not changed any tournament.',
      );
      return true;
    }
    final proposalId = actionable.single.proposal?['id']?.toString();
    if (proposalId == null || proposalId.isEmpty) {
      _showActionMessage(
        'I could not identify the saved tournament draft. Nothing was published. Please use the action on its preview card.',
      );
      return true;
    }
    await _resolveProposal(proposalId, decision);
    return true;
  }

  Future<void> _sendMessage(String message, {String? communityId}) async {
    if (message.isEmpty || _sending || _restoring) return;
    if (await _handleTournamentConfirmation(message)) return;
    final selectedCommunityId = communityId ?? _activeCommunityId ?? widget.communityId;
    setState(() {
      _sending = true;
      _items.add(_ChatItem(true, message));
      if (communityId != null) _activeCommunityId = communityId;
      if (_input.text.isNotEmpty) _input.clear();
    });
    _scrollToBottom();

    try {
      final response = await Supabase.instance.client.functions.invoke(
        'komnivo-ai',
        body: {
          'mode': widget.mode,
          'message': message,
          if (_conversationId != null) 'conversation_id': _conversationId,
          if (selectedCommunityId != null) 'community_id': selectedCommunityId,
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
    Map<String, dynamic>? selectedProposal;
    for (final item in _items) {
      if (item.proposal?['id']?.toString() == proposalId) {
        selectedProposal = item.proposal;
        break;
      }
    }
    if (selectedProposal == null) return;
    final proposalDetails = selectedProposal;
    final isStructuredTournament = proposalDetails['workflow_type'] == 'tournament';
    final keepAsDraft = decision == 'keep_draft';
    final publish = decision == 'publish';
    final eventAlreadyDraft = isStructuredTournament &&
        (proposalDetails['status'] == 'draft' || proposalDetails['status'] == 'approved');
    if (keepAsDraft && eventAlreadyDraft) {
      final index = _items.indexWhere((item) => item.proposal?['id']?.toString() == proposalId);
      if (index >= 0) {
        final current = _items[index];
        setState(() => _items[index] = current.copyWith(proposal: {
          ...?current.proposal,
          'status': 'draft',
          'draft_kept': true,
        }));
      }
      setState(() => _items.add(_ChatItem(
        false,
        'Tournament “${proposalDetails['name'] ?? 'event'}” is already saved as a private DRAFT. No public channels or player notifications were created. Publish it later when ready.',
      )));
      return;
    }
    setState(() => _resolvingProposalId = proposalId);
    try {
      final response = await Supabase.instance.client.functions.invoke(
        isStructuredTournament ? 'organizer-tournament-workflow' : 'komnivo-ai-proposal-action',
        body: isStructuredTournament
            ? {
                'action': publish ? 'publish_proposal' : 'resolve_proposal',
                'community_id': proposalDetails['community_id'],
                'proposal_id': proposalId,
                if (!publish) 'decision': keepAsDraft ? 'approve' : decision,
              }
            : {'proposal_id': proposalId, 'decision': decision},
      );
      final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : <String, dynamic>{};
      if (response.status < 200 || response.status >= 300) {
        throw Exception(data['error']?.toString() ?? 'Tournament action failed.');
      }
      if (!mounted) return;

      final index = _items.indexWhere((item) => item.proposal?['id']?.toString() == proposalId);
      if (index >= 0) {
        final current = _items[index];
        final updatedProposal = <String, dynamic>{
          ...?current.proposal,
          'status': decision == 'reject'
              ? 'rejected'
              : publish
                  ? 'published'
                  : isStructuredTournament
                      ? 'draft'
                      : 'executed',
          'result': data,
          if (data['event_id'] != null) 'event_id': data['event_id'],
          if (data['channels'] is List) 'published_channels': data['channels'],
        };
        setState(() => _items[index] = current.copyWith(proposal: updatedProposal));
      }

      if (publish) {
        final channels = data['channels'] is List ? (data['channels'] as List).length : 0;
        setState(() => _items.add(_ChatItem(
          false,
          'Tournament “${data['name'] ?? proposalDetails['name'] ?? 'event'}” published. Its tournament category and $channels channels are ready. Registration is still closed; open it separately when the schedule and registration setup are ready.',
        )));
      } else if (keepAsDraft) {
        setState(() => _items.add(_ChatItem(
          false,
          'Tournament “${data['name'] ?? proposalDetails['name'] ?? 'event'}” is saved as a private DRAFT. No public tournament channels or player notifications were created. You can publish it later from this chat.',
        )));
      } else if (decision == 'reject') {
        setState(() => _items.add(const _ChatItem(false, 'Proposal rejected. No event was created.')));
      } else {
        setState(() => _items.add(_ChatItem(
          false,
          'Draft event “${data['name'] ?? 'event'}” has been created. It is not published yet.',
        )));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _items.add(_ChatItem(
          false,
          'Tournament action could not be completed. ${error.toString().replaceFirst("Exception: ", "")}',
          isError: true,
        )));
      }
    } finally {
      if (mounted) setState(() => _resolvingProposalId = null);
    }
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
              'Authorised organiser data stays in chat. Tournament writes use a structured form and explicit approval.',
              style: TextStyle(color: KomnivoTheme.muted, fontSize: 11),
            ),
          ),
        if (_showOrganizerActions)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: OrganizerChatActions(
              tournamentEnabled: !_sending && !_restoring && !_loadingManagedCommunities,
              paidScrimEnabled: !_sending && !_restoring,
              onCreateTournament: _openTournamentForm,
              onCreatePaidScrim: _showPaidScrimComingSoon,
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
                    onKeepDraft: () => _resolveProposal(item.proposal!['id'].toString(), 'keep_draft'),
                    onPublish: () => _resolveProposal(item.proposal!['id'].toString(), 'publish'),
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
            padding: const EdgeInsets.fromLTRB(12, 5, 12, 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
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
            ]),
          ),
        ),
      ]),
    );
  }
}

class OrganizerChatActions extends StatelessWidget {
  const OrganizerChatActions({
    super.key,
    required this.tournamentEnabled,
    required this.paidScrimEnabled,
    required this.onCreateTournament,
    required this.onCreatePaidScrim,
  });

  final bool tournamentEnabled;
  final bool paidScrimEnabled;
  final VoidCallback onCreateTournament;
  final VoidCallback onCreatePaidScrim;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('organizer-chat-actions-panel'),
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: KomnivoTheme.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ORGANIZER QUICK ACTIONS',
            style: TextStyle(
              color: KomnivoTheme.muted,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: .7,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 7,
            children: [
              OutlinedButton.icon(
                key: const Key('organizer-create-tournament'),
                onPressed: tournamentEnabled ? onCreateTournament : null,
                icon: const Icon(Icons.emoji_events_outlined, size: 17),
                label: const Text('Create Tournament'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: KomnivoTheme.cyan,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                ),
              ),
              OutlinedButton.icon(
                key: const Key('organizer-create-paid-scrim'),
                onPressed: paidScrimEnabled ? onCreatePaidScrim : null,
                icon: const Icon(Icons.payments_outlined, size: 17),
                label: const Text('Create Paid Scrim'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: KomnivoTheme.accent,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChatItem {
  const _ChatItem(
    this.fromUser,
    this.text, {
    this.isError = false,
    this.proposal,
  });

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
    required this.onKeepDraft,
    required this.onPublish,
  });

  final Map<String, dynamic> proposal;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onKeepDraft;
  final VoidCallback onPublish;

  @override
  Widget build(BuildContext context) {
    final status = proposal['status']?.toString() ?? 'pending_approval';
    final isTournament = proposal['workflow_type'] == 'tournament';
    final name = proposal['name']?.toString() ?? 'Tournament';
    final format = proposal['format']?.toString() ?? 'squad';
    final capacity = proposal['capacity']?.toString() ?? '—';
    final game = proposal['game_name']?.toString() ?? 'Game';
    final startsAt = DateTime.tryParse(proposal['starts_at']?.toString() ?? '');
    final close = DateTime.tryParse(proposal['registration_closes_at']?.toString() ?? '');
    final eventConfig = proposal['event_config'] is Map
        ? Map<String, dynamic>.from(proposal['event_config'] as Map)
        : <String, dynamic>{};
    final entryType = eventConfig['entry_type']?.toString() ?? 'free';
    final stageCount = eventConfig['stage_count']?.toString() ?? '—';
    final prizePool = eventConfig['prize_pool_amount']?.toString() ?? '0';
    final sources = proposal['source_refs'] is List
        ? (proposal['source_refs'] as List).whereType<Map>().map((row) {
            final file = row['document']?.toString() ?? '';
            final source = row['source']?.toString() ?? '';
            return [file, source].where((part) => part.isNotEmpty).join(' — ');
          }).where((value) => value.isNotEmpty).toList()
        : <String>[];
    final pending = status == 'pending_approval';
    final draft = status == 'draft' || status == 'approved';

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
          Expanded(child: Text(
            isTournament ? 'TOURNAMENT PREVIEW' : 'EVENT DRAFT PROPOSAL',
            style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.8, fontSize: 11),
          )),
          Text(
            status.replaceAll('_', ' ').toUpperCase(),
            style: TextStyle(
              color: status == 'published' ? KomnivoTheme.cyan : KomnivoTheme.muted,
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
          _ProposalChip(icon: Icons.people_outline, label: '$capacity slots'),
          _ProposalChip(icon: Icons.account_tree_outlined, label: '$stageCount stages'),
          _ProposalChip(icon: Icons.payments_outlined, label: entryType == 'paid' ? 'Paid entry' : 'Free entry'),
          _ProposalChip(icon: Icons.card_giftcard_outlined, label: '₹$prizePool prize pool'),
        ]),
        const SizedBox(height: 10),
        if (startsAt != null)
          _ProposalInfo(icon: Icons.event_outlined, label: 'Matches start: ${startsAt.toLocal()}'),
        if (close != null)
          _ProposalInfo(icon: Icons.lock_clock_outlined, label: 'Registration closes: ${close.toLocal()}'),
        if (sources.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text('Based on uploaded sources', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11)),
          const SizedBox(height: 4),
          ...sources.take(4).map((source) => _ProposalInfo(icon: Icons.description_outlined, label: source)),
        ],
        const SizedBox(height: 10),
        Text(
          isTournament
              ? 'Keep as Draft creates a private, editable event. Publish creates the tournament category and channels. Registration remains closed until you open it separately.'
              : 'Approving creates a DRAFT event only. It will not open registration or publish automatically.',
          style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.35),
        ),
        if (isTournament && (pending || draft)) ...[
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: proposal['draft_kept'] == true
                  ? const Text('PRIVATE DRAFT SAVED', style: TextStyle(color: KomnivoTheme.cyan, fontSize: 10, fontWeight: FontWeight.w900))
                  : OutlinedButton(
                      onPressed: busy ? null : onKeepDraft,
                      child: Text(busy ? 'Saving…' : 'Keep as Draft'),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : onPublish,
                icon: const Icon(Icons.campaign_outlined),
                label: Text(busy ? 'Publishing…' : 'Publish Tournament'),
              ),
            ),
          ]),
        ] else if (!isTournament && pending) ...[
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
        ] else if (isTournament && status == 'published') ...[
          const SizedBox(height: 8),
          const Text('Published successfully. Registration has not been opened.', style: TextStyle(color: KomnivoTheme.cyan, fontSize: 11, fontWeight: FontWeight.w700)),
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
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xFF29234B),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: KomnivoTheme.line),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: KomnivoTheme.cyan),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
    ]),
  );
}

class _ProposalInfo extends StatelessWidget {
  const _ProposalInfo({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 13, color: KomnivoTheme.muted),
      const SizedBox(width: 7),
      Expanded(child: Text(label, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.35))),
    ]),
  );
}
), '').replaceAll(',', ' ').replaceAll(RegExp(r'\\s+'), ' ');
    const affirmative = {
      'yes', 'y', 'yeah', 'yep', 'haan', 'han', 'ha', 'ji haan',
      'publish', 'publish tournament', 'yes publish', 'haan publish',
      'haan publish karo', 'haan publish kar do', 'publish kar do',
      'go ahead and publish', 'confirm publish', 'sure', 'go ahead',
      'confirm', 'ok publish', 'okay publish', 'publish it', 'kar do',
    };
    const negative = {
      'no', 'n', 'nope', 'nahi', 'nahin', 'na', 'draft',
      'keep draft', 'keep as draft', 'save as draft', 'draft rakho',
      'draft hi rakho', 'publish mat karo', 'not now', 'not yet',
      'later', 'baad mein', 'abhi nahi', 'keep it private',
    };
    final decision = affirmative.contains(normalized)
        ? 'publish'
        : negative.contains(normalized)
            ? 'keep_draft'
            : null;
    if (decision == null || !_showOrganizerActions) return false;

    final actionable = _items
        .where((item) => item.proposal?['workflow_type'] == 'tournament')
        .where((item) => ['pending_approval', 'approved', 'draft']
            .contains(item.proposal?['status']?.toString()))
        .toList();
    if (actionable.isEmpty) return false;

    setState(() {
      _items.add(_ChatItem(true, message));
      if (_input.text.isNotEmpty) _input.clear();
    });
    if (actionable.length != 1) {
      _showActionMessage(
        'There are multiple unpublished tournament drafts in this chat. Use the Publish Tournament or Keep as Draft button on the exact tournament card you mean. I have not changed any tournament.',
      );
      return true;
    }
    final proposalId = actionable.single.proposal?['id']?.toString();
    if (proposalId == null || proposalId.isEmpty) {
      _showActionMessage(
        'I could not identify the saved tournament draft. Nothing was published. Please use the action on its preview card.',
      );
      return true;
    }
    await _resolveProposal(proposalId, decision);
    return true;
  }

  Future<void> _sendMessage(String message, {String? communityId}) async {
    if (message.isEmpty || _sending || _restoring) return;
    if (await _handleTournamentConfirmation(message)) return;

    final selectedCommunityId = communityId ?? _activeCommunityId ?? widget.communityId;
    setState(() {
      _sending = true;
      _items.add(_ChatItem(true, message));
      if (communityId != null) _activeCommunityId = communityId;
      if (_input.text.isNotEmpty) _input.clear();
    });
    _scrollToBottom();

    try {
      final response = await Supabase.instance.client.functions.invoke(
        'komnivo-ai',
        body: {
          'mode': widget.mode,
          'message': message,
          if (_conversationId != null) 'conversation_id': _conversationId,
          if (selectedCommunityId != null) 'community_id': selectedCommunityId,
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
        'Request complete nahi ho saka. \${error.toString().replaceFirst("Exception: ", "")}',
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
    Map<String, dynamic>? selectedProposal;
    for (final item in _items) {
      if (item.proposal?['id']?.toString() == proposalId) {
        selectedProposal = item.proposal;
        break;
      }
    }
    if (selectedProposal == null) return;
    final proposalDetails = selectedProposal;
    final isStructuredTournament = proposalDetails['workflow_type'] == 'tournament';
    final keepAsDraft = decision == 'keep_draft';
    final publish = decision == 'publish';
    final eventAlreadyDraft = isStructuredTournament &&
        (proposalDetails['status'] == 'draft' || proposalDetails['status'] == 'approved');
    if (keepAsDraft && eventAlreadyDraft) {
      final index = _items.indexWhere((item) => item.proposal?['id']?.toString() == proposalId);
      if (index >= 0) {
        final current = _items[index];
        setState(() => _items[index] = current.copyWith(proposal: {
          ...?current.proposal,
          'status': 'draft',
          'draft_kept': true,
        }));
      }
      setState(() => _items.add(_ChatItem(
        false,
        'Tournament “${proposalDetails['name'] ?? 'event'}” is already saved as a private DRAFT. No public channels or player notifications were created. Publish it later when ready.',
      )));
      return;
    }
    setState(() => _resolvingProposalId = proposalId);
    try {
      final response = await Supabase.instance.client.functions.invoke(
        isStructuredTournament ? 'organizer-tournament-workflow' : 'komnivo-ai-proposal-action',
        body: isStructuredTournament
            ? {
                'action': publish ? 'publish_proposal' : 'resolve_proposal',
                'community_id': proposalDetails['community_id'],
                'proposal_id': proposalId,
                if (!publish) 'decision': keepAsDraft ? 'approve' : decision,
              }
            : {'proposal_id': proposalId, 'decision': decision},
      );
      final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : <String, dynamic>{};
      if (response.status < 200 || response.status >= 300) {
        throw Exception(data['error']?.toString() ?? 'Tournament action failed.');
      }
      if (!mounted) return;

      final index = _items.indexWhere((item) => item.proposal?['id']?.toString() == proposalId);
      if (index >= 0) {
        final current = _items[index];
        final updatedProposal = <String, dynamic>{
          ...?current.proposal,
          'status': decision == 'reject'
              ? 'rejected'
              : publish
                  ? 'published'
                  : isStructuredTournament
                      ? 'draft'
                      : 'executed',
          'result': data,
          if (data['event_id'] != null) 'event_id': data['event_id'],
          if (data['channels'] is List) 'published_channels': data['channels'],
        };
        setState(() => _items[index] = current.copyWith(proposal: updatedProposal));
      }

      if (publish) {
        final channels = data['channels'] is List ? (data['channels'] as List).length : 0;
        setState(() => _items.add(_ChatItem(
          false,
          'Tournament “${data['name'] ?? proposalDetails['name'] ?? 'event'}” published. Its tournament category and $channels channels are ready. Registration is still closed; open it separately when the schedule and registration setup are ready.',
        )));
      } else if (keepAsDraft) {
        setState(() => _items.add(_ChatItem(
          false,
          'Tournament “${data['name'] ?? proposalDetails['name'] ?? 'event'}” is saved as a private DRAFT. No public tournament channels or player notifications were created. You can publish it later from this chat.',
        )));
      } else if (decision == 'reject') {
        setState(() => _items.add(const _ChatItem(false, 'Proposal rejected. No event was created.')));
      } else {
        setState(() => _items.add(_ChatItem(
          false,
          'Draft event “${data['name'] ?? 'event'}” has been created. It is not published yet.',
        )));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _items.add(_ChatItem(
          false,
          'Tournament action could not be completed. ${error.toString().replaceFirst("Exception: ", "")}',
          isError: true,
        )));
      }
    } finally {
      if (mounted) setState(() => _resolvingProposalId = null);
    }
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
              'Authorised organiser data stays in chat. Tournament writes use a structured form and explicit approval.',
              style: TextStyle(color: KomnivoTheme.muted, fontSize: 11),
            ),
          ),
        if (_showOrganizerActions)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: OrganizerChatActions(
              tournamentEnabled: !_sending && !_restoring && !_loadingManagedCommunities,
              paidScrimEnabled: !_sending && !_restoring,
              onCreateTournament: _openTournamentForm,
              onCreatePaidScrim: _showPaidScrimComingSoon,
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
                    onKeepDraft: () => _resolveProposal(item.proposal!['id'].toString(), 'keep_draft'),
                    onPublish: () => _resolveProposal(item.proposal!['id'].toString(), 'publish'),
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
            padding: const EdgeInsets.fromLTRB(12, 5, 12, 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
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
            ]),
          ),
        ),
      ]),
    );
  }
}

class OrganizerChatActions extends StatelessWidget {
  const OrganizerChatActions({
    super.key,
    required this.tournamentEnabled,
    required this.paidScrimEnabled,
    required this.onCreateTournament,
    required this.onCreatePaidScrim,
  });

  final bool tournamentEnabled;
  final bool paidScrimEnabled;
  final VoidCallback onCreateTournament;
  final VoidCallback onCreatePaidScrim;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('organizer-chat-actions-panel'),
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: KomnivoTheme.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ORGANIZER QUICK ACTIONS',
            style: TextStyle(
              color: KomnivoTheme.muted,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: .7,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 7,
            children: [
              OutlinedButton.icon(
                key: const Key('organizer-create-tournament'),
                onPressed: tournamentEnabled ? onCreateTournament : null,
                icon: const Icon(Icons.emoji_events_outlined, size: 17),
                label: const Text('Create Tournament'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: KomnivoTheme.cyan,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                ),
              ),
              OutlinedButton.icon(
                key: const Key('organizer-create-paid-scrim'),
                onPressed: paidScrimEnabled ? onCreatePaidScrim : null,
                icon: const Icon(Icons.payments_outlined, size: 17),
                label: const Text('Create Paid Scrim'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: KomnivoTheme.accent,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChatItem {
  const _ChatItem(
    this.fromUser,
    this.text, {
    this.isError = false,
    this.proposal,
  });

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
    required this.onKeepDraft,
    required this.onPublish,
  });

  final Map<String, dynamic> proposal;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onKeepDraft;
  final VoidCallback onPublish;

  @override
  Widget build(BuildContext context) {
    final status = proposal['status']?.toString() ?? 'pending_approval';
    final isTournament = proposal['workflow_type'] == 'tournament';
    final name = proposal['name']?.toString() ?? 'Tournament';
    final format = proposal['format']?.toString() ?? 'squad';
    final capacity = proposal['capacity']?.toString() ?? '—';
    final game = proposal['game_name']?.toString() ?? 'Game';
    final startsAt = DateTime.tryParse(proposal['starts_at']?.toString() ?? '');
    final opens = DateTime.tryParse(proposal['registration_opens_at']?.toString() ?? '');
    final close = DateTime.tryParse(proposal['registration_closes_at']?.toString() ?? '');
    final eventConfig = proposal['event_config'] is Map
        ? Map<String, dynamic>.from(proposal['event_config'] as Map)
        : <String, dynamic>{};
    final roadmap = eventConfig['roadmap'] is Map
        ? Map<String, dynamic>.from(eventConfig['roadmap'] as Map)
        : <String, dynamic>{};
    final rulebook = eventConfig['rulebook'] is Map
        ? Map<String, dynamic>.from(eventConfig['rulebook'] as Map)
        : <String, dynamic>{};
    final rules = proposal['rules_json'] is Map
        ? Map<String, dynamic>.from(proposal['rules_json'] as Map)
        : <String, dynamic>{};
    final scoring = proposal['scoring_config'] is Map
        ? Map<String, dynamic>.from(proposal['scoring_config'] as Map)
        : <String, dynamic>{};
    final stageNames = eventConfig['stage_names'] is List
        ? (eventConfig['stage_names'] as List).map((value) => value.toString()).toList()
        : <String>[];
    final entryType = eventConfig['entry_type']?.toString() ?? 'free';
    final stageCount = eventConfig['stage_count']?.toString() ?? '—';
    final prizePool = eventConfig['prize_pool_amount']?.toString() ?? '0';
    final sources = proposal['source_refs'] is List
        ? (proposal['source_refs'] as List).whereType<Map>().map((row) {
            final file = row['document']?.toString() ?? '';
            final source = row['source']?.toString() ?? '';
            return [file, source].where((part) => part.isNotEmpty).join(' — ');
          }).where((value) => value.isNotEmpty).toList()
        : <String>[];
    final pending = status == 'pending_approval';
    final draft = status == 'draft' || status == 'approved';

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
          Expanded(child: Text(
            isTournament ? 'TOURNAMENT PREVIEW' : 'EVENT DRAFT PROPOSAL',
            style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.8, fontSize: 11),
          )),
          Text(
            status.replaceAll('_', ' ').toUpperCase(),
            style: TextStyle(
              color: status == 'published' ? KomnivoTheme.cyan : KomnivoTheme.muted,
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
          _ProposalChip(icon: Icons.people_outline, label: '$capacity slots'),
          _ProposalChip(icon: Icons.account_tree_outlined, label: '$stageCount stages'),
          _ProposalChip(icon: Icons.payments_outlined, label: entryType == 'paid' ? 'Paid entry' : 'Free entry'),
          _ProposalChip(icon: Icons.card_giftcard_outlined, label: '₹$prizePool prize pool'),
        ]),
        const SizedBox(height: 10),
        if (opens != null)
          _ProposalInfo(icon: Icons.how_to_reg_outlined, label: 'Registration opens: ${opens.toLocal()}'),
        if (close != null)
          _ProposalInfo(icon: Icons.lock_clock_outlined, label: 'Registration closes: ${close.toLocal()}'),
        if (startsAt != null)
          _ProposalInfo(icon: Icons.event_outlined, label: 'Tournament starts: ${startsAt.toLocal()}'),
        if (stageNames.isNotEmpty)
          _ProposalInfo(icon: Icons.account_tree_outlined, label: 'Stage names: ${stageNames.join(' → ')}'),
        if (roadmap.isNotEmpty)
          _ProposalInfo(
            icon: Icons.groups_outlined,
            label: 'Roadmap: group size ${roadmap['group_size']}, ${roadmap['qualifiers_per_group']} qualifiers/group, ${roadmap['qualified_team_count']} qualified + ${roadmap['direct_invites']} direct invites → ${roadmap['next_round_team_count']} teams',
          ),
        _ProposalInfo(
          icon: Icons.rule_outlined,
          label: 'Rules: ${eventConfig['rules_source'] == 'standard' ? '${rulebook['title'] ?? 'Standard rulebook'} ${rulebook['version'] ?? ''}' : 'Custom rules'}',
        ),
        if (rules['custom_text'] != null)
          _ProposalInfo(icon: Icons.description_outlined, label: 'Custom rules: ${rules['custom_text']}'),
        if (scoring.isNotEmpty)
          _ProposalInfo(icon: Icons.calculate_outlined, label: 'Scoring configuration: ${scoring.entries.map((entry) => '${entry.key}: ${entry.value}').join(' · ')}'),
        if ((eventConfig['prize_distribution']?.toString() ?? '').isNotEmpty)
          _ProposalInfo(icon: Icons.card_giftcard_outlined, label: 'Prize distribution: ${eventConfig['prize_distribution']}'),
        if ((eventConfig['entry_fee']?.toString() ?? '').isNotEmpty)
          _ProposalInfo(icon: Icons.payments_outlined, label: 'Entry fee: ₹${eventConfig['entry_fee']}'),
        if ((proposal['banner_path']?.toString() ?? '').isNotEmpty || (eventConfig['banner_path']?.toString() ?? '').isNotEmpty)
          const _ProposalInfo(icon: Icons.image_outlined, label: 'Tournament banner uploaded'),
        if (sources.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text('Based on uploaded sources', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11)),
          const SizedBox(height: 4),
          ...sources.take(4).map((source) => _ProposalInfo(icon: Icons.description_outlined, label: source)),
        ],
        const SizedBox(height: 10),
        Text(
          isTournament
              ? 'Keep as Draft creates a private, editable event. Publish creates the tournament category and channels. Registration remains closed until you open it separately.'
              : 'Approving creates a DRAFT event only. It will not open registration or publish automatically.',
          style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.35),
        ),
        if (isTournament && (pending || draft)) ...[
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: proposal['draft_kept'] == true
                  ? const Text('PRIVATE DRAFT SAVED', style: TextStyle(color: KomnivoTheme.cyan, fontSize: 10, fontWeight: FontWeight.w900))
                  : OutlinedButton(
                      onPressed: busy ? null : onKeepDraft,
                      child: Text(busy ? 'Saving…' : 'Keep as Draft'),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : onPublish,
                icon: const Icon(Icons.campaign_outlined),
                label: Text(busy ? 'Publishing…' : 'Publish Tournament'),
              ),
            ),
          ]),
        ] else if (!isTournament && pending) ...[
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
        ] else if (isTournament && status == 'published') ...[
          const SizedBox(height: 8),
          const Text('Published successfully. Registration has not been opened.', style: TextStyle(color: KomnivoTheme.cyan, fontSize: 11, fontWeight: FontWeight.w700)),
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
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xFF29234B),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: KomnivoTheme.line),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: KomnivoTheme.cyan),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
    ]),
  );
}

class _ProposalInfo extends StatelessWidget {
  const _ProposalInfo({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 13, color: KomnivoTheme.muted),
      const SizedBox(width: 7),
      Expanded(child: Text(label, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.35))),
    ]),
  );
}
), '');
    const affirmative = {
      'yes', 'y', 'yeah', 'yep', 'haan', 'han', 'ha', 'ji haan',
      'publish', 'publish tournament', 'yes publish', 'haan publish', 'sure', 'go ahead', 'confirm', 'ok publish', 'okay publish', 'publish it',
      'haan publish karo', 'haan publish kar do', 'publish kar do',
      'go ahead and publish', 'confirm publish', 'kar do',
    };
    const negative = {
      'no', 'n', 'nope', 'nahi', 'nahin', 'na', 'draft',
      'keep draft', 'keep as draft', 'save as draft', 'draft rakho',
      'draft hi rakho', 'publish mat karo', 'not now', 'not yet', 'later', 'baad mein', 'abhi nahi', 'keep it private',
    };
    final decision = affirmative.contains(normalized)
        ? 'publish'
        : negative.contains(normalized)
            ? 'keep_draft'
            : null;
    if (decision == null || !_showOrganizerActions) return false;

    final actionable = _items
        .where((item) => item.proposal?['workflow_type'] == 'tournament')
        .where((item) => ['pending_approval', 'approved', 'draft']
            .contains(item.proposal?['status']?.toString()))
        .toList();
    if (actionable.isEmpty) return false;

    setState(() {
      _items.add(_ChatItem(true, message));
      if (_input.text.isNotEmpty) _input.clear();
    });
    if (actionable.length != 1) {
      _showActionMessage(
        'There are multiple unpublished tournament drafts in this chat. Use the Publish Tournament or Keep as Draft button on the exact tournament card you mean. I have not changed any tournament.',
      );
      return true;
    }
    final proposalId = actionable.single.proposal?['id']?.toString();
    if (proposalId == null || proposalId.isEmpty) {
      _showActionMessage(
        'I could not identify the saved tournament draft. Nothing was published. Please use the action on its preview card.',
      );
      return true;
    }
    await _resolveProposal(proposalId, decision);
    return true;
  }

  Future<void> _sendMessage(String message, {String? communityId}) async {
    if (message.isEmpty || _sending || _restoring) return;
    if (await _handleTournamentConfirmation(message)) return;
    final selectedCommunityId = communityId ?? _activeCommunityId ?? widget.communityId;
    setState(() {
      _sending = true;
      _items.add(_ChatItem(true, message));
      if (communityId != null) _activeCommunityId = communityId;
      if (_input.text.isNotEmpty) _input.clear();
    });
    _scrollToBottom();

    try {
      final response = await Supabase.instance.client.functions.invoke(
        'komnivo-ai',
        body: {
          'mode': widget.mode,
          'message': message,
          if (_conversationId != null) 'conversation_id': _conversationId,
          if (selectedCommunityId != null) 'community_id': selectedCommunityId,
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
    Map<String, dynamic>? selectedProposal;
    for (final item in _items) {
      if (item.proposal?['id']?.toString() == proposalId) {
        selectedProposal = item.proposal;
        break;
      }
    }
    if (selectedProposal == null) return;
    final proposalDetails = selectedProposal;
    final isStructuredTournament = proposalDetails['workflow_type'] == 'tournament';
    final keepAsDraft = decision == 'keep_draft';
    final publish = decision == 'publish';
    final eventAlreadyDraft = isStructuredTournament &&
        (proposalDetails['status'] == 'draft' || proposalDetails['status'] == 'approved');
    if (keepAsDraft && eventAlreadyDraft) {
      final index = _items.indexWhere((item) => item.proposal?['id']?.toString() == proposalId);
      if (index >= 0) {
        final current = _items[index];
        setState(() => _items[index] = current.copyWith(proposal: {
          ...?current.proposal,
          'status': 'draft',
          'draft_kept': true,
        }));
      }
      setState(() => _items.add(_ChatItem(
        false,
        'Tournament “${proposalDetails['name'] ?? 'event'}” is already saved as a private DRAFT. No public channels or player notifications were created. Publish it later when ready.',
      )));
      return;
    }
    setState(() => _resolvingProposalId = proposalId);
    try {
      final response = await Supabase.instance.client.functions.invoke(
        isStructuredTournament ? 'organizer-tournament-workflow' : 'komnivo-ai-proposal-action',
        body: isStructuredTournament
            ? {
                'action': publish ? 'publish_proposal' : 'resolve_proposal',
                'community_id': proposalDetails['community_id'],
                'proposal_id': proposalId,
                if (!publish) 'decision': keepAsDraft ? 'approve' : decision,
              }
            : {'proposal_id': proposalId, 'decision': decision},
      );
      final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : <String, dynamic>{};
      if (response.status < 200 || response.status >= 300) {
        throw Exception(data['error']?.toString() ?? 'Tournament action failed.');
      }
      if (!mounted) return;

      final index = _items.indexWhere((item) => item.proposal?['id']?.toString() == proposalId);
      if (index >= 0) {
        final current = _items[index];
        final updatedProposal = <String, dynamic>{
          ...?current.proposal,
          'status': decision == 'reject'
              ? 'rejected'
              : publish
                  ? 'published'
                  : isStructuredTournament
                      ? 'draft'
                      : 'executed',
          'result': data,
          if (data['event_id'] != null) 'event_id': data['event_id'],
          if (data['channels'] is List) 'published_channels': data['channels'],
        };
        setState(() => _items[index] = current.copyWith(proposal: updatedProposal));
      }

      if (publish) {
        final channels = data['channels'] is List ? (data['channels'] as List).length : 0;
        setState(() => _items.add(_ChatItem(
          false,
          'Tournament “${data['name'] ?? proposalDetails['name'] ?? 'event'}” published. Its tournament category and $channels channels are ready. Registration is still closed; open it separately when the schedule and registration setup are ready.',
        )));
      } else if (keepAsDraft) {
        setState(() => _items.add(_ChatItem(
          false,
          'Tournament “${data['name'] ?? proposalDetails['name'] ?? 'event'}” is saved as a private DRAFT. No public tournament channels or player notifications were created. You can publish it later from this chat.',
        )));
      } else if (decision == 'reject') {
        setState(() => _items.add(const _ChatItem(false, 'Proposal rejected. No event was created.')));
      } else {
        setState(() => _items.add(_ChatItem(
          false,
          'Draft event “${data['name'] ?? 'event'}” has been created. It is not published yet.',
        )));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _items.add(_ChatItem(
          false,
          'Tournament action could not be completed. ${error.toString().replaceFirst("Exception: ", "")}',
          isError: true,
        )));
      }
    } finally {
      if (mounted) setState(() => _resolvingProposalId = null);
    }
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
              'Authorised organiser data stays in chat. Tournament writes use a structured form and explicit approval.',
              style: TextStyle(color: KomnivoTheme.muted, fontSize: 11),
            ),
          ),
        if (_showOrganizerActions)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: OrganizerChatActions(
              tournamentEnabled: !_sending && !_restoring && !_loadingManagedCommunities,
              paidScrimEnabled: !_sending && !_restoring,
              onCreateTournament: _openTournamentForm,
              onCreatePaidScrim: _showPaidScrimComingSoon,
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
                    onKeepDraft: () => _resolveProposal(item.proposal!['id'].toString(), 'keep_draft'),
                    onPublish: () => _resolveProposal(item.proposal!['id'].toString(), 'publish'),
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
            padding: const EdgeInsets.fromLTRB(12, 5, 12, 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
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
            ]),
          ),
        ),
      ]),
    );
  }
}

class OrganizerChatActions extends StatelessWidget {
  const OrganizerChatActions({
    super.key,
    required this.tournamentEnabled,
    required this.paidScrimEnabled,
    required this.onCreateTournament,
    required this.onCreatePaidScrim,
  });

  final bool tournamentEnabled;
  final bool paidScrimEnabled;
  final VoidCallback onCreateTournament;
  final VoidCallback onCreatePaidScrim;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('organizer-chat-actions-panel'),
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: KomnivoTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: KomnivoTheme.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ORGANIZER QUICK ACTIONS',
            style: TextStyle(
              color: KomnivoTheme.muted,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: .7,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 7,
            children: [
              OutlinedButton.icon(
                key: const Key('organizer-create-tournament'),
                onPressed: tournamentEnabled ? onCreateTournament : null,
                icon: const Icon(Icons.emoji_events_outlined, size: 17),
                label: const Text('Create Tournament'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: KomnivoTheme.cyan,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                ),
              ),
              OutlinedButton.icon(
                key: const Key('organizer-create-paid-scrim'),
                onPressed: paidScrimEnabled ? onCreatePaidScrim : null,
                icon: const Icon(Icons.payments_outlined, size: 17),
                label: const Text('Create Paid Scrim'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: KomnivoTheme.accent,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChatItem {
  const _ChatItem(
    this.fromUser,
    this.text, {
    this.isError = false,
    this.proposal,
  });

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
    required this.onKeepDraft,
    required this.onPublish,
  });

  final Map<String, dynamic> proposal;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onKeepDraft;
  final VoidCallback onPublish;

  @override
  Widget build(BuildContext context) {
    final status = proposal['status']?.toString() ?? 'pending_approval';
    final isTournament = proposal['workflow_type'] == 'tournament';
    final name = proposal['name']?.toString() ?? 'Tournament';
    final format = proposal['format']?.toString() ?? 'squad';
    final capacity = proposal['capacity']?.toString() ?? '—';
    final game = proposal['game_name']?.toString() ?? 'Game';
    final startsAt = DateTime.tryParse(proposal['starts_at']?.toString() ?? '');
    final close = DateTime.tryParse(proposal['registration_closes_at']?.toString() ?? '');
    final eventConfig = proposal['event_config'] is Map
        ? Map<String, dynamic>.from(proposal['event_config'] as Map)
        : <String, dynamic>{};
    final entryType = eventConfig['entry_type']?.toString() ?? 'free';
    final stageCount = eventConfig['stage_count']?.toString() ?? '—';
    final prizePool = eventConfig['prize_pool_amount']?.toString() ?? '0';
    final sources = proposal['source_refs'] is List
        ? (proposal['source_refs'] as List).whereType<Map>().map((row) {
            final file = row['document']?.toString() ?? '';
            final source = row['source']?.toString() ?? '';
            return [file, source].where((part) => part.isNotEmpty).join(' — ');
          }).where((value) => value.isNotEmpty).toList()
        : <String>[];
    final pending = status == 'pending_approval';
    final draft = status == 'draft' || status == 'approved';

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
          Expanded(child: Text(
            isTournament ? 'TOURNAMENT PREVIEW' : 'EVENT DRAFT PROPOSAL',
            style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.8, fontSize: 11),
          )),
          Text(
            status.replaceAll('_', ' ').toUpperCase(),
            style: TextStyle(
              color: status == 'published' ? KomnivoTheme.cyan : KomnivoTheme.muted,
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
          _ProposalChip(icon: Icons.people_outline, label: '$capacity slots'),
          _ProposalChip(icon: Icons.account_tree_outlined, label: '$stageCount stages'),
          _ProposalChip(icon: Icons.payments_outlined, label: entryType == 'paid' ? 'Paid entry' : 'Free entry'),
          _ProposalChip(icon: Icons.card_giftcard_outlined, label: '₹$prizePool prize pool'),
        ]),
        const SizedBox(height: 10),
        if (startsAt != null)
          _ProposalInfo(icon: Icons.event_outlined, label: 'Matches start: ${startsAt.toLocal()}'),
        if (close != null)
          _ProposalInfo(icon: Icons.lock_clock_outlined, label: 'Registration closes: ${close.toLocal()}'),
        if (sources.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text('Based on uploaded sources', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11)),
          const SizedBox(height: 4),
          ...sources.take(4).map((source) => _ProposalInfo(icon: Icons.description_outlined, label: source)),
        ],
        const SizedBox(height: 10),
        Text(
          isTournament
              ? 'Keep as Draft creates a private, editable event. Publish creates the tournament category and channels. Registration remains closed until you open it separately.'
              : 'Approving creates a DRAFT event only. It will not open registration or publish automatically.',
          style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.35),
        ),
        if (isTournament && (pending || draft)) ...[
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: proposal['draft_kept'] == true
                  ? const Text('PRIVATE DRAFT SAVED', style: TextStyle(color: KomnivoTheme.cyan, fontSize: 10, fontWeight: FontWeight.w900))
                  : OutlinedButton(
                      onPressed: busy ? null : onKeepDraft,
                      child: Text(busy ? 'Saving…' : 'Keep as Draft'),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : onPublish,
                icon: const Icon(Icons.campaign_outlined),
                label: Text(busy ? 'Publishing…' : 'Publish Tournament'),
              ),
            ),
          ]),
        ] else if (!isTournament && pending) ...[
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
        ] else if (isTournament && status == 'published') ...[
          const SizedBox(height: 8),
          const Text('Published successfully. Registration has not been opened.', style: TextStyle(color: KomnivoTheme.cyan, fontSize: 11, fontWeight: FontWeight.w700)),
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
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xFF29234B),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: KomnivoTheme.line),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: KomnivoTheme.cyan),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
    ]),
  );
}

class _ProposalInfo extends StatelessWidget {
  const _ProposalInfo({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 13, color: KomnivoTheme.muted),
      const SizedBox(width: 7),
      Expanded(child: Text(label, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.35))),
    ]),
  );
}
