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
  bool inviteRevoked = false;
  Map<String, dynamic>? savedAppeal;
  Map<String, dynamic>? savedModerationAction;
  bool reportStatusSaved = false;
  Map<String, dynamic>? savedInviteConfiguration;
  final List<Map<String, dynamic>> joinRequests = [];
  final List<Map<String, dynamic>> reports = [];
  Map<String, dynamic>? savedSafetySettings;

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
  Future<void> saveCommunityAccessPolicy(String communityId, String visibility, bool approvalRequired) async {
    savedInviteConfiguration = {
      'visibility': visibility,
      'approval_required': approvalRequired,
    };
  }

  @override
  Future<Map<String, dynamic>> createInvite(String communityId, int? maxUses, int? expiresInHours, bool requiresApproval) async =>
      {'invite': {'id':'invite-1','requires_approval':requiresApproval}, 'code':'0123456789abcdef0123456789abcdef0123456789abcdef'};

  @override
  Future<void> revokeInvite(String inviteId) async {
    inviteRevoked = true;
  }

  @override
  Future<List<Map<String, dynamic>>> loadJoinRequests(String communityId) async =>
      List<Map<String, dynamic>>.from(joinRequests);

  @override
  Future<void> reviewJoinRequest(String requestId, String decision, String reason) async {
    final request = joinRequests.firstWhere((row) => row['id'] == requestId);
    request['status'] = decision == 'approve' ? 'approved' : 'rejected';
    request['review_reason'] = reason;
  }

  @override
  Future<void> reviewModerationReport(String reportId, String status, String note) async {
    reportStatusSaved = true;
    final report = reports.firstWhere((row) => row['id'] == reportId);
    report['status'] = status;
    report['review_note'] = note;
  }

  @override
  Future<String> submitModerationReport(String communityId, String? targetUserId, String? messageId, String reason, String details) async {
    reports.add({
      'id': 'report-12345678',
      'reporter_id': 'member-1',
      'target_user_id': targetUserId,
      'message_id': messageId,
      'reason': reason,
      'details': details,
      'status': 'open',
      'created_at': '2026-11-20T09:00:00Z',
    });
    return 'report-12345678';
  }

  @override
  Future<List<Map<String, dynamic>>> loadModerationActions(String communityId) async => const [
    {
      'id': '11111111-1111-4111-8111-111111111111',
      'action_type': 'warn',
      'target_user_id': 'member-1',
      'reason': 'Repeated harassment after community warning',
      'duration_minutes': null,
      'status': 'applied',
      'created_at': '2026-11-20T08:00:00Z',
    },
  ];

  @override
  Future<String> applyModerationAction(String communityId, Map<String, dynamic> action) async {
    savedModerationAction = Map<String, dynamic>.from(action);
    return 'action-1';
  }

  @override
  Future<List<Map<String, dynamic>>> loadAppeals(String communityId) async => savedAppeal == null
      ? const []
      : [Map<String, dynamic>.from(savedAppeal!)];

  @override
  Future<String> submitAppeal(String actionId, String reason, String details, String evidenceReference) async {
    savedAppeal = {
      'id': 'appeal-2026-001',
      'moderation_action_id': actionId,
      'appellant_id': 'member-1',
      'reason': reason,
      'details': details,
      'evidence_reference': evidenceReference,
      'status': 'pending',
      'reviewer_response': '',
      'created_at': '2026-11-20T09:00:00Z',
    };
    return 'appeal-2026-001';
  }

  @override
  Future<void> reviewAppeal(String appealId, String decision, String response, int? newDurationMinutes) async {
    if (savedAppeal != null) {
      savedAppeal!['status'] = decision == 'revoke' ? 'revoked' : decision == 'modify' ? 'modified' : decision == 'uphold' ? 'upheld' : 'dismissed';
      savedAppeal!['reviewer_response'] = response;
    }
  }

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
  Future<void> saveSafetySettings(String communityId, Map<String, dynamic> settings) async {
    savedSafetySettings = Map<String, dynamic>.from(settings);
  }

  @override
  Future<List<Map<String, dynamic>>> loadInvites(String communityId) async => [
    {
      'id': 'invite-12345678',
      'created_by': 'owner-1',
      'created_at': '2026-11-20T08:00:00Z',
      'expires_at': '2026-12-01T08:00:00Z',
      'max_uses': 25,
      'uses': 4,
      'revoked_at': inviteRevoked ? '2026-11-20T09:00:00Z' : null,
      'requires_approval': false,
    },
  ];

  @override
  Future<List<Map<String, dynamic>>> loadReports(String communityId) async =>
      List<Map<String, dynamic>>.from(reports);

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
  String communityVisibility = 'private',
  _FakeCommunityOperationsSource? source,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(MaterialApp(
    theme: KomnivoTheme.dark,
    home: CommunityOperationsScreen(
      community: {
        'id': 'community-test',
        'name': 'UI Test Community',
        'visibility': communityVisibility,
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

    await tester.ensureVisible(find.text('Team captains'));
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
    await tester.scrollUntilVisible(
      find.text('Save onboarding configuration'),
      260,
      scrollable: find.byType(Scrollable).last,
    );
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
    final onboardingScroll = find.descendant(
      of: find.byKey(const ValueKey('community-onboarding-scroll')),
      matching: find.byType(Scrollable),
    );
    // Managers see the full questionnaire editor above channel tagging.
    // Scroll the Onboarding tab, not a neighbouring TabBarView page.
    await tester.scrollUntilVisible(
      find.text('Save channel tags'),
      420,
      scrollable: onboardingScroll,
    );
    await tester.pumpAndSettle();
    final saveChannelTags = find.text('Save channel tags');
    expect(saveChannelTags, findsWidgets);
    await tester.tap(saveChannelTags.first);
    await tester.pumpAndSettle();

    expect(source.savedChannelTags.containsKey('channel-1'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Members can submit appeals and reviewers see persisted appeal records',
      (tester) async {
    addTearDown(() => _reset(tester));
    final source = _FakeCommunityOperationsSource();
    await _pumpOperations(tester, source: source, size: const Size(430, 1800));
    await _openOperationsTab(tester, 'Appeals');

    await tester.tap(find.text('Appeal this decision'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Why should this decision be reviewed?'),
      'The original moderation decision did not consider the available match evidence.',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Submit appeal'));
    await tester.tap(find.text('Submit appeal'));
    await tester.pumpAndSettle();

    expect(source.savedAppeal?['moderation_action_id'], '11111111-1111-4111-8111-111111111111');
    expect(find.text('PENDING'), findsOneWidget);
    expect(find.text('Appeal review queue'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Invite revoke is confirmed and persisted by the server operation',
      (tester) async {
    addTearDown(() => _reset(tester));
    final source = _FakeCommunityOperationsSource(
      permissions: {'community.manage_invites'},
    );
    await _pumpOperations(
      tester,
      permissions: {'community.manage_invites'},
      source: source,
    );
    await _openOperationsTab(tester, 'Invites');
    await tester.ensureVisible(find.text('Revoke now'));
    await tester.tap(find.text('Revoke now'));
    await tester.pumpAndSettle();

    expect(find.text('Revoke this invite?'), findsOneWidget);
    await tester.tap(find.text('Revoke invite'));
    await tester.pumpAndSettle();

    expect(source.inviteRevoked, isTrue);
    expect(find.text('REVOKED'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Authorised members can approve pending community join requests',
      (tester) async {
    addTearDown(() => _reset(tester));
    final source = _FakeCommunityOperationsSource(
      permissions: {'community.manage_members', 'community.manage_invites'},
    );
    source.joinRequests.add({
      'id': 'request-12345678',
      'user_id': 'member-2',
      'status': 'pending',
      'applicant_note': 'I want to join the competitive scrim group.',
      'created_at': '2026-11-20T08:30:00Z',
      'profiles': {'display_name': 'Orbit Mod', 'username': 'orbit'},
    });
    await _pumpOperations(
      tester,
      permissions: {'community.manage_members', 'community.manage_invites'},
      source: source,
      communityVisibility: 'public',
      size: const Size(430, 1700),
    );
    await _openOperationsTab(tester, 'Invites');

    expect(find.text('Join application queue'), findsOneWidget);
    expect(find.text('Orbit Mod'), findsOneWidget);
    await tester.ensureVisible(find.text('Approve').first);
    await tester.tap(find.text('Approve').first);
    await tester.pumpAndSettle();

    expect(find.text('Approve application?'), findsOneWidget);
    await tester.tap(find.text('Approve').last);
    await tester.pumpAndSettle();

    expect(source.joinRequests.single['status'], 'approved');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Invite settings create a one-time code and persist invite policy',
      (tester) async {
    addTearDown(() => _reset(tester));
    final source = _FakeCommunityOperationsSource(
      permissions: {'community.manage_invites'},
    );
    await _pumpOperations(
      tester,
      permissions: {'community.manage_invites'},
      source: source,
      communityVisibility: 'public',
    );
    await _openOperationsTab(tester, 'Invites');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.text('Invite settings'), findsOneWidget);
    final inviteOnly = find.widgetWithText(
      SwitchListTile,
      'Invite-only community',
    );
    await tester.ensureVisible(inviteOnly);
    await tester.tap(inviteOnly);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create invite'));
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Invite created'), findsOneWidget);
    expect(source.savedInviteConfiguration?['visibility'], 'private');
    expect(tester.takeException(), isNull);
  });


  testWidgets('Members can submit reports and moderators can review their status',
      (tester) async {
    addTearDown(() => _reset(tester));
    final source = _FakeCommunityOperationsSource(
      permissions: {'community.manage_members'},
    );
    await _pumpOperations(
      tester,
      permissions: {'community.manage_members'},
      source: source,
      size: const Size(430, 1700),
    );

    await tester.tap(find.text('Nova Ace').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prepare report'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'What happened?'),
      'Repeated abusive language in the public community channel.',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Submit report'));
    await tester.pumpAndSettle();

    expect(source.reports, hasLength(1));
    expect(source.reports.single['status'], 'open');
    // The member name is rendered in both the directory row and the
    // detail sheet. Select the top-most (sheet) instance to close that route.
    Navigator.of(tester.element(find.text('Nova Ace').last)).pop();
    await tester.pumpAndSettle();
    await _openOperationsTab(tester, 'Moderation');

    expect(find.text('Harassment or abuse'), findsOneWidget);
    await tester.ensureVisible(find.text('Update status'));
    await tester.tap(find.text('Update status'));
    await tester.pumpAndSettle();
    expect(find.text('Update report status'), findsOneWidget);
    await tester.tap(find.text('Save status'));
    await tester.pumpAndSettle();

    expect(source.reportStatusSaved, isTrue);
    expect(source.reports.single['status'], 'reviewing');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Moderation centre applies a scoped action and records it',
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
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(source.savedModerationAction?['action_type'], 'warn');
    expect(find.textContaining('Moderation action applied'), findsOneWidget);
    expect(find.text('NOT SENT'), findsNothing);
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

  testWidgets('Safety centre reviews and saves anti-spam windows and raid lockdown',
      (tester) async {
    addTearDown(() => _reset(tester));
    final source = _FakeCommunityOperationsSource(
      permissions: {'community.manage_settings'},
    );
    await _pumpOperations(
      tester,
      permissions: {'community.manage_settings'},
      source: source,
      size: const Size(430, 2100),
    );
    await _openOperationsTab(tester, 'Safety');

    await tester.enterText(find.byType(TextField).first, '6');
    await tester.scrollUntilVisible(
      find.text('Prepare lockdown'),
      260,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Prepare lockdown'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Review safety policy'),
      220,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Review safety policy'));
    await tester.pumpAndSettle();

    expect(find.text('Safety policy review'), findsOneWidget);
    expect(find.text('NOT APPLIED'), findsOneWidget);
    expect(find.textContaining('6 / 10 seconds'), findsOneWidget);
    expect(find.text('Message flood'), findsNWidgets(2));
    await tester.ensureVisible(find.text('Apply safety policy'));
    await tester.tap(find.text('Apply safety policy'));
    await tester.pumpAndSettle();

    expect(source.savedSafetySettings?['message_burst_limit'], 6);
    expect(source.savedSafetySettings?['lockdown_minutes'], 30);
    expect(find.text('Community safety policy saved and enforcement is active.'), findsOneWidget);
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
