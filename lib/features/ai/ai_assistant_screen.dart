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
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final message = _input.text.trim();
    if (message.isEmpty || _sending) return;
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
        'Request complete nahi ho saka. ${error.toString().replaceFirst('Exception: ', '')}',
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
            itemCount: _items.length + (_sending ? 1 : 0),
            itemBuilder: (context, index) {
              if (_sending && index == _items.length) {
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
              IconButton.filled(
                onPressed: _sending ? null : _send,
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
