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

      final messages = await client.from('ai_messages')
          .select('role,content')
          .eq('conversation_id', conversationId)
          .inFilter('role', ['user', 'assistant'])
          .order('created_at')
          .limit(60);
      if (!mounted) return;

      setState(() {
        _conversationId = conversationId;
        _items
          ..clear()
          ..addAll(List<Map<String, dynamic>>.from(messages).map((row) {
            return _ChatItem(
              row['role'] == 'user',
              row['content']?.toString() ?? '',
            );
          }));
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
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'docx', 'xlsx', 'xls', 'csv', 'txt', 'md', 'png', 'jpg', 'jpeg', 'webp'],
        allowMultiple: false,
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) return;

      final file = picked.files.single;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
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
      if (!mounted) return;
      setState(() => _items.add(_ChatItem(false, reply)));
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
  const _ChatItem(this.fromUser, this.text, {this.isError = false});
  final bool fromUser;
  final String text;
  final bool isError;
}
