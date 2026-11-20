import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:komnivo/core/komnivo_theme.dart';
import 'package:komnivo/features/community/community_operations_screen.dart';

class _FakeCommunityOperationsSource implements CommunityOperationsDataSource {
  _FakeCommunityOperationsSource({Set<String>? permissions})
      : permissions = permissions ?? <String>{};

  final Set<String> permissions;

  @override
  Future<Set<String>> loadPermissions(String communityId) async => permissions;

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
      const [
        {
          'id': 'channel-1',
          'name': 'general',
          'kind': 'text',
          'settings': {
            'read_only': false,
            'slow_mode_seconds': 15,
            'allow_links': false,
            'allow_everyone_mention': false,
          },
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
      dataSource: _FakeCommunityOperationsSource(permissions: permissions),
    ),
  ));
  await tester.pumpAndSettle();
}

void _reset(WidgetTester tester) {
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

void main() {
  testWidgets('Regular members only see directory and onboarding', (tester) async {
    addTearDown(() => _reset(tester));
    await _pumpOperations(tester);

    expect(find.text('Members'), findsOneWidget);
    expect(find.text('Onboarding'), findsOneWidget);
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
    await tester.tap(find.text('Onboarding'));
    await tester.pumpAndSettle();

    expect(find.text('Platform sign-in'), findsOneWidget);
    expect(find.text('Free Fire UID ownership'), findsOneWidget);
    expect(find.text('Community membership'), findsOneWidget);
    expect(find.textContaining('Verification proof pending'), findsOneWidget);
    expect(find.textContaining('Accepted · member'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Invite revoke requires confirmation and remains a draft',
      (tester) async {
    addTearDown(() => _reset(tester));
    await _pumpOperations(
      tester,
      permissions: {'community.manage_invites'},
    );
    await tester.tap(find.text('Invites'));
    await tester.pumpAndSettle();
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
    await tester.tap(find.text('Invites'));
    await tester.pumpAndSettle();
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
    await tester.tap(find.text('Invites'));
    await tester.pumpAndSettle();
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
    await tester.tap(find.text('Moderation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New action'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField).last,
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
    );
    await tester.tap(find.text('Safety'));
    await tester.pumpAndSettle();

    expect(find.text('Community safety'), findsOneWidget);
    expect(find.text('#general'), findsOneWidget);
    expect(find.text('SLOW MODE 15s'), findsOneWidget);
    expect(find.text('LINKS BLOCKED'), findsOneWidget);
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
    expect(find.text('Members & Safety Centre'), findsNothing);
    expect(find.text('Member directory'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
