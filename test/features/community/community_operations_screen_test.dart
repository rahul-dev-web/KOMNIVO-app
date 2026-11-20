import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:komnivo/core/komnivo_theme.dart';
import 'package:komnivo/features/community/community_operations_screen.dart';

class _FakeCommunityOperationsSource implements CommunityOperationsDataSource {
  _FakeCommunityOperationsSource({Set<String>? permissions})
      : permissions = permissions ?? <String>{};

  final Set<String> permissions;
  bool configurationSaved = false;
  Map<String, dynamic> savedAnswers = {};
  final Map<String, Map<String, List<String>>> savedChannelTags = {};

  List<Map<String, dynamic>> onboardingQuestions = [
    {
      'question_key': 'game_mode',
      'prompt': 'Which game mode do you play?',
      'question_type': 'single_select',
      'options': ['Battle Royale', 'Clash Squad'],
      'is_enabled': true,
      'is_required': false,
      'display_order': 1,
    },
    {
      'question_key': 'player_interests',
      'prompt': 'What are you interested in?',
      'question_type': 'multi_select',
      'options': ['Rank push', 'Competitive scrims', 'Casual matches', 'Content creation', 'Coaching', 'Team building'],
      'is_enabled': true,
      'is_required': false,
      'display_order': 2,
    },
    {
      'question_key': 'region',
      'prompt': 'Which region are you from?',
      'question_type': 'text',
      'options': [],
      'is_enabled': true,
      'is_required': false,
      'display_order': 3,
    },
    {
      'question_key': 'preferred_activities',
      'prompt': 'What would you like to do here?',
      'question_type': 'multi_select',
      'options': ['Find a team', 'Join tournaments', 'Play scrims', 'Learn strategies', 'Join voice sessions', 'Help organise events'],
      'is_enabled': true,
      'is_required': false,
      'display_order': 4,
    },
  ];

  @override
  Future<Set<String>> loadPermissions(String communityId) async => permissions;

  @override
  Future<Map<String, dynamic>> loadOnboardingData(String communityId) async => {
    'questions': onboardingQuestions,
    'answers': savedAnswers,
    'can_configure': permissions.contains('community.manage_members'),
  };

  @override
  Future<void> saveOnboardingConfiguration(
    String communityId,
    List<Map<String, dynamic>> questions,
  ) async {
    onboardingQuestions = questions.map((q) => Map<String, dynamic>.from(q)).toList();
    configurationSaved = true;
  }

  @override
  Future<void> submitOnboardingAnswers(
    String communityId,
    Map<String, dynamic> answers,
  ) async {
    savedAnswers = Map<String, dynamic>.from(answers);
  }

  @override
  Future<List<Map<String, dynamic>>> loadChannelRecommendations(
    String communityId,
  ) async {
    final interests = (savedAnswers['player_interests'] as List? ?? const [])
        .map((value) => value.toString()).toSet();
    final activities = (savedAnswers['preferred_activities'] as List? ?? const [])
        .map((value) => value.toString()).toSet();
    if (!interests.contains('Competitive scrims') &&
        !activities.contains('Play scrims')) {
      return const [];
    }
    return const [
      {
        'channel_id': 'channel-2',
        'name': 'scrim-hub',
        'kind': 'text',
        'matched_topics': ['Competitive scrims'],
        'matched_game_modes': ['Battle Royale'],
        'match_score': 2,
      },
      {
        'channel_id': 'channel-3',
        'name': 'looking-for-team',
        'kind': 'text',
        'matched_topics': ['Team building'],
        'matched_game_modes': [],
        'match_score': 1,
      },
    ];
  }

  @override
  Future<void> saveChannelOnboardingTags(
    String communityId,
    String channelId,
    List<String> topics,
    List<String> gameModes,
  ) async {
    savedChannelTags[channelId] = {
      'topics': List<String>.from(topics),
      'game_modes': List<String>.from(gameModes),
    };
  }

  @override
  Future<CommunityDirectoryData> loadDirectory(String communityId) async =>
      const CommunityDirectoryData(members: [
        {
          'user_id': 'member-1',
          'role': 'member',
          'joined_at': '2026-11-20T08:00:00Z',
          'muted_until': null,
          'profiles': {
            'display_name': 'Nova Ace',
            'username': 'nova',
            'avatar_url': null,
            'region': 'Central India',
            'is_public': true,
          },
          '_community_roles': [
            {'name': 'Player', 'preset_key': null, 'colour': '#66A8F2'},
          ],
          '_game_accounts': [
            {'ownership_status': 'verified', 'nickname': 'NovaAce'},
          ],
          '_is_team_captain': true,
          '_is_event_participant': true,
          '_is_event_staff': false,
        },
        {
          'user_id': 'member-2',
          'role': 'moderator',
          'joined_at': '2026-10-01T08:00:00Z',
          'muted_until': null,
          'profiles': {
            'display_name': 'Orbit Mod',
            'username': 'orbit',
            'avatar_url': null,
            'region': 'West',
            'is_public': false,
          },
          '_community_roles': [],
          '_game_accounts': [],
          '_is_team_captain': false,
          '_is_event_participant': false,
          '_is_event_staff': false,
        },
      ]);

  @override
  Future<CommunityIdentityData> loadIdentity(String communityId) async =>
      const CommunityIdentityData(
        signedIn: true,
        member: true,
        membershipRole: 'member',
        ownershipStatus: 'proof_pending',
      );


  @override
  Future<Map<String, dynamic>> loadCommunityAccessPolicy(String communityId) async =>
      {'visibility': 'private', 'join_approval_required': false};

  @override
  Future<void> saveCommunityAccessPolicy(String communityId, String visibility, bool approvalRequired) async {}

  @override
  Future<Map<String, dynamic>> createInvite(String communityId, int? maxUses, int? expiresInHours, bool requiresApproval) async =>
      {'invite': {'id':'invite-1','requires_approval':requiresApproval}, 'code':'0123456789abcdef0123456789abcdef0123456789abcdef'};

  @override
  Future<void> revokeInvite(String inviteId) async {}

  @override
  Future<List<Map<String, dynamic>>> loadJoinRequests(String communityId) async => const [];

  @override
  Future<void> reviewJoinRequest(String requestId, String decision, String reason) async {}

  @override
  Future<void> reviewModerationReport(String reportId, String status, String note) async {}

  @override
  Future<String> submitModerationReport(String communityId, String? targetUserId, String? messageId, String reason, String details) async => 'report-1';

  @override
  Future<List<Map<String, dynamic>>> loadModerationActions(String communityId) async => const [];

  @override
  Future<String> applyModerationAction(String communityId, Map<String, dynamic> action) async => 'action-1';

  @override
  Future<List<Map<String, dynamic>>> loadAppeals(String communityId) async => const [];

  @override
  Future<String> submitAppeal(String actionId, String reason, String details, String evidenceReference) async => 'appeal-1';

  @override
  Future<void> reviewAppeal(String appealId, String decision, String response, int? newDurationMinutes) async {}

  @override
  Future<Map<String, dynamic>> loadSafetySettings(String communityId) async => {
    'message_burst_limit': 6,
    'message_window_seconds': 10,
    'mention_burst_limit': 4,
    'mention_window_seconds': 60,
    'restrict_links_for_new_members': false,
    'new_member_link_restriction_hours': 24,
    'pause_invites_during_lockdown': true,
    'raid_join_threshold': 10,
    'raid_window_seconds': 60,
    'lockdown_until': null,
  };

  @override
  Future<void> saveSafetySettings(String communityId, Map<String, dynamic> settings) async {}

  @override
  Future<List<Map<String, dynamic>>> loadInvites(String communityId) async =>
      const [
        {
          'id': 'invite-12345678',
          'created_by': 'owner-1',
          'created_at': '2026-11-20T08:00:00Z',
          'expires_at': '2026-12-01T08:00:00Z',
          'max_uses': 25,
          'uses': 4,
        },
      ];

  @override
  Future<List<Map<String, dynamic>>> loadReports(String communityId) async =>
      const [];

  @override
  Future<List<Map<String, dynamic>>> loadChannelPolicies(String communityId) async =>
      [
        {
          'id': 'channel-1',
          'name': 'general',
          'kind': 'text',
          'event_id': null,
          'onboarding_topics': savedChannelTags['channel-1']?['topics'] ?? <String>[],
          'onboarding_game_modes': savedChannelTags['channel-1']?['game_modes'] ?? <String>[],
          'settings': {
            'read_only': false,
            'slow_mode_seconds': 15,
            'allow_links': false,
            'allow_everyone_mention': false,
          },
        },
        {
          'id': 'channel-2',
          'name': 'scrim-hub',
          'kind': 'text',
          'event_id': null,
          'onboarding_topics': savedChannelTags['channel-2']?['topics'] ?? <String>[],
          'onboarding_game_modes': savedChannelTags['channel-2']?['game_modes'] ?? <String>[],
          'settings': {},
        },
        {
          'id': 'channel-3',
          'name': 'looking-for-team',
          'kind': 'text',
          'event_id': null,
          'onboarding_topics': savedChannelTags['channel-3']?['topics'] ?? <String>[],
          'onboarding_game_modes': savedChannelTags['channel-3']?['game_modes'] ?? <String>[],
          'settings': {},
        },
      ];

  @override
  Future<List<Map<String, dynamic>>> loadAudit(String communityId) async =>
      const [];
}

Future<void> _pumpOperations(
  WidgetTester tester, {
  Set<String> permissions = const {},
  Size size = const Size(430, 900),
  _FakeCommunityOperationsSource? source,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(MaterialApp(
    theme: KomnivoTheme.dark,
    home: CommunityOperationsScreen(
      community: const {
        'id': 'community-test',
        'name': 'UI Test Community',
        'visibility': 'private',
      },
      dataSource: source ?? _FakeCommunityOperationsSource(permissions: permissions),
    ),
  ));
  await tester.pumpAndSettle();
}

void _reset(WidgetTester tester) {
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

Future<void> _openOperationsTab(WidgetTester tester, String label) async {
  final tab = find.descendant(
    of: find.byType(TabBar),
    matching: find.text(label),
  );
  expect(tab, findsOneWidget);
  tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Regular members only see directory and onboarding', (tester) async {
    addTearDown(() => _reset(tester));
    await _pumpOperations(tester);

    expect(find.text('Members'), findsOneWidget);
    expect(find.text('Onboarding'), findsOneWidget);
    expect(find.text('Appeals'), findsOneWidget);
    expect(find.text('Invites'), findsNothing);
    expect(find.text('Moderation'), findsNothing);
    expect(find.text('Safety'), findsNothing);
    expect(find.text('Audit'), findsNothing);
    expect(find.text('Member directory'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Management tabs are permission gated', (tester) async {
    addTearDown(() => _reset(tester));
    await _pumpOperations(
      tester,
      permissions: {
        'community.manage_members',
        'community.manage_invites',
        'community.manage_settings',
        'community.audit.read',
      },
    );

    for (final label in [
      'Members',
      'Onboarding',
      'Appeals',
      'Invites',
      'Moderation',
      'Safety',
      'Audit',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('Member directory filters show verified players and captains',
      (tester) async {
    addTearDown(() => _reset(tester));
    await _pumpOperations(tester);

    expect(find.text('Nova Ace'), findsOneWidget);
    await tester.tap(find.text('Verified players'));
    await tester.pumpAndSettle();
    expect(find.text('Nova Ace'), findsOneWidget);
    expect(find.text('Orbit Mod'), findsNothing);

    await tester.tap(find.text('Team captains'));
    await tester.pumpAndSettle();
    expect(find.text('Nova Ace'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Onboarding keeps sign-in UID ownership and membership separate',
      (tester) async {
    addTearDown(() => _reset(tester));
    await _pumpOperations(tester);
    await _openOperationsTab(tester, 'Onboarding');

    expect(find.text('Platform sign-in'), findsOneWidget);
    expect(find.text('Free Fire UID ownership'), findsOneWidget);
    expect(find.text('Community membership'), findsOneWidget);
    expect(find.textContaining('Verification proof pending'), findsOneWidget);
    expect(find.textContaining('Accepted · member'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Member answers persist and recommendations come from saved answers',
      (tester) async {
    addTearDown(() => _reset(tester));
    final source = _FakeCommunityOperationsSource();
    await _pumpOperations(tester, source: source);
    await _openOperationsTab(tester, 'Onboarding');

    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Battle Royale').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Competitive scrims'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Save my preferences'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save my preferences'));
    await tester.pumpAndSettle();

    expect(source.savedAnswers['game_mode'], 'Battle Royale');
    expect(source.savedAnswers['player_interests'], contains('Competitive scrims'));
    expect(find.text('Suggested community channels'), findsOneWidget);
    expect(find.text('scrim-hub'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Manager can save the four configured onboarding questions',
      (tester) async {
    addTearDown(() => _reset(tester));
    final source = _FakeCommunityOperationsSource(
      permissions: {'community.manage_members'},
    );
    await _pumpOperations(
      tester,
      permissions: {'community.manage_members'},
      source: source,
    );
    await _openOperationsTab(tester, 'Onboarding');
    await tester.ensureVisible(find.text('Save onboarding configuration'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save onboarding configuration'));
    await tester.pumpAndSettle();

    expect(source.configurationSaved, isTrue);
    expect(source.onboardingQuestions, hasLength(4));
    expect(find.text('Onboarding questions saved for this community.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Structure managers can tag channels without member question authority',
      (tester) async {
    addTearDown(() => _reset(tester));
    final source = _FakeCommunityOperationsSource(
      permissions: {'community.manage_structure'},
    );
    await _pumpOperations(
      tester,
      permissions: {'community.manage_structure'},
      size: const Size(430, 2800),
      source: source,
    );
    await _openOperationsTab(tester, 'Onboarding');

    expect(find.text('Save onboarding configuration'), findsNothing);
    expect(find.text('Save channel tags'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Manager can persist channel recommendation tags',
      (tester) async {
    addTearDown(() => _reset(tester));
    final source = _FakeCommunityOperationsSource(
      permissions: {'community.manage_members', 'community.manage_structure'},
    );
    await _pumpOperations(
      tester,
      permissions: {'community.manage_members', 'community.manage_structure'},
      size: const Size(430, 2800),
      source: source,
    );
    await _openOperationsTab(tester, 'Onboarding');
    await tester.ensureVisible(find.text('Save channel tags').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save channel tags').first);
    await tester.pumpAndSettle();

    expect(source.savedChannelTags.containsKey('channel-1'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Members can prepare appeals and reviewers see a separate queue',
      (tester) async {
    addTearDown(() => _reset(tester));
    await _pumpOperations(tester, size: const Size(430, 1400));
    await _openOperationsTab(tester, 'Appeals');

    await tester.ensureVisible(find.text('Moderation decision reference'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Moderation decision reference'),
      'decision-2026-001',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Explain why the decision should be reviewed'),
      'The decision did not include the supplied match evidence and roster context.',
    );
    await tester.ensureVisible(find.text('Review appeal'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review appeal'));
    await tester.pumpAndSettle();

    expect(find.text('Appeal review draft'), findsOneWidget);
    expect(find.text('NOT SUBMITTED'), findsOneWidget);
    expect(find.text('My appeal history'), findsOneWidget);

    _reset(tester);
  });

  testWidgets('Invite revoke requires confirmation and remains a draft',
      (tester) async {
    addTearDown(() => _reset(tester));
    await _pumpOperations(
      tester,
      permissions: {'community.manage_invites'},
    );
    await _openOperationsTab(tester, 'Invites');
    await tester.ensureVisible(find.text('Prepare revoke'));
    expect(find.text('Prepare revoke'), findsOneWidget);

    await tester.tap(find.text('Prepare revoke'));
    await tester.pumpAndSettle();
    expect(find.text('Revoke invite?'), findsOneWidget);
    await tester.tap(find.text('Review revoke'));
    await tester.pumpAndSettle();

    expect(find.text('Invite revoke review'), findsOneWidget);
    expect(find.text('NOT REVOKED'), findsOneWidget);
    expect(find.textContaining('remains usable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Invite draft exposes invite-only and approval choices',
      (tester) async {
    addTearDown(() => _reset(tester));
    await _pumpOperations(
      tester,
      permissions: {'community.manage_invites'},
    );
    await _openOperationsTab(tester, 'Invites');
    await tester.ensureVisible(find.text('Create'));
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(SwitchListTile).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review settings'));
    await tester.pumpAndSettle();

    expect(find.text('Invite configuration draft'), findsOneWidget);
    expect(find.text('Invite-only'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });


  testWidgets('Invite creation remains an unsaved configuration draft',
      (tester) async {
    addTearDown(() => _reset(tester));
    await _pumpOperations(
      tester,
      permissions: {'community.manage_invites'},
    );
    await _openOperationsTab(tester, 'Invites');
    await tester.ensureVisible(find.text('Create'));
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review settings'));
    await tester.pumpAndSettle();

    expect(find.text('Invite configuration draft'), findsOneWidget);
    expect(find.text('UNSAVED'), findsOneWidget);
    expect(find.textContaining('No token or shareable URL exists'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Moderation actions produce review drafts, not fake success',
      (tester) async {
    addTearDown(() => _reset(tester));
    await _pumpOperations(
      tester,
      permissions: {'community.manage_members'},
    );
    await _openOperationsTab(tester, 'Moderation');
    await tester.tap(find.text('New action'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byWidgetPredicate(
        (widget) => widget is TextField &&
            widget.decoration?.labelText == 'Target member ID / reference (required)',
      ),
      'member-1',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Reason (required)'),
      'Repeated harassment after community warning',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prepare action'));
    await tester.pumpAndSettle();

    expect(find.text('Action ready for backend review'), findsOneWidget);
    expect(find.text('NOT SENT'), findsOneWidget);
    expect(find.textContaining('No member state has changed'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Safety tab reads the actual channel policy shape',
      (tester) async {
    addTearDown(() => _reset(tester));
    await _pumpOperations(
      tester,
      permissions: {'community.manage_settings'},
      size: const Size(430, 2100),
    );
    await _openOperationsTab(tester, 'Safety');

    expect(find.text('Community safety'), findsOneWidget);
    expect(find.text('#general'), findsOneWidget);
    expect(find.text('SLOW MODE 15s'), findsOneWidget);
    expect(find.text('LINKS BLOCKED'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Safety centre reviews anti-spam windows and raid lockdown without applying',
      (tester) async {
    addTearDown(() => _reset(tester));
    await _pumpOperations(
      tester,
      permissions: {'community.manage_settings'},
      size: const Size(430, 2100),
    );
    await _openOperationsTab(tester, 'Safety');

    await tester.enterText(find.byType(TextField).first, '6');
    await tester.tap(find.text('Prepare lockdown'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review safety policy'));
    await tester.pumpAndSettle();

    expect(find.text('Safety policy review'), findsOneWidget);
    expect(find.text('NOT APPLIED'), findsOneWidget);
    expect(find.textContaining('6 / 10 seconds'), findsOneWidget);
    expect(find.text('Message flood'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Audit tab opens only for audit readers and shows real empty state',
      (tester) async {
    addTearDown(() => _reset(tester));
    await _pumpOperations(
      tester,
      permissions: {'community.audit.read'},
    );
    expect(find.text('Audit'), findsOneWidget);
    await _openOperationsTab(tester, 'Audit');
    expect(find.text('Audit history'), findsOneWidget);
    expect(find.text('No audit records'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Operations centre remains usable at desktop width',
      (tester) async {
    addTearDown(() => _reset(tester));
    await _pumpOperations(
      tester,
      size: const Size(1280, 900),
      permissions: {
        'community.manage_members',
        'community.manage_invites',
        'community.manage_settings',
        'community.audit.read',
      },
    );
    expect(find.text('MEMBERS & SAFETY CENTRE'), findsOneWidget);
    expect(find.text('Member directory'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
