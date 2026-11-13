// Visual style. Windows desktop gets its own look (YaHei UI text, Cascadia/Consolas logs, cards on a light
// background); Android keeps the stock Material look it had before.
import 'dart:io';

import 'package:flutter/material.dart';

final bool kWin = Platform.isWindows;

const kSeed = Color(0xFF3F51B5);
const kBg = Color(0xFFF2F4F8); // window background behind the cards
const kCardBorder = Color(0xFFE2E6EE);
const kMuted = Color(0xFF667085); // secondary text
const kLogBg = Color(0xFF1B1F27);
const kLogBar = Color(0xFF242A35);

/// Monospace for logs, payloads and hex. Windows: Cascadia Mono / Consolas, YaHei for any CJK in the text.
TextStyle mono({double size = 12, Color? color, double? height}) => TextStyle(
  fontFamily: kWin ? 'Cascadia Mono' : 'monospace',
  fontFamilyFallback: kWin
      ? const ['Cascadia Code', 'Consolas', 'Microsoft YaHei UI']
      : null,
  fontSize: size,
  color: color,
  height: height,
);

ThemeData appTheme() {
  if (!kWin) {
    return ThemeData(
      colorSchemeSeed: Colors.indigo,
      visualDensity: VisualDensity.compact,
    );
  }
  final scheme = ColorScheme.fromSeed(seedColor: kSeed, surface: Colors.white);
  final radius = BorderRadius.circular(8);
  OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
    borderRadius: radius,
    borderSide: BorderSide(color: c, width: w),
  );
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.compact,
    fontFamily: 'Microsoft YaHei UI',
    scaffoldBackgroundColor: kBg,
    dividerTheme: const DividerThemeData(
      color: kCardBorder,
      space: 1,
      thickness: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: border(const Color(0xFFD0D5DD)),
      enabledBorder: border(const Color(0xFFD0D5DD)),
      focusedBorder: border(scheme.primary, 1.6),
      labelStyle: const TextStyle(color: kMuted, fontSize: 13),
      floatingLabelStyle: TextStyle(color: scheme.primary, fontSize: 13),
      hintStyle: const TextStyle(color: Color(0xFF98A2B3), fontSize: 13),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: radius),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: radius),
        side: const BorderSide(color: Color(0xFFD0D5DD)),
        backgroundColor: Colors.white,
        textStyle: const TextStyle(fontSize: 13.5),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: radius),
        textStyle: const TextStyle(fontSize: 13.5),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.white,
      indicatorColor: scheme.primaryContainer,
      selectedIconTheme: IconThemeData(color: scheme.primary),
      unselectedIconTheme: const IconThemeData(color: kMuted),
      selectedLabelTextStyle: TextStyle(
        color: scheme.primary,
        fontWeight: FontWeight.w600,
        fontSize: 12.5,
      ),
      unselectedLabelTextStyle: const TextStyle(color: kMuted, fontSize: 12.5),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: radius),
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 400),
    ),
  );
  // Segoe UI for Latin letters and digits, YaHei for Chinese
  return base.copyWith(
    textTheme: base.textTheme.apply(
      fontFamilyFallback: const ['Segoe UI', 'Microsoft YaHei'],
    ),
  );
}

/// White rounded card used for groups of options on the Windows layout.
BoxDecoration cardDecoration() => BoxDecoration(
  color: Colors.white,
  borderRadius: BorderRadius.circular(10),
  border: Border.all(color: kCardBorder),
  boxShadow: const [
    BoxShadow(color: Color(0x0A101828), blurRadius: 6, offset: Offset(0, 1)),
  ],
);
