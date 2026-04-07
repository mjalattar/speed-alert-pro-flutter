import 'package:flutter/material.dart';

import '../core/constants.dart';

ThemeData buildAppTheme({required Brightness brightness}) {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.indigo,
      brightness: brightness,
    ),
    useMaterial3: true,
  );
}

ThemeMode themeModeForPrefs(int uiThemeMode) {
  switch (uiThemeMode) {
    case AppThemeMode.light:
      return ThemeMode.light;
    case AppThemeMode.dark:
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
}
