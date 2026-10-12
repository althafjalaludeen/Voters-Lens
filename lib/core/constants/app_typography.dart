import 'package:flutter/material.dart';
import 'app_colors.dart';

class AppTypography {
  // System typography with Malayalam fallbacks
  static const List<String> fontFallbacks = [
    'SF Pro Text',
    'SF Pro Display',
    'Roboto',
    'Nirmala UI',
    'Kartika',
    'Manjari',
    'Arial Unicode MS',
    'sans-serif',
  ];

  static TextStyle titleLarge(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.4,
      fontFamilyFallback: fontFallbacks,
      color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
    );
  }

  static TextStyle titleMedium(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return TextStyle(
      fontSize: 17,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
      fontFamilyFallback: fontFallbacks,
      color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
    );
  }

  static TextStyle bodyMedium(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      fontFamilyFallback: fontFallbacks,
      color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
    );
  }

  static TextStyle bodySmall(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w400,
      fontFamilyFallback: fontFallbacks,
      color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
    );
  }

  static TextStyle labelBold(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.3,
      fontFamilyFallback: fontFallbacks,
      color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
    );
  }
}
