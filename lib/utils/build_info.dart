/// Compile-time identity for the optional SyncPlay test distribution.
///
/// Normal builds intentionally keep the existing Kazumi behaviour and use the
/// fallback values below.  The temporary test workflow supplies all four
/// values with `--dart-define` so a package can be traced back to both the
/// feature source and the exact test-build commit.
const bool kSyncPlayTestBuild =
    bool.fromEnvironment('SYNCPLAY_TEST_BUILD', defaultValue: false);

const String kSyncPlayFeatureSha = String.fromEnvironment(
  'SYNCPLAY_FEATURE_SHA',
  defaultValue: 'unknown',
);

const String kSyncPlayTestSha = String.fromEnvironment(
  'SYNCPLAY_TEST_SHA',
  defaultValue: 'unknown',
);

const String kSyncPlayBuildId = String.fromEnvironment(
  'SYNCPLAY_BUILD_ID',
  defaultValue: 'local',
);

const String kSyncPlayTestProductName = 'Kazumi SyncPlay Test';

String get syncPlayBuildIdentity => [
      kSyncPlayTestBuild
          ? '非官方 SyncPlay 测试构建'
          : 'Kazumi 正式构建',
      'Feature SHA: $kSyncPlayFeatureSha',
      'Test SHA: $kSyncPlayTestSha',
      'Build ID: $kSyncPlayBuildId',
    ].join('\n');
