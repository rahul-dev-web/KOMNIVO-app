import 'package:flutter/material.dart';

import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';

class ForumChannelScreen extends StatefulWidget {
  const ForumChannelScreen({
    super.key,
    required this.channel,
    this.canModerate = false,
  });
  final Map<String, dynamic> channel;
  final bool canModerate;

  @override
  State<ForumChannelScreen> createState() => _ForumChannelScreenState();
}

class _ForumChannelScreenState extends State<ForumChannelScreen> {
  String _query = '';
  String _status = 'All';
  String _tag = 'All tags';
  late final List<Map<String, dynamic>> _posts;

  @override
  void initState() {
    super.initState();
    _posts = [
      {'title': 'Looking for two players for tonight', 'body': 'Need two reliable players for a squad. Share your role and availability.', 'tag': 'Recruitment', 'status': 'Open', 'author': 'RDX_Ace', 'replies': 8, 'time': '12 min ago', 'pinned': true, 'locked': false},
      {'title': 'Scrim schedule discussion', 'body': 'Can we agree on a practice window for this weekend?', 'tag': 'Scrims', 'status': 'In discussion', 'author': 'Nova', 'replies': 14, 'time': '38 min ago', 'pinned': false, 'locked': false},
      {'title': 'Support with voice setup', 'body': 'Microphone permissions are not appearing on my device.', 'tag': 'Support', 'status': 'Filled', 'author': 'Kairo', 'replies': 3, 'time': 'Yesterday', 'pinned': false, 'locked': false},
      {'title': 'Team recruitment closed', 'body': 'The roster is complete. Thanks to everyone who responded.', 'tag': 'Recruitment', 'status': 'Closed', 'author': 'IGL_Lead', 'replies': 6, 'time': 'Yesterday', 'pinned': false, 'locked': true},
    ];
  }

  String get _name => widget.channel['name']?.toString() ?? 'forum';

  Color _statusColor(String status) {
    switch (status) {
      case 'Filled': return const Color(0xFF54C9A5);
      case 'Closed': return KomnivoTheme.muted;
      case 'In discussion': return KomnivoTheme.cyan;
      default: return KomnivoTheme.accent;
    }
  }

  Widget _pill(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(30), border: Border.all(color: color.withValues(alpha: .24))),
    child: Text(text, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: color)),
  );

  @override
  Widget build(BuildContext context) {
    final rows = _posts.where((post) {
      final query = _query.trim().toLowerCase();
      final inText = query.isEmpty || post['title'].toString().toLowerCase().contains(query) || post['body'].toString().toLowerCase().contains(query);
      final inStatus = _status == 'All' || post['status'] == _status;
      final inTag = _tag == 'All tags' || post['tag'] == _tag;
      return inText && inStatus && inTag;
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          const Icon(Icons.forum_outlined, color: KomnivoTheme.accent, size: 19),
          const SizedBox(width: 7),
          Expanded(child: Text(_name, overflow: TextOverflow.ellipsis)),
        ]),
        actions: [
          IconButton(tooltip: 'Forum information', onPressed: _showGuidelines, icon: const Icon(Icons.info_outline)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newPost,
        icon: const Icon(Icons.add),
        label: const Text('New post'),
      ),
      body: Column(children: [
        Container(
          margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(color: KomnivoTheme.surfaceRaised, borderRadius: BorderRadius.circular(13), border: Border.all(color: KomnivoTheme.accent.withValues(alpha: .24))),
          child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.topic_outlined, color: KomnivoTheme.accent, size: 18),
            SizedBox(width: 9),
            Expanded(child: Text('A topic-first space. Start one discussion per subject, add a tag and update its status as it progresses.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.4))),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search topics…'),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        SizedBox(
          height: 46,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            scrollDirection: Axis.horizontal,
            children: [
              for (final status in ['All', 'Open', 'In discussion', 'Filled', 'Closed'])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(label: Text(status), selected: _status == status, onSelected: (_) => setState(() => _status = status)),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: DropdownButtonFormField<String>(
            value: _tag,
            decoration: const InputDecoration(labelText: 'Tag filter', isDense: true),
            items: const ['All tags', 'LFG', 'Recruitment', 'Scrims', 'Support', 'Suggestions'].map((tag) => DropdownMenuItem(value: tag, child: Text(tag))).toList(),
            onChanged: (value) => setState(() => _tag = value ?? 'All tags'),
          ),
        ),
        Expanded(
          child: rows.isEmpty
            ? const EmptyState(title: 'No matching topics', message: 'Try another filter or start a new post.', icon: Icons.forum_outlined)
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(14, 2, 14, 90),
                itemCount: rows.length,
                itemBuilder: (context, index) => _postCard(rows[index]),
              ),
        ),
      ]),
    );
  }

  Widget _postCard(Map<String, dynamic> post) => Container(
    margin: const EdgeInsets.only(bottom: 9),
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(15), border: Border.all(color: KomnivoTheme.line)),
    child: InkWell(
      onTap: () => _openPost(post),
      borderRadius: BorderRadius.circular(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _pill(post['status'].toString(), _statusColor(post['status'].toString())),
          const SizedBox(width: 6),
          _pill(post['tag'].toString(), KomnivoTheme.cyan),
          if (post['pinned'] == true) ...[
            const SizedBox(width: 6),
            _pill('Pinned', KomnivoTheme.accent),
          ],
          if (post['locked'] == true) ...[
            const SizedBox(width: 6),
            const Icon(Icons.lock_outline, color: KomnivoTheme.muted, size: 13),
          ],
          const Spacer(),
          if (widget.canModerate)
            PopupMenuButton<String>(
              onSelected: (value) {
                setState(() {
                  if (value == 'pin') {
                    post['pinned'] = post['pinned'] != true;
                  } else if (value == 'lock') {
                    post['locked'] = post['locked'] != true;
                  } else {
                    post['status'] = value;
                    if (value == 'Closed') post['locked'] = true;
                    if (value == 'Open') post['locked'] = false;
                  }
                });
                showMessage(context, 'Forum moderation preview updated. Persistent actions connect in the backend phase.');
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'pin', child: Text(post['pinned'] == true ? 'Unpin topic' : 'Pin topic')),
                PopupMenuItem(value: 'lock', child: Text(post['locked'] == true ? 'Unlock replies' : 'Lock replies')),
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'Open', child: Text('Reopen topic')),
                const PopupMenuItem(value: 'In discussion', child: Text('Move to discussion')),
                const PopupMenuItem(value: 'Filled', child: Text('Mark filled')),
                const PopupMenuItem(value: 'Closed', child: Text('Close topic')),
              ],
            ),
        ]),
        const SizedBox(height: 7),
        Text(post['title'].toString(), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900)),
        const SizedBox(height: 5),
        Text(post['body'].toString(), maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.4)),
        const SizedBox(height: 10),
        Row(children: [
          const Icon(Icons.person_outline, size: 14, color: KomnivoTheme.muted),
          const SizedBox(width: 4),
          Text(post['author'].toString(), style: const TextStyle(fontSize: 9, color: KomnivoTheme.muted)),
          const SizedBox(width: 12),
          const Icon(Icons.chat_bubble_outline, size: 14, color: KomnivoTheme.muted),
          const SizedBox(width: 4),
          Text(post['replies'].toString() + ' replies', style: const TextStyle(fontSize: 9, color: KomnivoTheme.muted)),
          const Spacer(),
          Text(post['time'].toString(), style: const TextStyle(fontSize: 8, color: KomnivoTheme.muted)),
          const SizedBox(width: 3),
          const Icon(Icons.chevron_right, size: 16, color: KomnivoTheme.muted),
        ]),
      ]),
    ),
  );

  Future<void> _newPost() async {
    final title = TextEditingController();
    final body = TextEditingController();
    String tag = 'LFG';
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (context, setDialogState) => AlertDialog(
        title: const Text('Create Forum post'),
        content: SizedBox(width: 440, child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: title, autofocus: true, maxLength: 100, decoration: const InputDecoration(labelText: 'Topic title')),
          TextField(controller: body, maxLength: 1200, minLines: 3, maxLines: 5, decoration: const InputDecoration(labelText: 'Details')),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: tag,
            decoration: const InputDecoration(labelText: 'Tag'),
            items: const ['LFG', 'Recruitment', 'Scrims', 'Support', 'Suggestions'].map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(),
            onChanged: (value) => setDialogState(() => tag = value ?? tag),
          ),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, {'title': title.text.trim(), 'body': body.text.trim(), 'tag': tag}), child: const Text('Preview post')),
        ],
      )),
    );
    title.dispose();
    body.dispose();
    if (result == null || (result['title'] ?? '').length < 3) return;
    setState(() => _posts.insert(0, {
      'title': result['title']!,
      'body': result['body'] ?? '',
      'tag': result['tag'] ?? 'LFG',
      'status': 'Open',
      'author': 'You',
      'replies': 0,
      'time': 'Just now',
      'pinned': false,
      'locked': false,
    }));
    showMessage(context, 'Post preview added. Publishing will be connected in the backend phase.');
  }

  Future<void> _openPost(Map<String, dynamic> post) async {
    final reply = TextEditingController();
    final preview = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: KomnivoTheme.surface,
      builder: (sheetContext) => SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 18, 16, MediaQuery.viewInsetsOf(sheetContext).bottom + 18),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _pill(post['status'].toString(), _statusColor(post['status'].toString())),
            const SizedBox(width: 6),
            _pill(post['tag'].toString(), KomnivoTheme.cyan),
          ]),
          const SizedBox(height: 10),
          Text(post['title'].toString(), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
          const SizedBox(height: 7),
          Text(post['body'].toString(), style: const TextStyle(fontSize: 11, height: 1.45)),
          const SizedBox(height: 12),
          const Divider(),
          const Text('Replies', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          const _Reply(author: 'Nova', body: 'I can join after 7 PM.'),
          const _Reply(author: 'RDX_Ace', body: 'Share your preferred role and availability.'),
          const SizedBox(height: 10),
          if (post['locked'] == true || post['status'] == 'Closed')
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                Icon(Icons.lock_outline, size: 15, color: KomnivoTheme.muted),
                SizedBox(width: 7),
                Expanded(child: Text('Replies are locked for this topic.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 10))),
              ]),
            )
          else ...[
            TextField(controller: reply, minLines: 1, maxLines: 3, decoration: const InputDecoration(hintText: 'Write a reply…')),
            const SizedBox(height: 10),
            Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: () => Navigator.pop(sheetContext, reply.text.trim().isNotEmpty), child: const Text('Preview reply'))),
          ],
          ]),
        ),
      ),
    );
    reply.dispose();
    if (preview == true && mounted) {
      setState(() => post['replies'] = (post['replies'] as int? ?? 0) + 1);
      showMessage(context, 'Reply preview added. It has not been published.');
    }
  }

  void _showGuidelines() => showModalBottomSheet<void>(
    context: context,
    backgroundColor: KomnivoTheme.surface,
    builder: (sheetContext) => const Padding(
      padding: EdgeInsets.all(20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Forum guidelines', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
        SizedBox(height: 10),
        _Guideline(text: 'Use one topic per post and add the closest matching tag.'),
        _Guideline(text: 'Update status when a request is filled or no longer active.'),
        _Guideline(text: 'Keep recruitment, support and scrim discussion in their relevant forum.'),
        _Guideline(text: 'Moderation actions must follow the role and channel permission rules.'),
        SizedBox(height: 10),
      ]),
    ),
  );
}

class _Reply extends StatelessWidget {
  const _Reply({required this.author, required this.body});
  final String author;
  final String body;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const CircleAvatar(radius: 12, child: Icon(Icons.person_outline, size: 14)),
      const SizedBox(width: 8),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(author, style: const TextStyle(color: KomnivoTheme.cyan, fontSize: 9, fontWeight: FontWeight.w800)),
        Text(body, style: const TextStyle(fontSize: 11)),
      ])),
    ]),
  );
}

class _Guideline extends StatelessWidget {
  const _Guideline({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.check_circle_outline, color: KomnivoTheme.cyan, size: 14),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.4))),
    ]),
  );
}
