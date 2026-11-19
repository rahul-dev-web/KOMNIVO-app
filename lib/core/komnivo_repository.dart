import 'dart:typed_data';
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

  /// Ask the database's canonical permission resolver. The UI uses this only
  /// to decide which controls to show; RLS and privileged RPCs enforce access.
  Future<bool> hasPermission({
    required String permissionKey,
    required String scopeType,
    required String scopeId,
    String? relatedId,
    String? resourceId,
  }) async {
    final result = await client.rpc('has_permission', params: {
      'p_permission_key': permissionKey,
      'p_scope_type': scopeType,
      'p_scope_id': scopeId,
      'p_related_id': relatedId,
      'p_resource_id': resourceId,
    });
    return result == true;
  }

  /// Starts a server-bound LiveOps session for a platform Match ID.
  Future<Map<String, dynamic>> startLiveOpsSession({
    required String matchId,
    Map<String, dynamic> deviceInfo = const <String, dynamic>{},
  }) async {
    final result = await client.rpc('start_liveops_session', params: {
      'p_match_id': matchId,
      'p_device_info': deviceInfo,
    });
    if (result is! Map) {
      throw Exception('LiveOps session could not be created.');
    }
    return Map<String, dynamic>.from(result);
  }


  /// Reads this user's own membership rows, including the owner row created
  /// by the database trigger when a community is created.
  Future<Map<String, Map<String, dynamic>>> myCommunityMemberships() async {
    final rows = await client.from('community_members')
        .select('community_id,role')
        .eq('user_id', userId);
    final memberships = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final membership = Map<String, dynamic>.from(row);
      final id = membership['community_id']?.toString();
      if (id != null && id.isNotEmpty) memberships[id] = membership;
    }
    return memberships;
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

  Future<String> uploadCommunityLogo({
    required String communityId,
    required Uint8List bytes,
    required String extension,
    required String contentType,
  }) async {
    if (bytes.isEmpty || bytes.length > 2 * 1024 * 1024) {
      throw Exception('Community logo must be smaller than 2 MB.');
    }
    const allowed = {'jpg', 'jpeg', 'png', 'webp'};
    final normalizedExtension = extension.toLowerCase();
    if (!allowed.contains(normalizedExtension)) {
      throw Exception('Use a JPG, PNG or WebP community logo.');
    }

    final path = '$userId/$communityId/logo-${DateTime.now().microsecondsSinceEpoch}.$normalizedExtension';
    await client.storage.from('community-media').uploadBinary(
      path,
      bytes,
      fileOptions: FileOptions(
        contentType: contentType,
        cacheControl: '3600',
      ),
    );
    return path;
  }

  Future<Map<String, dynamic>> updateCommunity({
    required String communityId,
    required String name,
    required String description,
    required String visibility,
    String? iconUrl,
  }) async {
    final updates = <String, dynamic>{
      'name': name.trim(),
      'description': description.trim(),
      'visibility': visibility,
    };
    if (iconUrl != null) updates['icon_url'] = iconUrl;
    final row = await client.from('communities').update(updates)
        .eq('id', communityId).select().single();
    return Map<String, dynamic>.from(row);
  }

  Future<Map<String, dynamic>> createCommunityChannel({
    required String communityId,
    required String name,
    required String description,
    required String kind,
  }) async {
    final normalizedName = name.trim().toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-');
    final row = await client.from('channels').insert({
      'community_id': communityId,
      'name': normalizedName,
      'description': description.trim(),
      'kind': kind,
      'is_private': false,
      'created_by': userId,
    }).select().single();
    return Map<String, dynamic>.from(row);
  }

  Future<Map<String, dynamic>> updateCommunityChannel({
    required String channelId,
    required String name,
    required String description,
  }) async {
    final normalizedName = name.trim().toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-');
    final row = await client.from('channels').update({
      'name': normalizedName,
      'description': description.trim(),
    }).eq('id', channelId).select().single();
    return Map<String, dynamic>.from(row);
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

  Future<Set<String>> messagePinIds(String channelId) async {
    final rows = await client.from('message_pins').select('message_id')
      .eq('channel_id', channelId);
    return rows.map((row) => row['message_id'].toString()).toSet();
  }

  Future<void> toggleMessagePin(String channelId, String messageId) async {
    final existing = await client.from('message_pins').select('message_id')
      .eq('channel_id', channelId).eq('message_id', messageId).maybeSingle();
    if (existing != null) {
      await client.from('message_pins').delete()
        .eq('channel_id', channelId).eq('message_id', messageId);
    } else {
      await client.from('message_pins').insert({
        'channel_id': channelId, 'message_id': messageId, 'pinned_by': userId,
      });
    }
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


  Future<List<Map<String, dynamic>>> channelCategories(String communityId) async {
    final rows = await client.from('channel_categories').select()
      .eq('community_id', communityId).order('position');
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<Map<String, dynamic>> createChannelCategory({
    required String communityId, required String name, required int position,
  }) async {
    final row = await client.from('channel_categories').insert({
      'community_id': communityId, 'name': name.trim(),
      'created_by': userId, 'position': position,
    }).select().single();
    return Map<String, dynamic>.from(row);
  }

  Future<void> updateChannelCategory({
    required String categoryId, String? name, int? position, bool? archived,
  }) async {
    final updates = <String, dynamic>{};
    if (name != null) updates['name'] = name.trim();
    if (position != null) updates['position'] = position;
    if (archived != null) updates['archived_at'] = archived
      ? DateTime.now().toUtc().toIso8601String() : null;
    if (updates.isEmpty) return;
    await client.from('channel_categories').update(updates).eq('id', categoryId);
  }

  Future<void> assignChannelCategory(String channelId, String? categoryId) async {
    await client.from('channels').update({'category_id': categoryId}).eq('id', channelId);
  }

  Future<List<Map<String, dynamic>>> forumPosts(String channelId) async {
    final rows = await client.from('forum_posts').select()
      .eq('channel_id', channelId).order('is_pinned', ascending: false)
      .order('created_at', ascending: false).limit(100);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<Map<String, dynamic>> createForumPost({
    required String channelId,
    required String communityId,
    required String title,
    required String body,
    required String tag,
  }) async {
    final row = await client.from('forum_posts').insert({
      'channel_id': channelId, 'community_id': communityId, 'author_id': userId,
      'title': title.trim(), 'body': body.trim(), 'tag': tag,
    }).select().single();
    return Map<String, dynamic>.from(row);
  }

  Future<void> moderateForumPost({
    required String postId, required String status, bool? locked, bool? pinned,
  }) async {
    await client.rpc('set_forum_post_status', params: {
      'p_post_id': postId, 'p_status': status, 'p_locked': locked, 'p_pinned': pinned,
    });
  }

  Future<List<Map<String, dynamic>>> forumReplies(String postId) async {
    final rows = await client.from('forum_post_replies').select()
      .eq('post_id', postId).order('created_at');
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<void> createForumReply(String postId, String body) async {
    final text = body.trim();
    if (text.isEmpty) throw Exception('Reply cannot be empty.');
    await client.from('forum_post_replies').insert({
      'post_id': postId, 'author_id': userId, 'body': text,
    });
  }


  Future<String> createChannelPoll({
    required String channelId,
    required String communityId,
    required String question,
    required List<String> options,
    bool allowMultiple = false,
    DateTime? closesAt,
  }) async {
    final result = await client.rpc('create_channel_poll', params: {
      'p_channel_id': channelId,
      'p_community_id': communityId,
      'p_question': question.trim(),
      'p_options': options,
      'p_allow_multiple': allowMultiple,
      'p_closes_at': closesAt?.toUtc().toIso8601String(),
    });
    return result.toString();
  }

  Future<List<Map<String, dynamic>>> channelPollOptions(String pollId) async {
    final rows = await client.from('channel_poll_options').select()
      .eq('poll_id', pollId).order('position');
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<int> voteChannelPoll(String pollId, List<String> optionIds) async {
    final result = await client.rpc('vote_channel_poll', params: {
      'p_poll_id': pollId,
      'p_option_ids': optionIds,
    });
    return result as int;
  }

  Future<void> cancelChannelAnnouncement(String announcementId) async {
    await client.rpc('cancel_channel_announcement', params: {
      'p_announcement_id': announcementId,
    });
  }

  Future<Map<String, dynamic>> channelSettings(String channelId) async {
    final row = await client.from('channel_settings').select()
      .eq('channel_id', channelId).maybeSingle();
    return row == null ? <String, dynamic>{} : Map<String, dynamic>.from(row);
  }

  Future<Map<String, dynamic>> saveChannelSettings({
    required String channelId, required String communityId,
    required Map<String, dynamic> settings,
  }) async {
    final row = await client.from('channel_settings').upsert({
      'channel_id': channelId, 'community_id': communityId,
      ...settings, 'updated_by': userId,
    }, onConflict: 'channel_id').select().single();
    return Map<String, dynamic>.from(row);
  }

  Future<void> setCategoryCollapsed(String categoryId, bool collapsed) async {
    await client.from('channel_category_preferences').upsert({
      'category_id': categoryId, 'user_id': userId, 'is_collapsed': collapsed,
    }, onConflict: 'category_id,user_id');
  }

  Future<Map<String, dynamic>> scheduleChannelAnnouncement({
    required String channelId, required String communityId,
    required String body, required DateTime publishAt,
  }) async {
    final row = await client.from('scheduled_channel_announcements').insert({
      'channel_id': channelId, 'community_id': communityId, 'created_by': userId,
      'body': body.trim(), 'publish_at': publishAt.toUtc().toIso8601String(),
    }).select().single();
    return Map<String, dynamic>.from(row);
  }

  Stream<List<Map<String, dynamic>>> messageStream(String channelId) {
    return client.from('messages').stream(primaryKey: ['id']).eq('channel_id', channelId).order('created_at');
  }

  Future<Map<String, dynamic>> prepareFreeFireVerification(
    String uid, {
    String region = 'ind',
  }) async {
    final response = await client.functions.invoke('sync-freefire-profile', body: {
      'action': 'prepare',
      'uid': uid.trim(),
      'region': region,
    });
    final data = response.data is Map
        ? Map<String, dynamic>.from(response.data as Map)
        : <String, dynamic>{};
    if (response.status < 200 || response.status >= 300) {
      throw Exception(data['error']?.toString() ??
          'Could not prepare verification code (' + response.status.toString() + ').');
    }
    return data;
  }

  Future<Map<String, dynamic>> myGameAccountVerification() async {
    final response = await client.functions.invoke('sync-freefire-profile', body: {
      'action': 'status',
    });
    final data = response.data is Map
        ? Map<String, dynamic>.from(response.data as Map)
        : <String, dynamic>{};
    if (response.status < 200 || response.status >= 300) {
      throw Exception(data['error']?.toString() ??
          'Could not load Free Fire ownership status (' + response.status.toString() + ').');
    }
    return data;
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

    // 429 is a server-side retry throttle and does not consume an attempt.
    // A 409 no_active_code is also a recoverable challenge-state response:
    // the UI clears the stale code and lets the owner generate a replacement.
    if (response.status == 429 || data['status'] == 'no_active_code') {
      return data;
    }

    if (response.status < 200 || response.status >= 300) {
      throw Exception(data['error']?.toString() ??
          'Ownership verification failed (' + response.status.toString() + ').');
    }
    return data;
  }

  Future<List<Map<String, dynamic>>> storeListings() async {
    final rows = await client.from('store_listings')
        .select('*, seller:profiles!store_listings_seller_id_fkey(display_name, username, avatar_url)')
        .eq('status', 'published')
        .order('created_at', ascending: false)
        .limit(100);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<List<Map<String, dynamic>>> myStoreListings() async {
    final rows = await client.from('store_listings')
        .select()
        .eq('seller_id', userId)
        .order('created_at', ascending: false)
        .limit(100);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<Map<String, dynamic>> createStoreListing({
    required String categoryKey,
    required String title,
    required String role,
    required String description,
    required String game,
    required String region,
    required double priceAmount,
    required String pricingModel,
  }) async {
    final row = await client.from('store_listings').insert({
      'seller_id': userId,
      'category_key': categoryKey,
      'title': title.trim(),
      'role': role.trim(),
      'description': description.trim(),
      'game': game.trim(),
      'region': region.trim().isEmpty ? 'Remote' : region.trim(),
      'price_amount': priceAmount,
      'pricing_model': pricingModel,
      'currency': 'INR',
      'status': 'published',
    }).select().single();
    return Map<String, dynamic>.from(row);
  }

  Future<void> updateStoreListingStatus(String listingId, String status) async {
    if (!const {'published', 'paused', 'archived'}.contains(status)) {
      throw ArgumentError.value(status, 'status');
    }
    await client.from('store_listings')
        .update({'status': status})
        .eq('id', listingId)
        .eq('seller_id', userId);
  }

  Future<List<Map<String, dynamic>>> storeCartItems() async {
    final rows = await client.from('store_cart_items')
        .select('id,listing_id,quantity,store_listings!inner(id,seller_id,category_key,title,role,description,game,region,price_amount,pricing_model,status)')
        .eq('buyer_id', userId)
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<void> addStoreCartItem(String listingId) async {
    final existing = await client.from('store_cart_items')
        .select('id,quantity')
        .eq('buyer_id', userId)
        .eq('listing_id', listingId)
        .maybeSingle();
    if (existing == null) {
      await client.from('store_cart_items').insert({
        'buyer_id': userId,
        'listing_id': listingId,
        'quantity': 1,
      });
      return;
    }
    final nextQuantity = (existing['quantity'] as int? ?? 1) + 1;
    if (nextQuantity > 20) throw Exception('Maximum quantity for one listing is 20.');
    await client.from('store_cart_items')
        .update({'quantity': nextQuantity})
        .eq('id', existing['id']);
  }

  Future<void> updateStoreCartQuantity(String cartItemId, int quantity) async {
    if (quantity < 1 || quantity > 20) throw ArgumentError.value(quantity, 'quantity');
    await client.from('store_cart_items')
        .update({'quantity': quantity})
        .eq('id', cartItemId)
        .eq('buyer_id', userId);
  }

  Future<void> removeStoreCartItem(String cartItemId) async {
    await client.from('store_cart_items')
        .delete()
        .eq('id', cartItemId)
        .eq('buyer_id', userId);
  }

  Future<Map<String, dynamic>> createStoreOrder(
      List<Map<String, dynamic>> items) async {
    final result = await client.rpc('create_store_order', params: {
      'p_items': items,
    });
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> createStoreInquiry({
    required String listingId,
    required String sellerId,
    required String message,
  }) async {
    final row = await client.from('store_inquiries').insert({
      'listing_id': listingId,
      'buyer_id': userId,
      'seller_id': sellerId,
      'message': message.trim(),
    }).select().single();
    return Map<String, dynamic>.from(row);
  }

  Future<List<Map<String, dynamic>>> myStoreInquiries() async {
    final rows = await client.from('store_inquiries')
        .select('*, store_listings(title,category_key), buyer:profiles!store_inquiries_buyer_id_fkey(display_name,username)')
        .eq('seller_id', userId)
        .order('created_at', ascending: false)
        .limit(50);
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<void> updateStoreInquiryStatus(String inquiryId, String status) async {
    if (!const {'open', 'responded', 'closed'}.contains(status)) {
      throw ArgumentError.value(status, 'status');
    }
    await client.from('store_inquiries')
        .update({'status': status})
        .eq('id', inquiryId)
        .eq('seller_id', userId);
  }

  Future<List<Map<String, dynamic>>> storeOrders() async {
    final rows = await client.from('store_orders')
        .select('*, store_order_items(*)')
        .eq('buyer_id', userId)
        .order('created_at', ascending: false)
        .limit(50);
    return List<Map<String, dynamic>>.from(rows);
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
