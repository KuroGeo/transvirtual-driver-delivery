import 'package:flutter/material.dart';

abstract final class OceanColors {
  static const orange = Color(0xFFFF6B38);
  static const ink = Color(0xFF302B26);
  static const cream = Color(0xFFFFFCF7);
  static const muted = Color(0xFF756E65);
  static const border = Color(0xFFE8E1D7);
  static const green = Color(0xFF187657);
  static const red = Color(0xFFB84B42);
}

ThemeData oceanTheme() => ThemeData(
  useMaterial3: true,
  fontFamily: 'Inter',
  colorScheme: ColorScheme.fromSeed(
    seedColor: OceanColors.orange,
    primary: OceanColors.orange,
    onPrimary: OceanColors.ink,
    surface: OceanColors.cream,
    onSurface: OceanColors.ink,
    error: OceanColors.red,
  ),
  scaffoldBackgroundColor: OceanColors.cream,
  appBarTheme: const AppBarTheme(
    backgroundColor: OceanColors.cream,
    foregroundColor: OceanColors.ink,
    surfaceTintColor: Colors.transparent,
  ),
  dividerColor: OceanColors.border,
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: OceanColors.border),
    ),
  ),
);
