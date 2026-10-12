import 'package:flutter/material.dart';

/// Semantic design colors for VoterLens adhering to iOS-inspired utility aesthetics.
class AppColors {
  // Neutral foundations - Light
  static const Color backgroundLight = Color(0xFFF8FAFC);
  static const Color surfaceLight = Color(0xFFFFFFFF);
  static const Color surfaceElevatedLight = Color(0xFFF1F5F9);
  static const Color borderLight = Color(0xFFE2E8F0);
  static const Color dividerLight = Color(0xFFCBD5E1);

  // Neutral foundations - Dark
  static const Color backgroundDark = Color(0xFF090D16);
  static const Color surfaceDark = Color(0xFF111827);
  static const Color surfaceElevatedDark = Color(0xFF1E293B);
  static const Color borderDark = Color(0xFF1F293D);
  static const Color dividerDark = Color(0xFF334155);

  // Brand Accents
  static const Color primary = Color(0xFF2563EB); // Vibrant Royal Cobalt
  static const Color primaryDark = Color(0xFF1D4ED8);
  static const Color primaryLight = Color(0xFF60A5FA);

  static const Color textPrimaryLight = Color(0xFF0F172A);
  static const Color textSecondaryLight = Color(0xFF64748B);
  static const Color textTertiaryLight = Color(0xFF94A3B8);

  static const Color textPrimaryDark = Color(0xFFF8FAFC);
  static const Color textSecondaryDark = Color(0xFF94A3B8);
  static const Color textTertiaryDark = Color(0xFF64748B);

  // Field Status Semantic Colors (Section 6)
  static const Color statusNoIssue = Color(0xFF10B981); // Emerald Green
  static const Color statusAway = Color(0xFFF59E0B); // Amber Yellow
  static const Color statusAbroad = Color(0xFF3B82F6); // Royal Blue
  static const Color statusDeceased = Color(0xFFEF4444); // Crimson Red
  static const Color statusUnableToVerify = Color(0xFFF97316); // Warm Orange

  // Review Status Colors
  static const Color reviewNeedsReview = Color(0xFFE11D48); // Rose
  static const Color reviewReviewed = Color(0xFF0D9488); // Teal
  static const Color reviewNotReviewed = Color(0xFF64748B); // Slate

  // Status background tints (Light)
  static Color statusNoIssueBg = const Color(0xFF10B981).withValues(alpha: 0.12);
  static Color statusAwayBg = const Color(0xFFF59E0B).withValues(alpha: 0.12);
  static Color statusAbroadBg = const Color(0xFF3B82F6).withValues(alpha: 0.12);
  static Color statusDeceasedBg = const Color(0xFFEF4444).withValues(alpha: 0.12);
  static Color statusUnableToVerifyBg = const Color(0xFFF97316).withValues(alpha: 0.12);
}
