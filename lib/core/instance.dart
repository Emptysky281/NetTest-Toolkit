// Named Windows instances use real, differently named executable files. Each
// launch owns its runtime and profile; no process memory or system executables
// are modified, and no shell is involved in starting the new application.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

String _join(String directory, String name) =>
    '$directory${Platform.pathSeparator}$name';
String _fileName(String path) => File(path).uri.pathSegments.last;

/// A filename, never a command line or a path. Windows process names come from
/// executable filenames; validate before creating any directories or files.
String instanceExecutableName(String input) {
  var name = input.trim();
  if (name.toLowerCase().endsWith('.exe')) {
    name = name.substring(0, name.length - 4);
  }
  if (name.isEmpty) throw const FormatException('请填写新实例的进程名');
  if (name.length > 64) throw const FormatException('进程名不能超过 64 个字符');
  if (RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(name) ||
      name == '.' ||
      name == '..') {
    throw const FormatException('名称不能包含路径或 <>:"/\\|?* 等字符');
  }
  if (name.endsWith('.') || name.endsWith(' ')) {
    throw const FormatException('进程名不能以句点或空格结尾');
  }
  if (RegExp(
    r'^(con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(name)) {
    throw const FormatException('该名称是 Windows 保留名称，请换一个');
  }
  return '$name.exe';
}

class DesktopInstance {
  DesktopInstance({
    required this.executablePath,
    required this.processId,
    this.profileDirectory,
  });
  final String executablePath;
  final int processId;
  final String? profileDirectory;
  String get processName => _fileName(executablePath);
  bool get isolated => profileDirectory != null;
  String get label => '$processName · PID $processId';
  String get windowTitle {
    const base = 'NetTest - 网络连接测试';
    return processName.toLowerCase() == 'nettest.exe'
        ? '$base [$processId]'
        : '$processName - $base [$processId]';
  }

  static const markerFileName = 'nettest.instance.json';
  static final current = DesktopInstance.load();

  /// A relative marker, not an inherited environment variable: double-clicking
  /// a previously created executable reopens its own profile, too.
  static DesktopInstance load({
    String? executablePath,
    int? processId,
    bool? windows,
  }) {
    final executable = File(executablePath ?? Platform.resolvedExecutable)
        .absolute;
    String? profile;
    if (windows ?? Platform.isWindows) {
      final marker = File(_join(executable.parent.path, markerFileName));
      if (marker.existsSync()) {
        final metadata = jsonDecode(marker.readAsStringSync());
        if (metadata is! Map ||
            metadata['version'] != 1 ||
            metadata['profile'] != '../profile') {
          throw const FormatException('多开实例配置损坏，请从主程序重新创建');
        }
        // Only this fixed sibling path is accepted, never a path supplied by JSON.
        profile = Directory(_join(executable.parent.parent.path, 'profile'))
            .absolute
            .path;
      }
    }
    return DesktopInstance(
      executablePath: executable.path,
      processId: processId ?? pid,
      profileDirectory: profile,
    );
  }
}

class InstanceLaunchResult {
  InstanceLaunchResult({
    required this.processName,
    required this.processId,
    required this.executablePath,
    required this.profileDirectory,
  });
  final String processName, executablePath, profileDirectory;
  final int processId;
}

typedef InstanceProcessStarter = Future<int> Function(
  String executable,
  String workingDirectory,
);

class NamedInstanceLauncher {
  NamedInstanceLauncher({
    required this.storageRoot,
    File? sourceExecutable,
    InstanceProcessStarter? startProcess,
  }) : sourceExecutable =
           (sourceExecutable ?? File(Platform.resolvedExecutable)).absolute,
       _startProcess = startProcess ?? _startDetached;
  final Directory storageRoot;
  final File sourceExecutable;
  final InstanceProcessStarter _startProcess;
  static final _random = Random.secure();

  static Future<int> _startDetached(
    String executable,
    String workingDirectory,
  ) async {
    final process = await Process.start(
      executable,
      const [],
      workingDirectory: workingDirectory,
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
    return process.pid;
  }

  Future<InstanceLaunchResult> launch(
    String name, {
    Map<String, Object?>? preferences,
    List<String> urlHistory = const [],
  }) async {
    if (!Platform.isWindows) throw UnsupportedError('自定义进程名多开目前仅支持 Windows');
    final filename = instanceExecutableName(name);
    // Freeze the parent's settings before the first await; never modify them.
    final copied = preferences == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(jsonEncode(preferences)) as Map);
    final history = List<String>.of(urlHistory.take(20));
    final source = sourceExecutable.parent;
    final requiredFiles = [
      sourceExecutable,
      File(_join(source.path, 'flutter_windows.dll')),
      File(_join(source.path, 'data/app.so')),
      File(_join(source.path, 'data/icudtl.dat')),
    ];
    for (final file in requiredFiles) {
      if (!await file.exists()) {
        throw FileSystemException(
          '请使用完整解压后的 Windows Release 程序，多开缺少运行文件',
          file.path,
        );
      }
    }

    await storageRoot.create(recursive: true);
    final allowedRoot = await storageRoot.resolveSymbolicLinks();
    final token =
        '${DateTime.now().microsecondsSinceEpoch}_${pid}_${_random.nextInt(0x100000000).toRadixString(16)}';
    final workspace = Directory(_join(allowedRoot, token));
    // Never reuse/overwrite a running executable or share an active profile.
    if (await workspace.exists()) throw const FileSystemException('实例目录冲突，请重试');
    var created = false;
    try {
      await workspace.create();
      created = true;
      final runtime = await Directory(_join(workspace.path, 'bundle')).create();
      final profile = await Directory(_join(workspace.path, 'profile'))
          .create();
      final downloads = await Directory(_join(profile.path, 'downloads'))
          .create();
      final executable = await sourceExecutable.copy(
        _join(runtime.path, filename),
      );
      // Copy runtime assets only; do not copy user downloads or recurse into old instances.
      await for (final entry in source.list(followLinks: false)) {
        final leaf = _fileName(entry.path),
            lower = _fileName(entry.path).toLowerCase();
        if (entry is Link && (lower.endsWith('.dll') || lower == 'data')) {
          throw FileSystemException('运行目录包含链接，请完整解压安装包后再多开', entry.path);
        }
        if (entry is File &&
            (lower.endsWith('.dll') || lower == 'native_assets.json')) {
          await entry.copy(_join(runtime.path, leaf));
        }
      }
      await _copyTree(
        Directory(_join(source.path, 'data')),
        Directory(_join(runtime.path, 'data')),
      );
      await File(_join(runtime.path, DesktopInstance.markerFileName))
          .writeAsString(
            jsonEncode({'version': 1, 'profile': '../profile'}),
            flush: true,
          );
      final settings = copied['settings'] is Map
          ? Map<String, dynamic>.from(copied['settings'] as Map)
          : <String, dynamic>{};
      settings['saveDir'] = downloads.path;
      // Copying one fixed local-port range across processes causes avoidable bind collisions.
      // A user who needs capture ranges can assign a separate range in the new window.
      settings['bindOn'] = false;
      copied['settings'] = settings;
      copied['version'] = 2;
      await File(_join(profile.path, 'settings.json'))
          .writeAsString(jsonEncode(copied), flush: true);
      await File(_join(profile.path, 'url_history.json'))
          .writeAsString(jsonEncode(history), flush: true);
      final processId = await _startProcess(executable.path, runtime.path);
      return InstanceLaunchResult(
        processName: filename,
        processId: processId,
        executablePath: executable.path,
        profileDirectory: profile.path,
      );
    } catch (_) {
      if (created) await _cleanFailedWorkspace(workspace, allowedRoot);
      rethrow;
    }
  }

  Future<void> _copyTree(Directory source, Directory target) async {
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException('运行数据目录不是普通目录', source.path);
    }
    await target.create(recursive: true);
    await for (final entry in source.list(followLinks: false)) {
      final destination = _join(target.path, _fileName(entry.path));
      if (entry is File) {
        await entry.copy(destination);
      } else if (entry is Directory) {
        await _copyTree(entry, Directory(destination));
      } else {
        throw FileSystemException('运行数据包含链接，请使用完整解压的安装包', entry.path);
      }
    }
  }

  Future<void> _cleanFailedWorkspace(Directory workspace, String root) async {
    try {
      if (await FileSystemEntity.type(workspace.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return;
      }
      final resolved = await workspace.resolveSymbolicLinks();
      final normalized = Platform.isWindows ? resolved.toLowerCase() : resolved;
      final allowed = Platform.isWindows ? root.toLowerCase() : root;
      // Resolve and check the absolute target BEFORE any recursive delete.
      if (normalized != allowed &&
          normalized.startsWith('$allowed${Platform.pathSeparator}')) {
        await Directory(resolved).delete(recursive: true);
      }
    } catch (_) {
      /* Preserve a partial bundle if cleanup is unavailable. */
    }
  }
}
