// Windows "save as" dialog (GetSaveFileNameW) through dart:ffi, run on a background isolate so the
// Flutter window keeps painting while the modal dialog is open.
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

final class _OpenFileNameW extends Struct {
  @Uint32()
  external int lStructSize;
  external Pointer<Void> hwndOwner;
  external Pointer<Void> hInstance;
  external Pointer<Utf16> lpstrFilter;
  external Pointer<Utf16> lpstrCustomFilter;
  @Uint32()
  external int nMaxCustFilter;
  @Uint32()
  external int nFilterIndex;
  external Pointer<Utf16> lpstrFile;
  @Uint32()
  external int nMaxFile;
  external Pointer<Utf16> lpstrFileTitle;
  @Uint32()
  external int nMaxFileTitle;
  external Pointer<Utf16> lpstrInitialDir;
  external Pointer<Utf16> lpstrTitle;
  @Uint32()
  external int flags;
  @Uint16()
  external int nFileOffset;
  @Uint16()
  external int nFileExtension;
  external Pointer<Utf16> lpstrDefExt;
  external Pointer<Void> lCustData;
  external Pointer<Void> lpfnHook;
  external Pointer<Utf16> lpTemplateName;
  external Pointer<Void> pvReserved;
  @Uint32()
  external int dwReserved;
  @Uint32()
  external int flagsEx;
}

const _ofnOverwritePrompt = 0x2,
    _ofnHideReadOnly = 0x4,
    _ofnNoChangeDir = 0x8,
    _ofnPathMustExist = 0x800;
const _maxPath = 1024;

/// Returns the chosen path, or null when the user cancels. [filter] pairs: (label, pattern), e.g.
/// ('CSV', '*.csv'). [windowTitle] identifies the owner window so the dialog is modal to it.
Future<String?> windowsSaveDialog({
  required String title,
  required String initialDir,
  required String fileName,
  required String defaultExt,
  required List<(String, String)> filter,
  String windowTitle = 'NetTest - 网络连接测试',
}) => Isolate.run(
  () => _run(title, initialDir, fileName, defaultExt, filter, windowTitle),
);

String? _run(
  String title,
  String initialDir,
  String fileName,
  String defaultExt,
  List<(String, String)> filter,
  String windowTitle,
) {
  final ole = DynamicLibrary.open('ole32.dll');
  final coInit = ole
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)
      >('CoInitializeEx');
  final coUninit = ole.lookupFunction<Void Function(), void Function()>(
    'CoUninitialize',
  );
  final user32 = DynamicLibrary.open('user32.dll');
  final findWindow = user32
      .lookupFunction<
        Pointer<Void> Function(Pointer<Utf16>, Pointer<Utf16>),
        Pointer<Void> Function(Pointer<Utf16>, Pointer<Utf16>)
      >('FindWindowW');
  final getSave = DynamicLibrary.open('comdlg32.dll')
      .lookupFunction<
        Int32 Function(Pointer<_OpenFileNameW>),
        int Function(Pointer<_OpenFileNameW>)
      >('GetSaveFileNameW');

  coInit(
    nullptr,
    0x2,
  ); // COINIT_APARTMENTTHREADED, required by the common dialogs
  final arena = Arena();
  try {
    final wt = windowTitle.toNativeUtf16(allocator: arena);
    // filter: "label\0pattern\0...\0\0"
    final f = filter.map((e) => '${e.$1}\u0000${e.$2}\u0000').join();
    final filterPtr = '$f\u0000'.toNativeUtf16(allocator: arena);
    final file = arena<Uint16>(_maxPath);
    final name = fileName.codeUnits.take(_maxPath - 1).toList();
    for (var i = 0; i < name.length; i++) {
      file[i] = name[i];
    }
    final ofn = arena<_OpenFileNameW>();
    ofn.ref
      ..lStructSize = sizeOf<_OpenFileNameW>()
      ..hwndOwner = findWindow(nullptr, wt)
      ..lpstrFilter = filterPtr
      ..nFilterIndex = 1
      ..lpstrFile = file.cast()
      ..nMaxFile = _maxPath
      ..lpstrInitialDir = initialDir.toNativeUtf16(allocator: arena)
      ..lpstrTitle = title.toNativeUtf16(allocator: arena)
      ..lpstrDefExt = defaultExt.toNativeUtf16(allocator: arena)
      ..flags =
          _ofnOverwritePrompt |
          _ofnHideReadOnly |
          _ofnNoChangeDir |
          _ofnPathMustExist;
    if (getSave(ofn) == 0) {
      return null; // cancelled (or an error; both mean "do not save")
    }
    return file.cast<Utf16>().toDartString();
  } finally {
    arena.releaseAll();
    coUninit();
  }
}
