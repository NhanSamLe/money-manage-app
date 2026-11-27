/// Pure parsing for the in-app update check (GitHub Releases), kept free of Flutter so it is unit-testable.
/// Releases are tagged `v<versionName>+<build>` (e.g. `v0.2.0+5`) and carry one `.apk` asset.
class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.versionName,
    required this.build,
    required this.notes,
    required this.apkUrl,
    required this.apkSize,
    required this.pageUrl,
  });

  final String tag;
  final String versionName;
  final int build;
  final String notes;
  final String apkUrl;
  final int apkSize;
  final String pageUrl;

  /// Null when the JSON is not a usable release (draft, pre-release, no build number or no APK asset).
  static ReleaseInfo? fromGitHub(Map<String, dynamic> j) {
    if (j['draft'] == true || j['prerelease'] == true) return null;
    final tag = (j['tag_name'] as String?) ?? '';
    final parsed = parseReleaseTag(tag);
    if (parsed == null) return null;
    final assets = ((j['assets'] as List<dynamic>?) ?? const [])
        .cast<Map<String, dynamic>>()
        .where(
          (a) => ((a['name'] as String?) ?? '').toLowerCase().endsWith('.apk'),
        )
        .toList();
    if (assets.isEmpty) return null;
    // Prefer the "MoMa-..." asset when a release carries more than one APK.
    assets.sort((a, b) {
      final am = ((a['name'] as String?) ?? '').startsWith('MoMa-') ? 0 : 1;
      final bm = ((b['name'] as String?) ?? '').startsWith('MoMa-') ? 0 : 1;
      return am.compareTo(bm);
    });
    final apk = assets.first;
    final url = apk['browser_download_url'] as String?;
    if (url == null || !url.startsWith('https://')) return null;
    return ReleaseInfo(
      tag: tag,
      versionName: parsed.versionName,
      build: parsed.build,
      notes: stripMarkdown((j['body'] as String?) ?? ''),
      apkUrl: url,
      apkSize: (apk['size'] as num?)?.toInt() ?? 0,
      pageUrl: (j['html_url'] as String?) ?? '',
    );
  }
}

/// `v0.2.0+5` -> (versionName: 0.2.0, build: 5). Null when the tag does not follow the convention.
({String versionName, int build})? parseReleaseTag(String tag) {
  final m = RegExp(r'^v?(\d+\.\d+\.\d+)\+(\d+)$').firstMatch(tag.trim());
  if (m == null) return null;
  return (versionName: m.group(1)!, build: int.parse(m.group(2)!));
}

/// True when [release] is a newer build than the installed [installedBuild] (package_info buildNumber).
bool isNewerBuild(ReleaseInfo release, String installedBuild) {
  final current = int.tryParse(installedBuild.trim());
  if (current == null) return false;
  return release.build > current;
}

/// Release notes as plain text: headings, emphasis, code marks, links and images reduced to their text,
/// list markers turned into "- ", blank-line runs collapsed.
String stripMarkdown(String md) {
  var s = md.replaceAll('\r\n', '\n');
  s = s.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
  s = s.replaceAll(RegExp(r'```[^\n]*\n?'), '');
  s = s.replaceAllMapped(RegExp(r'!\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1)!);
  s = s.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m.group(1)!);
  s = s.replaceAll(RegExp(r'<[^>\n]+>'), '');
  final lines = <String>[];
  for (var line in s.split('\n')) {
    line = line.replaceFirst(RegExp(r'^\s{0,3}#{1,6}\s+'), '');
    line = line.replaceFirst(RegExp(r'^\s{0,3}>\s?'), '');
    line = line.replaceFirstMapped(
      RegExp(r'^(\s*)[*+-]\s+'),
      (m) => '${m.group(1)}- ',
    );
    if (RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$').hasMatch(line)) line = '';
    line = line
        .replaceAllMapped(RegExp(r'(\*\*|__)(.+?)\1'), (m) => m.group(2)!)
        .replaceAllMapped(
          RegExp(r'(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?!\w)'),
          (m) => m.group(1)!,
        )
        .replaceAllMapped(RegExp(r'~~(.+?)~~'), (m) => m.group(1)!)
        .replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m.group(1)!);
    lines.add(line.trimRight());
  }
  return lines.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}
