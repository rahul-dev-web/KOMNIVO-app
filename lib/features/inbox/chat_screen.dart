import 'package:flutter/material.dart';

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
  bool _sending = false;

  Future<void> _send() async {
    if (_sending || _controller.text.trim().isEmpty) return;
    setState(() => _sending = true);
    try {
      await KomnivoRepository.instance.sendMessage(widget.channel['id'] as String, _controller.text);
      _controller.clear();
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('# ${widget.channel['name'] ?? 'chat'}')),
      body: Column(children: [
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: KomnivoRepository.instance.messageStream(widget.channel['id'] as String),
            builder: (context, snapshot) {
              final messages = snapshot.data ?? [];
              if (messages.isEmpty) return const EmptyState(title: 'Start the conversation', message: 'Keep match coordination and community chat in one place.', icon: Icons.forum_outlined);
              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final row = messages[index];
                  final mine = row['sender_id'] == KomnivoRepository.instance.userId;
                  return Align(
                    alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 520),
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: mine ? const Color(0xFF342A61) : KomnivoTheme.surface,
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(color: KomnivoTheme.line),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(mine ? 'You' : 'Community member', style: const TextStyle(color: KomnivoTheme.cyan, fontWeight: FontWeight.w800, fontSize: 11)),
                        const SizedBox(height: 4),
                        Text(row['body']?.toString() ?? ''),
                      ]),
                    ),
                  );
                },
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(children: [
              Expanded(child: TextField(controller: _controller, minLines: 1, maxLines: 4, decoration: const InputDecoration(hintText: 'Write a message…', prefixIcon: Icon(Icons.chat_bubble_outline)))),
              const SizedBox(width: 8),
              IconButton.filled(onPressed: _sending ? null : _send, icon: _sending ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send)),
            ]),
          ),
        ),
      ]),
    );
  }
}
