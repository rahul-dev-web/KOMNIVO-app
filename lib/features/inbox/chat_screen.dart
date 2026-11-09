import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.channel});
  final Map<String, dynamic> channel;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _searchController = TextEditingController();
  bool _sending = false;
  bool _searching = false;
  PlatformFile? _attachment;
  Map<String, dynamic>? _replyTo;

  String get _channelId => widget.channel['id'] as String;
  String get _userId => Supabase.instance.client.auth.currentUser!.id;

  Future<void> _pickAttachment() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'pdf'],
      );
      if (file == null || !mounted) return;
      setState(() => _attachment = file);
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    final attachment = _attachment;
    if (_sending || (text.isEmpty && attachment == null)) return;

    setState(() => _sending = true);
    final parentId = _replyTo?['id'] as String?;
    try {
      if (text.isNotEmpty) {
        await KomnivoRepository.instance.sendMessage(
          _channelId,
          text,
          parentMessageId: parentId,
        );
      }
      if (attachment != null) {
        await KomnivoRepository.instance.sendMessageAttachment(
          _channelId,
          attachment,
          parentMessageId: parentId,
        );
      }
      _controller.clear();
      if (mounted) setState(() { _attachment = null; _replyTo = null; });
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _reply(Map<String, dynamic> message) {
    setState(() {
      _replyTo = message;
      _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final channelName = widget.channel['name']?.toString() ?? 'chat';
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          const Icon(Icons.tag, color: KomnivoTheme.cyan, size: 19),
          const SizedBox(width: 6),
          Expanded(child: Text(channelName, overflow: TextOverflow.ellipsis)),
        ]),
        actions: [
          IconButton(
            tooltip: _searching ? 'Close search' : 'Search messages',
            onPressed: () => setState(() {
              _searching = !_searching;
              _searchController.clear();
            }),
            icon: Icon(_searching ? Icons.close : Icons.search),
          ),
        ],
      ),
      body: Column(children: [
        if (_searching)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search in this channel…',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: KomnivoRepository.instance.messageStream(_channelId),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(snapshot.error.toString())));
              }
              final query = _searchController.text.trim().toLowerCase();
              final allMessages = snapshot.data ?? [];
              final messages = query.isEmpty
                  ? allMessages
                  : allMessages.where((message) => (message['body'] ?? '').toString().toLowerCase().contains(query)).toList();

              if (snapshot.connectionState == ConnectionState.waiting && messages.isEmpty) {
                return const Center(child: CircularProgressIndicator());
              }
              if (messages.isEmpty) {
                return EmptyState(
                  title: query.isNotEmpty ? 'No matching messages' : 'Start the conversation',
                  message: query.isNotEmpty
                      ? 'Try another word or phrase.'
                      : 'Coordinate matches, share updates and keep your community in one place.',
                  icon: Icons.forum_outlined,
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(14, 16, 14, 22),
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final message = messages[index];
                  final mine = message['sender_id'] == _userId;
                  return _MessageBubble(
                    message: message,
                    mine: mine,
                    onReply: () => _reply(message),
                  );
                },
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            decoration: const BoxDecoration(
              color: KomnivoTheme.background,
              border: Border(top: BorderSide(color: KomnivoTheme.line)),
            ),
            child: Column(children: [
              if (_replyTo != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                  decoration: BoxDecoration(
                    color: KomnivoTheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: const Border(left: BorderSide(color: KomnivoTheme.accent, width: 3)),
                  ),
                  child: Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Replying to message', style: TextStyle(color: KomnivoTheme.cyan, fontSize: 10, fontWeight: FontWeight.w800)),
                      Text((_replyTo!['body'] ?? '').toString(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 12)),
                    ])),
                    IconButton(onPressed: () => setState(() => _replyTo = null), icon: const Icon(Icons.close, size: 18)),
                  ]),
                ),
              if (_attachment != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(10)),
                  child: Row(children: [
                    const Icon(Icons.attach_file, color: KomnivoTheme.cyan, size: 18),
                    const SizedBox(width: 7),
                    Expanded(child: Text(_attachment!.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _attachment = null),
                      icon: const Icon(Icons.close, size: 17),
                    ),
                  ]),
                ),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                IconButton(
                  tooltip: 'Attach image or PDF',
                  onPressed: _sending ? null : _pickAttachment,
                  icon: const Icon(Icons.attach_file, color: KomnivoTheme.cyan),
                ),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: 'Message #$channelName',
                      filled: true,
                      fillColor: KomnivoTheme.surfaceRaised,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: KomnivoTheme.accent)),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send_rounded),
                ),
              ]),
              const SizedBox(height: 3),
              const Text('Keep personal or sensitive information out of public channels.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.mine,
    required this.onReply,
  });
  final Map<String, dynamic> message;
  final bool mine;
  final VoidCallback onReply;

  @override
  Widget build(BuildContext context) {
    final sender = mine ? 'You' : 'Community member';
    final body = message['body']?.toString() ?? '';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.only(bottom: 9),
        padding: const EdgeInsets.fromLTRB(13, 10, 9, 9),
        decoration: BoxDecoration(
          color: mine ? const Color(0xFF302653) : KomnivoTheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: KomnivoTheme.line),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(child: Text(sender, style: const TextStyle(color: KomnivoTheme.cyan, fontWeight: FontWeight.w800, fontSize: 11))),
            const SizedBox(width: 8),
            PopupMenuButton<String>(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 150),
              tooltip: 'Message actions',
              iconSize: 17,
              icon: const Icon(Icons.more_horiz, color: KomnivoTheme.muted),
              onSelected: (value) async {
                if (value == 'reply') onReply();
                if (value == 'copy') {
                  await Clipboard.setData(ClipboardData(text: body));
                  if (context.mounted) showMessage(context, 'Message copied.');
                }
                if (value.startsWith('react:')) {
                  try {
                    await KomnivoRepository.instance.toggleMessageReaction(
                      message['id'] as String,
                      value.substring(6),
                    );
                  } catch (error) {
                    if (context.mounted) showMessage(context, error.toString());
                  }
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'reply', child: Text('Reply')),
                PopupMenuItem(value: 'copy', child: Text('Copy text')),
                PopupMenuDivider(),
                PopupMenuItem(value: 'react:👍', child: Text('👍 React')),
                PopupMenuItem(value: 'react:❤️', child: Text('❤️ React')),
                PopupMenuItem(value: 'react:🔥', child: Text('🔥 React')),
                PopupMenuItem(value: 'react:😂', child: Text('😂 React')),
              ],
            ),
          ]),
          if (message['parent_message_id'] != null) ...[
            const SizedBox(height: 3),
            const Text('↳ Reply in this conversation', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
          ],
          const SizedBox(height: 3),
          SelectableText(body, style: const TextStyle(height: 1.35)),
          const SizedBox(height: 7),
          _MessageAttachmentList(messageId: message['id'] as String),
          _MessageReactionBar(messageId: message['id'] as String),
        ]),
      ),
    );
  }
}

class _MessageAttachmentList extends StatefulWidget {
  const _MessageAttachmentList({required this.messageId});
  final String messageId;
  @override
  State<_MessageAttachmentList> createState() => _MessageAttachmentListState();
}

class _MessageAttachmentListState extends State<_MessageAttachmentList> {
  late Future<List<Map<String, dynamic>>> _future;
  @override
  void initState() {
    super.initState();
    _future = KomnivoRepository.instance.messageAttachments(widget.messageId);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, dynamic>>>(
    future: _future,
    builder: (context, snapshot) {
      final rows = snapshot.data ?? [];
      if (rows.isEmpty) return const SizedBox.shrink();
      return Column(children: rows.map((row) => _AttachmentItem(row: row)).toList());
    },
  );
}

class _AttachmentItem extends StatefulWidget {
  const _AttachmentItem({required this.row});
  final Map<String, dynamic> row;
  @override
  State<_AttachmentItem> createState() => _AttachmentItemState();
}

class _AttachmentItemState extends State<_AttachmentItem> {
  late Future<String> _url;
  @override
  void initState() {
    super.initState();
    _url = KomnivoRepository.instance.messageAttachmentUrl(widget.row['storage_path'] as String);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: _url,
    builder: (context, snapshot) {
      if (!snapshot.hasData) return const Padding(
        padding: EdgeInsets.only(top: 6),
        child: Row(children: [SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5)), SizedBox(width: 7), Text('Loading attachment…', style: TextStyle(color: KomnivoTheme.muted, fontSize: 10))]),
      );
      final url = snapshot.data!;
      final type = widget.row['content_type']?.toString() ?? '';
      final isImage = type.startsWith('image/');
      final name = (widget.row['storage_path'] ?? '').toString().split('/').last;
      return Container(
        width: 280,
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: KomnivoTheme.surfaceRaised, borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (isImage)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(url, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined)),
            )
          else
            const Icon(Icons.picture_as_pdf_outlined, color: KomnivoTheme.cyan, size: 24),
          const SizedBox(height: 5),
          Row(children: [
            Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: KomnivoTheme.muted))),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Open attachment',
              onPressed: () async {
                final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                if (!ok && context.mounted) showMessage(context, 'Could not open this attachment.');
              },
              icon: const Icon(Icons.open_in_new, size: 16, color: KomnivoTheme.cyan),
            ),
          ]),
        ]),
      );
    },
  );
}

class _MessageReactionBar extends StatefulWidget {
  const _MessageReactionBar({required this.messageId});
  final String messageId;
  @override
  State<_MessageReactionBar> createState() => _MessageReactionBarState();
}

class _MessageReactionBarState extends State<_MessageReactionBar> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _future = KomnivoRepository.instance.messageReactions(widget.messageId);
  }

  Future<void> _toggle(String emoji) async {
    try {
      await KomnivoRepository.instance.toggleMessageReaction(widget.messageId, emoji);
      if (mounted) setState(_reload);
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, dynamic>>>(
    future: _future,
    builder: (context, snapshot) {
      final rows = snapshot.data ?? [];
      final counts = <String, int>{};
      for (final row in rows) {
        final emoji = row['emoji']?.toString() ?? '';
        counts[emoji] = (counts[emoji] ?? 0) + 1;
      }
      if (counts.isEmpty) {
        return Align(
          alignment: Alignment.centerLeft,
          child: Wrap(spacing: 4, children: [
            for (final emoji in ['👍', '❤️', '🔥'])
              InkWell(
                onTap: () => _toggle(emoji),
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
                  child: Text(emoji, style: const TextStyle(fontSize: 13)),
                ),
              ),
          ]),
        );
      }
      return Align(
        alignment: Alignment.centerLeft,
        child: Wrap(spacing: 5, children: counts.entries.map((entry) => ActionChip(
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          label: Text('${entry.key} ${entry.value}', style: const TextStyle(fontSize: 10)),
          onPressed: () => _toggle(entry.key),
        )).toList()),
      );
    },
  );
}
