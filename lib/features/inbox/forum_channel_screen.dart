import 'package:flutter/material.dart';

import '../../core/komnivo_theme.dart';
import '../../core/komnivo_repository.dart';
import '../../core/ui.dart';

class ForumChannelScreen extends StatefulWidget {
  const ForumChannelScreen({
    super.key,
    required this.channel,
    this.canModerate = false,
    this.initialPosts = const [],
  });
  final Map<String, dynamic> channel;
  final bool canModerate;
  final List<Map<String, dynamic>> initialPosts;

  @override
  State<ForumChannelScreen> createState() => _ForumChannelScreenState();
}

class _ForumChannelScreenState extends State<ForumChannelScreen> {
  String _query = '';
  String _status = 'All';
  String _tag = 'All tags';
  List<Map<String, dynamic>> _posts = <Map<String, dynamic>>[];
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialPosts.isNotEmpty) {
      _posts = widget.initialPosts.map((row) => Map<String, dynamic>.from(row)).toList();
      _loading = false;
    } else {
      _loadPosts();
    }
  }

  Future<void> _loadPosts() async {
    try {
      final rows = await KomnivoRepository.instance.forumPosts(widget.channel['id'].toString());
      final mapped = rows.map((row) => <String, dynamic>{
        ...row,
        'author': row['author_id']?.toString() == KomnivoRepository.instance.userId
            ? 'You' : 'Member',
        'replies': 0,
        'time': _timeLabel(row['created_at']?.toString()),
        'pinned': row['is_pinned'] == true,
        'locked': row['is_locked'] == true,
      }).toList();
      if (mounted) setState(() { _posts = mapped; _loading = false; });
    } catch (error) {
      if (mounted) {
        setState(() => _loading = false);
        showMessage(context, 'Could not load forum posts: $error');
      }
    }
  }

  String _timeLabel(String? value) {
    if (value == null) return 'Recently';
    final date = DateTime.tryParse(value)?.toLocal();
    if (date == null) return 'Recently';
    final difference = DateTime.now().difference(date);
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inHours < 1) return '${difference.inMinutes} min ago';
    if (difference.inDays < 1) return '${difference.inHours} hr ago';
    return '${difference.inDays} d ago';
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
          child: _loading
            ? const Center(child: CircularProgressIndicator())
            : rows.isEmpty
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
              onSelected: (value) async {
                final id = post['id']?.toString();
                if (widget.initialPosts.isNotEmpty) {
                  setState(() {
                    if (value == 'pin') post['pinned'] = post['pinned'] != true;
                    else if (value == 'lock') post['locked'] = post['locked'] != true;
                    else { post['status'] = value; if (value == 'Closed') post['locked'] = true; if (value == 'Open') post['locked'] = false; }
                  });
                  return;
                }
                if (id == null) return;
                final nextStatus = const ['Open','In discussion','Filled','Closed'].contains(value)
                    ? value : post['status'].toString();
                final nextLocked = value == 'lock' ? post['locked'] != true
                    : value == 'Closed' ? true : value == 'Open' ? false : null;
                final nextPinned = value == 'pin' ? post['pinned'] != true : null;
                try {
                  await KomnivoRepository.instance.moderateForumPost(
                    postId: id, status: nextStatus, locked: nextLocked, pinned: nextPinned,
                  );
                  await _loadPosts();
                } catch (error) {
                  if (mounted) showMessage(context, 'Moderation failed: $error');
                }
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
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => const _ForumPostDraftDialog(),
    );
    if (result == null || (result['title'] ?? '').length < 3) return;
    if (widget.initialPosts.isNotEmpty) {
      setState(() => _posts.insert(0, {
        'title': result['title']!, 'body': result['body'] ?? '', 'tag': result['tag'] ?? 'LFG',
        'status': 'Open', 'author': 'You', 'replies': 0, 'time': 'Just now', 'pinned': false, 'locked': false,
      }));
      return;
    }
    final communityId = widget.channel['community_id']?.toString();
    if (communityId == null || communityId.isEmpty) {
      showMessage(context, 'This forum is not linked to a community.');
      return;
    }
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await KomnivoRepository.instance.createForumPost(
        channelId: widget.channel['id'].toString(),
        communityId: communityId,
        title: result['title']!,
        body: result['body'] ?? '',
        tag: result['tag'] ?? 'LFG',
      );
      await _loadPosts();
      if (mounted) showMessage(context, 'Forum post published.');
    } catch (error) {
      if (mounted) showMessage(context, 'Could not publish post: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openPost(Map<String, dynamic> post) async {
    final preview = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: KomnivoTheme.surface,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .88),
      builder: (_) => _ForumPostDetailSheet(
        post: post,
        statusColor: _statusColor(post['status'].toString()),
      ),
    );
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

class _ForumPostDraftDialog extends StatefulWidget {
  const _ForumPostDraftDialog();

  @override
  State<_ForumPostDraftDialog> createState() => _ForumPostDraftDialogState();
}

class _ForumPostDraftDialogState extends State<_ForumPostDraftDialog> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  String _tag = 'LFG';

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _submit() {
    if (_title.text.trim().length < 3) {
      showMessage(context, 'Enter a topic title with at least 3 characters.');
      return;
    }
    Navigator.pop(context, {
      'title': _title.text.trim(),
      'body': _body.text.trim(),
      'tag': _tag,
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Create Forum post'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _title,
            autofocus: true,
            maxLength: 100,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Topic title'),
          ),
          TextField(
            controller: _body,
            maxLength: 1200,
            minLines: 3,
            maxLines: 5,
            decoration: const InputDecoration(labelText: 'Details'),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: _tag,
            decoration: const InputDecoration(labelText: 'Tag'),
            items: const ['LFG', 'Recruitment', 'Scrims', 'Support', 'Suggestions']
                .map((value) => DropdownMenuItem(value: value, child: Text(value)))
                .toList(),
            onChanged: (value) => setState(() => _tag = value ?? _tag),
          ),
        ]),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: _submit, child: const Text('Preview post')),
    ],
  );
}

class _ForumPostDetailSheet extends StatefulWidget {
  const _ForumPostDetailSheet({
    required this.post,
    required this.statusColor,
  });

  final Map<String, dynamic> post;
  final Color statusColor;

  @override
  State<_ForumPostDetailSheet> createState() => _ForumPostDetailSheetState();
}

class _ForumPostDetailSheetState extends State<_ForumPostDetailSheet> {
  final _reply = TextEditingController();

  bool get _locked =>
      widget.post['locked'] == true || widget.post['status'] == 'Closed';

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          18,
          16,
          MediaQuery.viewInsetsOf(context).bottom + 18,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(spacing: 6, runSpacing: 6, children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: widget.statusColor.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: widget.statusColor.withValues(alpha: .24)),
                ),
                child: Text(widget.post['status'].toString(), style: TextStyle(color: widget.statusColor, fontSize: 9, fontWeight: FontWeight.w800)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(color: KomnivoTheme.cyan.withValues(alpha: .12), borderRadius: BorderRadius.circular(30)),
                child: Text(widget.post['tag'].toString(), style: const TextStyle(color: KomnivoTheme.cyan, fontSize: 9, fontWeight: FontWeight.w800)),
              ),
              if (widget.post['pinned'] == true)
                const Chip(label: Text('Pinned'), visualDensity: VisualDensity.compact),
              if (_locked)
                const Chip(label: Text('Replies locked'), visualDensity: VisualDensity.compact),
            ]),
            const SizedBox(height: 10),
            Text(widget.post['title'].toString(), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
            const SizedBox(height: 7),
            Text(widget.post['body'].toString(), style: const TextStyle(fontSize: 11, height: 1.45)),
            const SizedBox(height: 12),
            const Divider(),
            Text('Replies · ${widget.post['replies'] ?? 0}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            const _Reply(author: 'Nova', body: 'I can join after 7 PM.'),
            const _Reply(author: 'RDX_Ace', body: 'Share your preferred role and availability.'),
            const SizedBox(height: 10),
            if (_locked)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  Icon(Icons.lock_outline, size: 15, color: KomnivoTheme.muted),
                  SizedBox(width: 7),
                  Expanded(child: Text('Replies are locked for this topic.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 10))),
                ]),
              )
            else ...[
              TextField(
                controller: _reply,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(hintText: 'Write a reply…'),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () {
                    if (_reply.text.trim().isEmpty) {
                      showMessage(context, 'Write a reply before previewing it.');
                      return;
                    }
                    Navigator.pop(context, true);
                  },
                  child: const Text('Preview reply'),
                ),
              ),
            ],
          ],
        ),
      ),
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
