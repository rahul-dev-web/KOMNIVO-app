import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/komnivo_repository.dart';
import '../../core/komnivo_theme.dart';
import '../../core/ui.dart';
import '../profile/member_profile_screen.dart';

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
  bool _readOnly = false;
  bool _announcementPublishersOnly = false;
  bool _allowAttachments = true;
  bool _allowThreads = true;
  bool _allowPins = true;
  bool _keepHistory = true;
  bool _canManageMessages = false;
  bool _canPublishInChannel = false;
  bool _canSendMessages = false;
  bool _sendPermissionLoading = true;
  bool _allowUserMentions = true;
  bool _eventRegistrationLoading = false;
  bool _eventRegistrationEligible = false;
  bool _eventRegistrationSubmitting = false;
  bool _eventRegistrationSubmitted = false;
  Map<String, dynamic>? _eventRegistration;
  String? _eventRegistrationError;
  bool _mentionLoading = false;
  Timer? _mentionDebounce;
  int _mentionRequest = 0;
  int? _mentionStart;
  int? _mentionEnd;
  String _mentionQuery = '';
  List<Map<String, dynamic>> _mentionCandidates = <Map<String, dynamic>>[];
  PlatformFile? _attachment;
  Map<String, dynamic>? _replyTo;
  final Set<String> _pinnedMessageIds = <String>{};
  final List<Map<String, dynamic>> _pollPreviews = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> _scheduledPreviews = <Map<String, dynamic>>[];
  final Map<String, List<Map<String, dynamic>>> _threadDraftReplies = <String, List<Map<String, dynamic>>>{};
  List<Map<String, dynamic>> _latestMessages = <Map<String, dynamic>>[];
  final Map<String, Map<String, dynamic>> _senderProfiles = <String, Map<String, dynamic>>{};
  final Set<String> _senderProfileRequests = <String>{};

  bool get _composerReadOnly => _sendPermissionLoading ||
      ((!_canSendMessages || _readOnly || _announcementPublishersOnly) && !_canPublishInChannel);

  String get _channelId => widget.channel['id'] as String;
  String get _userId => Supabase.instance.client.auth.currentUser!.id;
  String? get _eventId => widget.channel['event_id']?.toString();
  String get _normalizedChannelName =>
      (widget.channel['name']?.toString() ?? '').trim().toLowerCase().replaceAll('_', '-');
  bool get _isEventRegistrationChannel =>
      _eventId != null && (_normalizedChannelName == 'registration' || _normalizedChannelName == 'test-registration');
  bool get _isTestRegistrationChannel => _normalizedChannelName == 'test-registration';

  Future<void> _ensureSenderProfiles(List<Map<String, dynamic>> messages) async {
    final ids = messages
        .map((message) => message['sender_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty && !_senderProfiles.containsKey(id) && !_senderProfileRequests.contains(id))
        .toSet()
        .toList();
    if (ids.isEmpty) return;
    _senderProfileRequests.addAll(ids);
    try {
      final rows = await Supabase.instance.client
          .from('profiles')
          .select('id,display_name,username,avatar_url,bio,region,is_public')
          .inFilter('id', ids);
      if (!mounted) return;
      final profiles = <String, Map<String, dynamic>>{};
      for (final row in rows) {
        final profile = Map<String, dynamic>.from(row);
        final id = profile['id']?.toString();
        if (id != null) profiles[id] = profile;
      }
      setState(() => _senderProfiles.addAll(profiles));
    } catch (_) {
      // A private profile stays private; the chat falls back to a neutral label.
    } finally {
      _senderProfileRequests.removeAll(ids);
    }
  }

  Future<void> _openMemberProfile(String userId) async {
    if (userId.isEmpty || !mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => MemberProfileScreen(userId: userId)),
    );
  }

  Future<void> _loadEventRegistrationChannel() async {
    if (!_isEventRegistrationChannel || _eventId == null) return;
    if (mounted) setState(() {
      _eventRegistrationLoading = true;
      _eventRegistrationError = null;
    });
    try {
      final client = Supabase.instance.client;
      final event = await client
          .from('events')
          .select('id,name,format,status,registration_opens_at,registration_closes_at,game_id,community_id,rules_json')
          .eq('id', _eventId!)
          .maybeSingle();
      if (event == null) throw Exception('Tournament details are unavailable.');
      final eligible = await client.rpc('can_write_event_registration_channel', params: {
        'p_channel_id': _channelId,
      }) == true;
      if (!mounted) return;
      setState(() {
        _eventRegistration = Map<String, dynamic>.from(event);
        _eventRegistrationEligible = eligible;
        _eventRegistrationError = null;
      });
    } catch (error) {
      if (mounted) setState(() => _eventRegistrationError = error.toString());
    } finally {
      if (mounted) setState(() => _eventRegistrationLoading = false);
    }
  }

  String _eventRegistrationUnavailableMessage() {
    final event = _eventRegistration;
    if (event == null) return _eventRegistrationError ?? 'Tournament details are unavailable.';
    if (Supabase.instance.client.auth.currentUser == null) return 'Sign in to register for this tournament.';
    final status = event['status']?.toString() ?? '';
    if (status != 'published' && status != 'registration_open') {
      return 'This tournament is not accepting registrations right now.';
    }
    final closeAt = DateTime.tryParse(event['registration_closes_at']?.toString() ?? '');
    if (closeAt == null) return 'The registration deadline has not been configured.';
    if (!DateTime.now().isBefore(closeAt)) return 'The registration window is closed.';
    if (!_isTestRegistrationChannel) {
      final openAt = DateTime.tryParse(event['registration_opens_at']?.toString() ?? '');
      if (openAt == null) return 'The registration opening time has not been configured.';
      if (DateTime.now().isBefore(openAt)) {
        return 'Registration opens at ' + openAt.toLocal().toString() + '.';
      }
    }
    return 'You are not eligible yet. Join the tournament community and make sure your team meets the roster requirements.';
  }

  Future<String?> _chooseRegistrationTeam() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      showMessage(context, 'Sign in before registering.');
      return null;
    }
    final event = _eventRegistration;
    if (event == null) return null;
    final rows = await client
        .from('team_members')
        .select('team_id,teams(id,name,tag,game_id)')
        .eq('user_id', userId);
    final gameId = event['game_id']?.toString();
    final teams = List<Map<String, dynamic>>.from(rows).where((row) {
      final team = row['teams'];
      return team is Map && team['game_id']?.toString() == gameId;
    }).map((row) => Map<String, dynamic>.from(row['teams'] as Map)).toList();
    if (teams.isEmpty) {
      showMessage(context, 'You need an eligible team for this game before registering.');
      return null;
    }
    if (teams.length == 1) return teams.first['id']?.toString();

    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_isTestRegistrationChannel ? 'Choose a team for test registration' : 'Choose a team'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: teams.map((team) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.groups_2_outlined, color: KomnivoTheme.cyan),
                title: Text(team['name']?.toString() ?? 'Team'),
                subtitle: Text(team['tag']?.toString() ?? ''),
                onTap: () => Navigator.pop(dialogContext, team['id']?.toString()),
              )).toList(),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
        ],
      ),
    );
  }

  Future<void> _submitEventRegistrationFromChannel() async {
    if (_eventRegistrationSubmitting || !_eventRegistrationEligible || _eventRegistration == null) return;
    final event = _eventRegistration!;
    final registrationType = _isTestRegistrationChannel ? 'test' : 'real';
    String? teamId;
    if (event['format']?.toString() != 'solo') {
      try {
        teamId = await _chooseRegistrationTeam();
      } catch (error) {
        if (mounted) showMessage(context, error.toString());
        return;
      }
      if (teamId == null || !mounted) return;
    }
    setState(() => _eventRegistrationSubmitting = true);
    try {
      final response = await Supabase.instance.client.functions.invoke(
        'register-event',
        body: {
          'event_id': event['id'],
          'team_id': teamId,
          'registration_type': registrationType,
        },
      );
      if (response.status < 200 || response.status >= 300) {
        final details = response.data is Map ? (response.data as Map)['error'] : null;
        throw Exception(details?.toString() ?? 'Registration could not be submitted.');
      }
      if (!mounted) return;
      setState(() {
        _eventRegistrationSubmitted = true;
        _eventRegistrationEligible = false;
      });
      showMessage(
        context,
        registrationType == 'test'
            ? 'Test registration submitted. It will not reserve a real tournament slot.'
            : 'Tournament registration submitted.',
      );
    } catch (error) {
      if (mounted) {
        showMessage(context, error.toString());
        await _loadEventRegistrationChannel();
      }
    } finally {
      if (mounted) setState(() => _eventRegistrationSubmitting = false);
    }
  }

  Widget _eventRegistrationChannelFooter() {
    final eventName = _eventRegistration?['name']?.toString() ?? 'Tournament registration';
    final isTest = _isTestRegistrationChannel;
    final actionLabel = isTest ? 'Submit test registration' : 'Register in tournament';
    final accent = isTest ? KomnivoTheme.accent : KomnivoTheme.cyan;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [KomnivoTheme.surfaceRaised, accent.withValues(alpha: .10)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withValues(alpha: .35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: accent.withValues(alpha: .15), borderRadius: BorderRadius.circular(14)),
            child: Icon(isTest ? Icons.science_rounded : Icons.emoji_events_rounded, color: accent, size: 22),
          ),
          const SizedBox(width: 11),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(isTest ? 'TEST REGISTRATION' : 'TOURNAMENT ENTRY',
              style: TextStyle(color: accent, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1)),
            const SizedBox(height: 3),
            Text(eventName, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900)),
          ])),
          if (isTest)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(color: accent.withValues(alpha: .14), borderRadius: BorderRadius.circular(20)),
              child: Text('TEST ONLY', style: TextStyle(color: accent, fontSize: 8, fontWeight: FontWeight.w900)),
            ),
        ]),
        const SizedBox(height: 11),
        Text(
          isTest
              ? 'Run a safe test entry. It never consumes a real tournament slot or changes standings.'
              : 'Choose your eligible team and send its entry directly to the tournament.',
          style: const TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.4),
        ),
        const SizedBox(height: 13),
        if (_eventRegistrationLoading)
          const ClipRRect(borderRadius: BorderRadius.all(Radius.circular(8)), child: LinearProgressIndicator(minHeight: 4))
        else if (_eventRegistrationSubmitted)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(color: KomnivoTheme.cyan.withValues(alpha: .12), borderRadius: BorderRadius.circular(13)),
            child: const Row(children: [
              Icon(Icons.check_circle_rounded, color: KomnivoTheme.cyan, size: 18),
              SizedBox(width: 8),
              Expanded(child: Text('Registration submitted successfully', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900))),
            ]),
          )
        else if (_eventRegistrationEligible)
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _eventRegistrationSubmitting ? null : _submitEventRegistrationFromChannel,
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              icon: _eventRegistrationSubmitting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Icon(isTest ? Icons.science_rounded : Icons.login_rounded, size: 18),
              label: Text(_eventRegistrationSubmitting ? 'Submitting…' : actionLabel,
                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12)),
            ),
          )
        else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(13)),
            child: Row(children: [
              const Icon(Icons.info_outline_rounded, color: KomnivoTheme.muted, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(_eventRegistrationUnavailableMessage(),
                style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.35))),
            ]),
          ),
      ]),
    );
  }

  Widget _lockedChatFooter({bool compact = false}) {
    final publishersOnly = _announcementPublishersOnly && !_canPublishInChannel;
    final readOnly = _readOnly && !_canPublishInChannel;
    final noPostingPermission = !_sendPermissionLoading &&
        !_canSendMessages && !_canPublishInChannel && !readOnly && !publishersOnly;
    final label = _sendPermissionLoading
        ? 'Checking permissions'
        : publishersOnly
            ? 'Publishers only'
            : noPostingPermission
                ? 'Posting permission required'
                : 'Read-only channel';
    final explanation = _sendPermissionLoading
        ? 'We are checking whether your role can post here.'
        : publishersOnly
            ? 'This is an announcement channel. Only authorised publishers can post.'
            : noPostingPermission
                ? 'Your current role can read this conversation but cannot send messages.'
                : 'You can read the full conversation. Message posting is turned off here.';
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 10 : 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [KomnivoTheme.surfaceRaised, KomnivoTheme.surface],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: KomnivoTheme.line),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Container(
          width: compact ? 34 : 40,
          height: compact ? 34 : 40,
          decoration: BoxDecoration(color: KomnivoTheme.muted.withValues(alpha: .12), borderRadius: BorderRadius.circular(13)),
          child: const Icon(Icons.lock_rounded, color: KomnivoTheme.muted, size: 19),
        ),
        const SizedBox(width: 11),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: .8)),
          const SizedBox(height: 3),
          Text(explanation, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10, height: 1.35)),
        ])),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(color: KomnivoTheme.background, borderRadius: BorderRadius.circular(30)),
          child: const Icon(Icons.visibility_outlined, size: 15, color: KomnivoTheme.muted),
        ),
      ]),
    );
  }

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
    if (_composerReadOnly) {
      showMessage(context, 'This channel is read-only. Only authorised publishers can post.');
      return;
    }
    if (_sending || (text.isEmpty && attachment == null)) return;

    final parentId = _replyTo?['id'] as String?;
    if (parentId != null && !_allowThreads) {
      showMessage(context, 'Message threads are disabled in this channel.');
      return;
    }
    setState(() => _sending = true);
    try {
      if (text.isNotEmpty) {
        await KomnivoRepository.instance.sendMessage(
          _channelId,
          text,
          parentMessageId: parentId,
        );
      }
      if (attachment != null) {
        if (!_allowAttachments) throw Exception('Attachments are disabled in this channel.');
        await KomnivoRepository.instance.sendMessageAttachment(
          _channelId,
          attachment,
          parentMessageId: parentId,
        );
      }
      _controller.clear();
      _clearMentionSuggestions();
      if (mounted) setState(() { _attachment = null; _replyTo = null; });
    } catch (error) {
      if (mounted) showMessage(context, error.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _reply(Map<String, dynamic> message) {
    if (_isEventRegistrationChannel) return;
    setState(() {
      _replyTo = message;
      _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
    });
  }

  Future<void> _openThread(Map<String, dynamic> selectedMessage) async {
    final parentId = selectedMessage['parent_message_id']?.toString();
    Map<String, dynamic> root = selectedMessage;
    if (parentId != null) {
      for (final row in _latestMessages) {
        if (row['id']?.toString() == parentId) {
          root = row;
          break;
        }
      }
    }
    final rootId = root['id']?.toString();
    if (rootId == null || _isEventRegistrationChannel) return;
    if (!_allowThreads) {
      showMessage(context, 'Message threads are disabled in this channel.');
      return;
    }

    final replies = _latestMessages
        .where((row) => row['parent_message_id']?.toString() == rootId)
        .toList();
    final draftReplies = List<Map<String, dynamic>>.from(
      _threadDraftReplies[rootId] ?? const <Map<String, dynamic>>[],
    );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: KomnivoTheme.surface,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .88),
      builder: (routeContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * .78,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 16, 14, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Expanded(child: Text('Message thread', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900))),
                  Text((replies.length + draftReplies.length).toString() + ' replies',
                    style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
                  IconButton(onPressed: () => Navigator.pop(sheetContext), icon: const Icon(Icons.close, size: 18)),
                ]),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: KomnivoTheme.surfaceRaised,
                    borderRadius: BorderRadius.circular(13),
                    border: const Border(left: BorderSide(color: KomnivoTheme.accent, width: 3)),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(root['sender_id'] == _userId ? 'You · original message' : 'Community member · original message',
                      style: const TextStyle(color: KomnivoTheme.cyan, fontSize: 9, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 5),
                    SelectableText(root['body']?.toString() ?? '', style: const TextStyle(fontSize: 12, height: 1.4)),
                  ]),
                ),
                const SizedBox(height: 12),
                const Text('Replies', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900)),
                const SizedBox(height: 7),
                Expanded(
                  child: ListView(
                    children: [
                      if (replies.isEmpty && draftReplies.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Text('No replies yet. Start the thread with a response.',
                            style: TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
                        ),
                      ...replies.map((row) => _ThreadMessageCard(
                        author: row['sender_id'] == _userId ? 'You' : 'Community member',
                        body: row['body']?.toString() ?? '',
                      )),
                      ...draftReplies.map((row) => _ThreadMessageCard(
                        author: 'You · preview',
                        body: row['body']?.toString() ?? '',
                        isPreview: true,
                      )),
                    ],
                  ),
                ),
                if (_composerReadOnly)
                  _lockedChatFooter(compact: true)
                else
                  _ThreadComposer(
                  enabled: true,
                  onSend: (text) async {
                    try {
                      final messageId = await KomnivoRepository.instance.sendMessage(
                        _channelId, text, parentMessageId: rootId,
                      );
                      final reply = <String, dynamic>{
                        'id': messageId, 'body': text, 'sender_id': _userId,
                        'parent_message_id': rootId,
                        'created_at': DateTime.now().toIso8601String(),
                      };
                      if (!mounted) return;
                      setSheetState(() => replies.add(reply));
                      setState(() => _latestMessages.add(reply));
                    } catch (error) {
                      if (mounted) showMessage(context, 'Thread reply failed: $error');
                    }
                  },
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 5),
                  child: Text('Replies are saved to this channel and appear in the message thread.',
                    style: TextStyle(color: KomnivoTheme.muted, fontSize: 8)),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _togglePin(Map<String, dynamic> message) async {
    if (!_allowPins || !_canManageMessages) {
      showMessage(context, 'You do not have permission to manage pinned messages in this channel.');
      return;
    }
    final id = message['id']?.toString();
    if (id == null) return;
    try {
      await KomnivoRepository.instance.toggleMessagePin(_channelId, id);
      final pins = await KomnivoRepository.instance.messagePinIds(_channelId);
      if (!mounted) return;
      setState(() {
        _pinnedMessageIds
          ..clear()
          ..addAll(pins);
      });
      showMessage(context, pins.contains(id) ? 'Message pinned.' : 'Pin removed.');
    } catch (error) {
      if (mounted) showMessage(context, 'Pin update failed: $error');
    }
  }

  Future<void> _showPinnedMessages() async {
    final rows = _latestMessages.where((row) => _pinnedMessageIds.contains(row['id']?.toString())).toList();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: KomnivoTheme.surface,
      builder: (sheetContext) => SafeArea(child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('Pinned messages', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900))),
            Text(rows.length.toString(), style: const TextStyle(color: KomnivoTheme.muted, fontSize: 10)),
          ]),
          const SizedBox(height: 12),
          if (rows.isEmpty)
            const Text('No pinned messages in this channel yet. Use a message menu to pin an important update.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 11, height: 1.4))
          else
            ...rows.map((row) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.push_pin_outlined, color: KomnivoTheme.cyan),
              title: Text((row['body'] ?? '').toString(), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
              trailing: _canManageMessages ? IconButton(onPressed: () async {
                Navigator.pop(sheetContext);
                await _togglePin(row);
              }, icon: const Icon(Icons.close, size: 17)) : null,
            )),
          const SizedBox(height: 6),
          const Text('Pins are stored with the channel and follow its moderation permissions.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
        ]),
      )),
    );
  }

  Future<void> _createChannelPoll() async {
    final question = TextEditingController();
    final optionOne = TextEditingController();
    final optionTwo = TextEditingController();
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Create channel poll'),
        content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: question, autofocus: true, maxLength: 160, decoration: const InputDecoration(labelText: 'Question')),
          TextField(controller: optionOne, maxLength: 70, decoration: const InputDecoration(labelText: 'Option 1')),
          TextField(controller: optionTwo, maxLength: 70, decoration: const InputDecoration(labelText: 'Option 2')),
          const SizedBox(height: 6),
          const Text('Poll votes are community feedback, never official tournament results.', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, {
            'question': question.text.trim(),
            'one': optionOne.text.trim(),
            'two': optionTwo.text.trim(),
          }), child: const Text('Publish poll')),
        ],
      ),
    );
    question.dispose(); optionOne.dispose(); optionTwo.dispose();
    if (result == null || (result['question'] ?? '').isEmpty || (result['one'] ?? '').isEmpty || (result['two'] ?? '').isEmpty) return;
    final communityId = widget.channel['community_id']?.toString();
    if (communityId == null || communityId.isEmpty) {
      showMessage(context, 'This channel is not linked to a community.');
      return;
    }
    try {
      await KomnivoRepository.instance.createChannelPoll(
        channelId: _channelId,
        communityId: communityId,
        question: result['question']!,
        options: [result['one']!, result['two']!],
      );
      await _loadPolls();
      if (mounted) showMessage(context, 'Poll published.');
    } catch (error) {
      if (mounted) showMessage(context, 'Could not publish poll: $error');
    }
  }

  Future<void> _scheduleChannelAnnouncement() async {
    final title = TextEditingController();
    final body = TextEditingController();
    String when = 'Tomorrow · 5:30 PM';
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (context, setDialogState) => AlertDialog(
        title: const Text('Schedule announcement'),
        content: SizedBox(width: 430, child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: title, maxLength: 100, decoration: const InputDecoration(labelText: 'Announcement title')),
          TextField(controller: body, maxLines: 3, maxLength: 1200, decoration: const InputDecoration(labelText: 'Message')),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: when,
            decoration: const InputDecoration(labelText: 'Publish time'),
            items: const ['Today · 6:00 PM', 'Tomorrow · 9:00 AM', 'Tomorrow · 5:30 PM'].map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(),
            onChanged: (value) => setDialogState(() => when = value ?? when),
          ),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, {
            'title': title.text.trim(),
            'body': body.text.trim(),
            'when': when,
          }), child: const Text('Schedule announcement')),
        ],
      )),
    );
    title.dispose(); body.dispose();
    if (result == null || (result['title'] ?? '').isEmpty || (result['body'] ?? '').isEmpty) return;
    final communityId = widget.channel['community_id']?.toString();
    if (communityId == null || communityId.isEmpty) {
      showMessage(context, 'This channel is not linked to a community.');
      return;
    }
    final now = DateTime.now();
    DateTime publishAt;
    if (when.startsWith('Today')) {
      publishAt = DateTime(now.year, now.month, now.day, 18);
      if (!publishAt.isAfter(now)) publishAt = publishAt.add(const Duration(days: 1));
    } else if (when.contains('9:00 AM')) {
      publishAt = DateTime(now.year, now.month, now.day + 1, 9);
    } else {
      publishAt = DateTime(now.year, now.month, now.day + 1, 17, 30);
    }
    try {
      await KomnivoRepository.instance.scheduleChannelAnnouncement(
        channelId: _channelId,
        communityId: communityId,
        body: '${result['title']}: ${result['body']}',
        publishAt: publishAt,
      );
      await _loadScheduledAnnouncements();
      if (mounted) showMessage(context, 'Announcement queued. It will publish automatically at the selected time.');
    } catch (error) {
      if (mounted) showMessage(context, 'Could not schedule announcement: $error');
    }
  }

  void _showChannelTools() {
    if (_isEventRegistrationChannel) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: KomnivoTheme.surface,
      builder: (sheetContext) => SafeArea(child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Channel tools', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
          const SizedBox(height: 12),
          if (_allowPins) ListTile(leading: const Icon(Icons.push_pin_outlined), title: const Text('Pinned messages'), subtitle: Text(_pinnedMessageIds.length.toString() + ' pinned'), onTap: () { Navigator.pop(sheetContext); _showPinnedMessages(); }),
          if (!_composerReadOnly) ListTile(leading: const Icon(Icons.poll_outlined), title: const Text('Create poll'), subtitle: const Text('Collect community feedback'), onTap: () { Navigator.pop(sheetContext); _createChannelPoll(); }),
          if (_canManageMessages) ListTile(leading: const Icon(Icons.schedule_outlined), title: const Text('Schedule announcement'), subtitle: const Text('Choose a publish window'), onTap: () { Navigator.pop(sheetContext); _scheduleChannelAnnouncement(); }),
        ]),
      )),
    );
  }

  Widget _previewToolCard(IconData icon, String title) => Container(
    width: 230,
    margin: const EdgeInsets.only(right: 8),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: KomnivoTheme.line)),
    child: Row(children: [
      Icon(icon, color: KomnivoTheme.cyan, size: 18),
      const SizedBox(width: 8),
      Expanded(child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700))),
    ]),
  );

  Widget _scheduledAnnouncementCard(Map<String, dynamic> row) => Container(
    width: 260,
    margin: const EdgeInsets.only(right: 8),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: KomnivoTheme.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: KomnivoTheme.line),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.schedule_outlined, color: KomnivoTheme.cyan, size: 15),
        const SizedBox(width: 6),
        const Expanded(child: Text('Scheduled announcement', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800))),
        IconButton(
          tooltip: 'Cancel announcement',
          visualDensity: VisualDensity.compact,
          onPressed: () => _cancelScheduledAnnouncement(row['id'].toString()),
          icon: const Icon(Icons.close, size: 15),
        ),
      ]),
      Text(row['title'].toString(), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10)),
      const SizedBox(height: 4),
      Text(row['when'].toString(), style: const TextStyle(color: KomnivoTheme.muted, fontSize: 8)),
    ]),
  );

  Widget _pollPreviewCard(Map<String, dynamic> poll) {
    final options = (poll['options'] as List).cast<String>();
    final votes = (poll['votes'] as List).cast<int>();
    return Container(
      width: 250,
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: KomnivoTheme.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: KomnivoTheme.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(poll['question'].toString(), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
        const SizedBox(height: 5),
        ...List.generate(options.length, (index) => InkWell(
          onTap: () async {
            final pollId = poll['id']?.toString();
            final optionIds = (poll['optionIds'] as List).cast<String>();
            if (pollId == null || index >= optionIds.length) return;
            try {
              await KomnivoRepository.instance.voteChannelPoll(pollId, [optionIds[index]]);
              if (!mounted) return;
              await _loadPolls();
              if (mounted) showMessage(context, 'Vote recorded.');
            } catch (error) {
              if (mounted) showMessage(context, 'Vote failed: $error');
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Icon(poll['selected'] == index ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 13, color: KomnivoTheme.cyan),
              const SizedBox(width: 5),
              Expanded(child: Text(options[index], style: const TextStyle(fontSize: 9))),
              Text(votes[index].toString(), style: const TextStyle(color: KomnivoTheme.muted, fontSize: 8)),
            ]),
          ),
        )),
        const Text('Vote is saved to the channel poll', style: TextStyle(color: KomnivoTheme.muted, fontSize: 8)),
      ]),
    );
  }

  @override
  void initState() {
    super.initState();
    _readOnly = widget.channel['is_read_only'] == true;
    _loadPins();
    _loadChannelSettings();
    _loadEventRegistrationChannel();
    _loadPolls();
    _loadScheduledAnnouncements();
  }

  Future<void> _loadChannelSettings() async {
    try {
      final results = await Future.wait([
        KomnivoRepository.instance.channelSettings(_channelId),
        _resolveCanManageMessages(),
        _resolveCanSendMessages(),
      ]);
      final settings = Map<String, dynamic>.from(results[0] as Map);
      final canManage = results[1] == true;
      final eventId = widget.channel['event_id']?.toString();
      final isRootEventChannel = eventId != null && eventId.isNotEmpty &&
          widget.channel['stage_id'] == null &&
          widget.channel['group_id'] == null &&
          widget.channel['match_id'] == null;
      final publishersOnly = settings.containsKey('announcement_publishers_only')
          ? settings['announcement_publishers_only'] == true
          : widget.channel['kind'] == 'announcement';
      final isReadOnly = settings['read_only'] == true;
      var canPublish = canManage;
      // Root event announcements have a stricter backend rule: only event.manage
      // can publish, even where scoped staff can manage other channel operations.
      if (isRootEventChannel && (isReadOnly || publishersOnly)) {
        canPublish = await KomnivoRepository.instance.hasPermission(
          permissionKey: 'event.manage',
          scopeType: 'event',
          scopeId: eventId,
        );
      }
      if (!mounted) return;
      setState(() {
        _readOnly = isReadOnly || _readOnly;
        _announcementPublishersOnly = publishersOnly;
        _allowAttachments = settings['allow_attachments'] != false;
        _allowThreads = settings['allow_threads'] != false;
        _allowPins = settings['allow_pins'] != false;
        _keepHistory = settings['keep_history'] != false;
        _allowUserMentions = settings['allow_user_mentions'] != false;
        _canManageMessages = canManage;
        _canPublishInChannel = canPublish;
        _canSendMessages = results[2] == true;
        _sendPermissionLoading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _sendPermissionLoading = false;
          _canPublishInChannel = false;
          _canSendMessages = false;
        });
        showMessage(context, 'Could not load channel behaviour settings: $error');
      }
    }
  }

  Future<bool> _resolveCanManageMessages() {
    return KomnivoRepository.instance.canManageChannelMessages(_channelId);
  }

  Future<bool> _resolveCanSendMessages() async {
    if (widget.channel['event_id'] != null) return true;
    final communityId = widget.channel['community_id']?.toString();
    if (communityId == null || communityId.isEmpty) return true;
    try {
      return await KomnivoRepository.instance.hasPermission(
        permissionKey: 'channel.send_messages',
        scopeType: 'community',
        scopeId: communityId,
        resourceId: _channelId,
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> _loadPolls() async {
    try {
      final rows = await KomnivoRepository.instance.channelPollFeed(_channelId);
      final grouped = <String, List<Map<String, dynamic>>>{};
      for (final raw in rows) {
        final row = Map<String, dynamic>.from(raw);
        final id = row['poll_id']?.toString();
        if (id == null) continue;
        (grouped[id] ??= <Map<String, dynamic>>[]).add(row);
      }
      final polls = grouped.entries.map((entry) {
        final options = entry.value;
        final first = options.first;
        final selectedIndex = options.indexWhere((row) => row['selected_by_me'] == true);
        return <String, dynamic>{
          'id': entry.key,
          'question': first['question']?.toString() ?? '',
          'options': options.map((row) => row['option_label'].toString()).toList(),
          'optionIds': options.map((row) => row['option_id'].toString()).toList(),
          'votes': options.map((row) => (row['vote_count'] as num?)?.toInt() ?? 0).toList(),
          'selected': selectedIndex,
          'allowMultiple': first['allow_multiple'] == true,
          'closesAt': first['closes_at'],
        };
      }).toList();
      if (mounted) setState(() {
        _pollPreviews
          ..clear()
          ..addAll(polls);
      });
    } catch (error) {
      if (mounted) showMessage(context, 'Could not load channel polls: $error');
    }
  }

  Future<void> _loadScheduledAnnouncements() async {
    try {
      final rows = await KomnivoRepository.instance.scheduledChannelAnnouncements(_channelId);
      if (!mounted) return;
      setState(() {
        _scheduledPreviews
          ..clear()
          ..addAll(rows.map((row) => <String, dynamic>{
            ...row,
            'title': row['body']?.toString() ?? 'Scheduled announcement',
            'when': DateTime.tryParse(row['publish_at']?.toString() ?? '')?.toLocal().toString() ?? 'Scheduled',
          }));
      });
    } catch (error) {
      if (mounted) showMessage(context, 'Could not load scheduled announcements: $error');
    }
  }

  Future<void> _cancelScheduledAnnouncement(String announcementId) async {
    try {
      await KomnivoRepository.instance.cancelChannelAnnouncement(announcementId);
      await _loadScheduledAnnouncements();
      if (mounted) showMessage(context, 'Scheduled announcement cancelled.');
    } catch (error) {
      if (mounted) showMessage(context, 'Could not cancel announcement: $error');
    }
  }

  Future<void> _loadPins() async {
    try {
      final pins = await KomnivoRepository.instance.messagePinIds(_channelId);
      if (mounted) setState(() { _pinnedMessageIds..clear()..addAll(pins); });
    } catch (_) {
      // Channel membership/RLS controls whether the pin list is readable.
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _searchController.dispose();
    _mentionDebounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final channelName = widget.channel['name']?.toString() ?? 'chat';
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Icon(_isEventRegistrationChannel ? Icons.emoji_events_outlined : Icons.tag, color: KomnivoTheme.cyan, size: 18),
            const SizedBox(width: 6),
            Flexible(child: Text(channelName, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900))),
          ]),
          Text(
            _isTestRegistrationChannel ? 'TEST ENTRY · ISOLATED' : _isEventRegistrationChannel ? 'TOURNAMENT REGISTRATION' : 'LIVE COMMUNITY CHAT',
            style: const TextStyle(color: KomnivoTheme.muted, fontSize: 8, fontWeight: FontWeight.w800, letterSpacing: 1),
          ),
        ]),
        actions: [
          if (!_isEventRegistrationChannel)
            IconButton(tooltip: 'Channel tools', onPressed: _showChannelTools, icon: const Icon(Icons.more_vert)),
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
        if (!_allowAttachments || !_allowThreads || !_allowPins || (!_keepHistory && !_canManageMessages))
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: KomnivoTheme.surfaceRaised,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: KomnivoTheme.line),
            ),
            child: Wrap(spacing: 10, runSpacing: 5, children: [
              if (!_allowAttachments) const Text('Attachments off', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
              if (!_allowThreads) const Text('Threads off', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
              if (!_allowPins) const Text('Pins off', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
              if (!_keepHistory && !_canManageMessages) const Text('Only the last 24 hours of messages are shown', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
            ]),
          ),
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
        if (_pollPreviews.isNotEmpty || _scheduledPreviews.isNotEmpty || _pinnedMessageIds.isNotEmpty)
          SizedBox(
            height: 116,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 7, 12, 0),
              children: [
                ..._pollPreviews.map(_pollPreviewCard),
                ..._scheduledPreviews.map(_scheduledAnnouncementCard),
                if (_pinnedMessageIds.isNotEmpty) _previewToolCard(Icons.push_pin_outlined, _pinnedMessageIds.length.toString() + ' pinned messages'),
              ],
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
              // Supabase RLS applies the configured history window server-side.
              // Moderators are exempt; history remains stored for audit/evidence purposes.
              _latestMessages = List<Map<String, dynamic>>.from(allMessages);
              if (allMessages.isNotEmpty) unawaited(_ensureSenderProfiles(allMessages));
              final messages = query.isEmpty
                  ? allMessages
                  : allMessages.where((message) => (message['body'] ?? '').toString().toLowerCase().contains(query)).toList();

              if (snapshot.connectionState == ConnectionState.waiting && messages.isEmpty) {
                return const Center(child: CircularProgressIndicator());
              }
              if (messages.isEmpty) {
                return EmptyState(
                  title: query.isNotEmpty
                      ? 'No matching messages'
                      : _isEventRegistrationChannel
                          ? (_isTestRegistrationChannel ? 'Test registration' : 'Tournament registration')
                          : 'Start the conversation',
                  message: query.isNotEmpty
                      ? 'Try another word or phrase.'
                      : _isEventRegistrationChannel
                          ? (_isTestRegistrationChannel
                              ? 'Use the Test register button below to submit an isolated test entry.'
                              : 'Use the Register in tournament button below to submit your team.')
                          : 'Coordinate matches, share updates and keep your community in one place.',
                  icon: _isEventRegistrationChannel
                      ? (_isTestRegistrationChannel ? Icons.science_outlined : Icons.how_to_reg_outlined)
                      : Icons.forum_outlined,
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(14, 16, 14, 22),
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final message = messages[index];
                  final mine = message['sender_id'] == _userId;
                  final messageId = message['id']?.toString() ?? '';
                  final replyCount = allMessages.where(
                    (row) => row['parent_message_id']?.toString() == messageId,
                  ).length + (_threadDraftReplies[messageId]?.length ?? 0);
                  return _MessageBubble(
                    message: message,
                    mine: mine,
                    profile: _senderProfiles[message['sender_id']?.toString()],
                    onOpenProfile: () => _openMemberProfile(message['sender_id']?.toString() ?? ''),
                    isPinned: _pinnedMessageIds.contains(messageId),
                    replyCount: replyCount,
                    onReply: () => _reply(message),
                    onOpenThread: () => _openThread(message),
                    onPin: () => _togglePin(message),
                    allowThreads: _allowThreads && !_isEventRegistrationChannel,
                    allowPins: _allowPins && _canManageMessages && !_isEventRegistrationChannel,
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
            child: _isEventRegistrationChannel
                ? _eventRegistrationChannelFooter()
                : _composerReadOnly
                    ? _lockedChatFooter()
                    : Column(children: [
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
              if (_allowUserMentions && _mentionStart != null)
                _mentionSuggestionPanel(),
              Container(
                padding: const EdgeInsets.fromLTRB(7, 6, 7, 6),
                decoration: BoxDecoration(
                  color: KomnivoTheme.surfaceRaised,
                  borderRadius: BorderRadius.circular(21),
                  border: Border.all(color: KomnivoTheme.line),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .12), blurRadius: 15, offset: const Offset(0, 5))],
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  IconButton(
                    tooltip: 'Attach image or PDF',
                    onPressed: _sending || _composerReadOnly || !_allowAttachments ? null : _pickAttachment,
                    style: IconButton.styleFrom(
                      backgroundColor: KomnivoTheme.surface,
                      foregroundColor: KomnivoTheme.cyan,
                      fixedSize: const Size(40, 40),
                    ),
                    icon: const Icon(Icons.add_rounded),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      enabled: !_composerReadOnly,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: 'Message #$channelName',
                        filled: false,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 7, vertical: 12),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                      onChanged: _handleComposerChanged,
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 5),
                  IconButton.filled(
                    onPressed: _sending || _composerReadOnly ? null : _send,
                    style: IconButton.styleFrom(
                      backgroundColor: KomnivoTheme.cyan,
                      foregroundColor: KomnivoTheme.background,
                      fixedSize: const Size(42, 42),
                    ),
                    icon: _sending
                        ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.arrow_upward_rounded),
                  ),
                ]),
              ),
              const SizedBox(height: 5),
              Row(children: [
                const Icon(Icons.keyboard_return_rounded, size: 11, color: KomnivoTheme.muted),
                const SizedBox(width: 4),
                const Expanded(child: Text('Enter to send · Keep sensitive information out of public channels',
                  style: TextStyle(color: KomnivoTheme.muted, fontSize: 8))),
                Text(_allowAttachments ? 'Attachments on' : 'Text only',
                  style: const TextStyle(color: KomnivoTheme.muted, fontSize: 8, fontWeight: FontWeight.w700)),
              ]),
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
    required this.onOpenThread,
    required this.onPin,
    required this.onOpenProfile,
    required this.isPinned,
    required this.replyCount,
    this.profile,
    this.allowThreads = true,
    this.allowPins = true,
  });
  final Map<String, dynamic> message;
  final bool mine;
  final Map<String, dynamic>? profile;
  final VoidCallback onReply;
  final VoidCallback onOpenThread;
  final VoidCallback onPin;
  final VoidCallback onOpenProfile;
  final bool isPinned;
  final int replyCount;
  final bool allowThreads;
  final bool allowPins;

  String _clockLabel() {
    final created = DateTime.tryParse(message['created_at']?.toString() ?? '')?.toLocal();
    if (created == null) return '';
    final hour = created.hour.toString().padLeft(2, '0');
    final minute = created.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\\s+')).where((part) => part.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    return parts.take(2).map((part) => part.substring(0, 1).toUpperCase()).join();
  }

  @override
  Widget build(BuildContext context) {
    final displayName = profile?['display_name']?.toString().trim().isNotEmpty == true
        ? profile!['display_name'].toString().trim()
        : profile?['username']?.toString().trim().isNotEmpty == true
            ? profile!['username'].toString().trim()
            : mine ? 'You' : 'Member';
    final username = profile?['username']?.toString().trim() ?? '';
    final avatarUrl = profile?['avatar_url']?.toString().trim() ?? '';
    final body = message['body']?.toString() ?? '';
    final time = _clockLabel();
    final avatar = InkWell(
      onTap: onOpenProfile,
      borderRadius: BorderRadius.circular(24),
      child: CircleAvatar(
        radius: 16,
        backgroundColor: KomnivoTheme.surfaceRaised,
        backgroundImage: avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
        onBackgroundImageError: (_, __) {},
        child: avatarUrl.isEmpty
            ? Text(_initials(displayName), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900))
            : null,
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!mine) ...[avatar, const SizedBox(width: 8)],
          Flexible(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 600),
              padding: const EdgeInsets.fromLTRB(13, 10, 9, 8),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: mine
                      ? [const Color(0xFF342C5E), const Color(0xFF282448)]
                      : [KomnivoTheme.surfaceRaised, KomnivoTheme.surface],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(mine ? 18 : 5),
                  bottomRight: Radius.circular(mine ? 5 : 18),
                ),
                border: Border.all(color: mine ? KomnivoTheme.accent.withValues(alpha: .35) : KomnivoTheme.line),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  if (isPinned) const Padding(padding: EdgeInsets.only(right: 5), child: Icon(Icons.push_pin, size: 12, color: KomnivoTheme.cyan)),
                  Flexible(
                    child: InkWell(
                      onTap: onOpenProfile,
                      borderRadius: BorderRadius.circular(5),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(displayName, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: KomnivoTheme.cyan, fontWeight: FontWeight.w900, fontSize: 11)),
                      ),
                    ),
                  ),
                  if (username.isNotEmpty && username.toLowerCase() != displayName.toLowerCase()) ...[
                    const SizedBox(width: 6),
                    Text('@$username', style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
                  ],
                  const SizedBox(width: 6),
                  if (time.isNotEmpty) Text(time, style: const TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
                  const SizedBox(width: 2),
                  PopupMenuButton<String>(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 150),
                    tooltip: 'Message actions',
                    iconSize: 17,
                    icon: const Icon(Icons.more_horiz, color: KomnivoTheme.muted),
                    onSelected: (value) async {
                      if (value == 'reply') onReply();
                      if (value == 'thread') onOpenThread();
                      if (value == 'pin') onPin();
                      if (value == 'profile') onOpenProfile();
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
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'profile', child: Text('View profile')),
                      if (allowThreads) const PopupMenuItem(value: 'thread', child: Text('Open thread')),
                      if (allowThreads) const PopupMenuItem(value: 'reply', child: Text('Reply in composer')),
                      if (allowPins) PopupMenuItem(value: 'pin', child: Text(isPinned ? 'Unpin message' : 'Pin message')),
                      const PopupMenuItem(value: 'copy', child: Text('Copy text')),
                      const PopupMenuDivider(),
                      const PopupMenuItem(value: 'react:👍', child: Text('👍 React')),
                      const PopupMenuItem(value: 'react:❤️', child: Text('❤️ React')),
                      const PopupMenuItem(value: 'react:🔥', child: Text('🔥 React')),
                      const PopupMenuItem(value: 'react:😂', child: Text('😂 React')),
                    ],
                  ),
                ]),
                if (message['parent_message_id'] != null) ...[
                  const SizedBox(height: 3),
                  const Text('↳ Reply in this conversation', style: TextStyle(color: KomnivoTheme.muted, fontSize: 9)),
                ],
                const SizedBox(height: 3),
                SelectableText(body, style: const TextStyle(height: 1.42, fontSize: 13)),
                const SizedBox(height: 7),
                _MessageAttachmentList(messageId: message['id'] as String),
                _MessageReactionBar(messageId: message['id'] as String),
                if (allowThreads) Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: onOpenThread,
                    icon: const Icon(Icons.forum_outlined, size: 13),
                    label: Text(replyCount == 0 ? 'Open thread' : '$replyCount replies',
                      style: const TextStyle(fontSize: 9)),
                    style: TextButton.styleFrom(
                      foregroundColor: KomnivoTheme.muted,
                      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              ]),
            ),
          ),
          if (mine) ...[const SizedBox(width: 8), avatar],
        ],
      ),
    );
  }
}

class _ThreadMessageCard extends StatelessWidget {
  const _ThreadMessageCard({
    required this.author,
    required this.body,
    this.isPreview = false,
  });

  final String author;
  final String body;
  final bool isPreview;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 7),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: isPreview ? KomnivoTheme.surfaceRaised : KomnivoTheme.surface,
      borderRadius: BorderRadius.circular(11),
      border: Border.all(color: isPreview ? KomnivoTheme.accent.withValues(alpha: .4) : KomnivoTheme.line),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(author, style: const TextStyle(color: KomnivoTheme.cyan, fontSize: 9, fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      Text(body, style: const TextStyle(fontSize: 11, height: 1.4)),
    ]),
  );
}

class _ThreadComposer extends StatefulWidget {
  const _ThreadComposer({required this.enabled, required this.onSend});

  final bool enabled;
  final ValueChanged<String> onSend;

  @override
  State<_ThreadComposer> createState() => _ThreadComposerState();
}

class _ThreadComposerState extends State<_ThreadComposer> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (!widget.enabled || text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
    Expanded(
      child: TextField(
        controller: _controller,
        enabled: widget.enabled,
        minLines: 1,
        maxLines: 3,
        decoration: const InputDecoration(
          hintText: 'Reply to this thread…',
          isDense: true,
        ),
        onSubmitted: (_) => _submit(),
      ),
    ),
    const SizedBox(width: 8),
    IconButton.filled(
      onPressed: widget.enabled ? _submit : null,
      icon: const Icon(Icons.send_rounded, size: 17),
    ),
  ]);
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
