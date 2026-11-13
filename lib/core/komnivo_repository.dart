import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class KomnivoRepository {
  KomnivoRepository._();
  static final instance = KomnivoRepository._();

  SupabaseClient get client => Supabase.instance.client;
  String get userId => client.auth.currentUser!.id;

  Future<Map<String, dynamic>> myProfile() async {
    final row = await client.from('profiles').select().eq('id', userId).maybeSingle();
    return row ?? <String, dynamic>{};
  }

  Future<List<Map<String, dynamic>>> communities() async {
    final rows = await client.from('communities').select().order('created_at', ascending: false).limit(30);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<Map<String, dynamic>> createCommunity({
    required String name,
    required String description,
    required bool isPublic,
  }) async {
    final result = await client.functions.invoke('create-community', body: {
      'name': name,
      'description': description,
      'visibility': isPublic ? 'public' : 'private',
    });
    if (result.status < 200 || result.status >= 300) {
      throw Exception('Community creation failed (${result.status}).');
    }
    return Map<String, dynamic>.from(result.data as Map);
  }

  Future<void> joinCommunity(String communityId) async {
    await client.functions.invoke('join-community', body: {'community_id': communityId});
  }

  Future<List<Map<String, dynamic>>> events() async {
    final rows = await client.from('events').select('*, games(name, code), communities(name)')
      .inFilter('status', ['published', 'registration_open', 'live'])
      .order('starts_at').limit(40);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<Map<String, dynamic>> createEvent({
    required String name,
    required String gameId,
    required DateTime startsAt,
    required int capacity,
    required Map<String, dynamic> scoring,
  }) async {
    final row = await client.from('events').insert({
      'name': name,
      'game_id': gameId,
      'organizer_id': userId,
      'starts_at': startsAt.toUtc().toIso8601String(),
      'capacity': capacity,
      'status': 'published',
      'format': 'squad',
      'scoring_config': scoring,
      'rules_json': <String, dynamic>{},
    }).select().single();
    return Map<String, dynamic>.from(row);
  }

  Future<List<Map<String, dynamic>>> myRegistrableTeams() async {
    final rows = await client.from('team_members')
      .select('team_id, role, teams(id, name, tag, game_id)')
      .eq('user_id', userId)
      .inFilter('role', ['owner', 'captain']);
    return List<Map<String, dynamic>>.from(rows)
      .where((row) => row['teams'] is Map)
      .map((row) => Map<String, dynamic>.from(row['teams'] as Map))
      .toList();
  }

  Future<void> registerForEvent(String eventId, {String? teamId}) async {
    await client.rpc('register_for_event', params: {
      'p_event_id': eventId,
      'p_team_id': teamId,
    });
  }

  Future<List<Map<String, dynamic>>> teams() async {
    final rows = await client.from('teams').select('*, games(name, code), team_members(count)')
      .order('created_at', ascending: false).limit(30);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<Map<String, dynamic>> createTeam({
    required String name,
    required String tag,
    required String gameId,
  }) async {
    final row = await client.from('teams').insert({
      'name': name,
      'tag': tag,
      'game_id': gameId,
      'owner_user_id': userId,
    }).select().single();
    return Map<String, dynamic>.from(row);
  }

  Future<List<Map<String, dynamic>>> channels({String? communityId}) async {
    var query = client.from('channels').select();
    if (communityId != null) query = query.eq('community_id', communityId);
    final rows = await query.order('created_at').limit(50);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<List<Map<String, dynamic>>> messages(String channelId) async {
    final rows = await client.from('messages')
      .select('*, profiles!messages_sender_id_fkey(display_name, avatar_url)')
      .eq('channel_id', channelId).order('created_at').limit(100);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<String> sendMessage(
    String channelId,
    String body, {
    String? parentMessageId,
  }) async {
    final text = body.trim();
    if (text.isEmpty) throw Exception('Message cannot be empty.');
    final row = await client.from('messages').insert({
      'channel_id': channelId,
      'sender_id': userId,
      'body': text,
      'parent_message_id': parentMessageId,
    }).select('id').single();
    return row['id'] as String;
  }

  Future<String> sendMessageAttachment(
    String channelId,
    PlatformFile file, {
    String? parentMessageId,
  }) async {
    final contentType = _contentTypeFor(file.extension);
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) throw Exception('The selected attachment is empty.');
    if (bytes.length > 10 * 1024 * 1024) {
      throw Exception('Attachments must be 10 MB or smaller.');
    }

    final messageId = await sendMessage(
      channelId,
      'Shared a file: ${file.name}',
      parentMessageId: parentMessageId,
    );
    final safeName = file.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final path = '$userId/$channelId/${DateTime.now().millisecondsSinceEpoch}_$safeName';

    await client.storage.from('community-media').uploadBinary(
      path,
      bytes,
      fileOptions: FileOptions(contentType: contentType, upsert: false),
    );
    await client.from('message_attachments').insert({
      'message_id': messageId,
      'uploaded_by': userId,
      'storage_path': path,
      'content_type': contentType,
      'file_size': bytes.length,
    });
    return messageId;
  }

  Future<List<Map<String, dynamic>>> messageAttachments(String messageId) async {
    final rows = await client.from('message_attachments')
      .select('id,storage_path,content_type,file_size')
      .eq('message_id', messageId)
      .order('created_at');
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<String> messageAttachmentUrl(String storagePath) async {
    final result = await client.storage.from('community-media')
      .createSignedUrl(storagePath, 3600);
    return result;
  }

  Future<List<Map<String, dynamic>>> messageReactions(String messageId) async {
    final rows = await client.from('message_reactions')
      .select('emoji,user_id')
      .eq('message_id', messageId);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<void> toggleMessageReaction(String messageId, String emoji) async {
    final existing = await client.from('message_reactions')
      .select('message_id')
      .eq('message_id', messageId)
      .eq('user_id', userId)
      .eq('emoji', emoji)
      .maybeSingle();

    if (existing != null) {
      await client.from('message_reactions').delete()
        .eq('message_id', messageId)
        .eq('user_id', userId)
        .eq('emoji', emoji);
    } else {
      await client.from('message_reactions').insert({
        'message_id': messageId,
        'user_id': userId,
        'emoji': emoji,
      });
    }
  }

  Stream<List<Map<String, dynamic>>> messageStream(String channelId) {
    return client.from('messages').stream(primaryKey: ['id']).eq('channel_id', channelId).order('created_at');
  }

  Future<Map<String, dynamic>> syncFreeFire(String uid, {String region = 'ind'}) async {
    final response = await client.functions.invoke('sync-freefire-profile', body: {
      'action': 'lookup',
      'uid': uid.trim(),
      'region': region,
    });
    if (response.status < 200 || response.status >= 300) {
      final data = response.data;
      final message = data is Map ? data['error']?.toString() : null;
      throw Exception(message ?? 'Profile lookup failed (' + response.status.toString() + ').');
    }
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<Map<String, dynamic>> myGameAccountVerification() async {
    final response = await client.functions.invoke('sync-freefire-profile', body: {
      'action': 'status',
    });
    if (response.status < 200 || response.status >= 300) {
      throw Exception('Could not load Free Fire ownership status (' + response.status.toString() + ').');
    }
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<Map<String, dynamic>> verifyFreeFireOwnership({
    required String accountId,
    required bool bioConfirmed,
  }) async {
    final response = await client.functions.invoke('sync-freefire-profile', body: {
      'action': 'verify',
      'account_id': accountId,
      'bio_confirmed': bioConfirmed,
    });
    final data = response.data is Map
        ? Map<String, dynamic>.from(response.data as Map)
        : <String, dynamic>{};
    if (response.status < 200 || response.status >= 300) {
      final message = data['error']?.toString() ??
          'Ownership verification failed (' + response.status.toString() + ').';
      throw Exception(message);
    }
    return data;
  }

  String _contentTypeFor(String? extension) {
    switch (extension?.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'pdf':
        return 'application/pdf';
      default:
        throw Exception('Unsupported evidence file. Use JPG, PNG, WebP or PDF.');
    }
  }

  Future<String> uploadEvidence(PlatformFile file, String matchId) async {
    final contentType = _contentTypeFor(file.extension);
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) throw Exception('The selected evidence file is empty.');
    if (bytes.length > 10 * 1024 * 1024) {
      throw Exception('Evidence files must be 10 MB or smaller.');
    }

    final safeName = file.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final path = '$userId/$matchId/${DateTime.now().millisecondsSinceEpoch}_$safeName';
    await client.storage.from('match-evidence').uploadBinary(
      path,
      bytes,
      fileOptions: FileOptions(contentType: contentType, upsert: false),
    );
    return path;
  }

  Future<List<Map<String, dynamic>>> myNotifications() async {
    final rows = await client.from('notifications').select().eq('user_id', userId)
      .order('created_at', ascending: false).limit(60);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<void> markNotificationRead(String notificationId) async {
    await client.from('notifications').update({
      'read_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', notificationId).eq('user_id', userId);
  }

  Future<void> updateNotificationPreferences(Map<String, bool> values) async {
    await client.from('notification_preferences').upsert({
      'user_id': userId,
      ...values,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'user_id');
  }

  Future<Map<String, dynamic>> notificationPreferences() async {
    final row = await client.from('notification_preferences')
      .select().eq('user_id', userId).maybeSingle();
    return row ?? {
      'push_enabled': true,
      'message_push': true,
      'mention_push': true,
      'event_push': true,
      'tournament_push': true,
      'marketing_push': false,
    };
  }
}
