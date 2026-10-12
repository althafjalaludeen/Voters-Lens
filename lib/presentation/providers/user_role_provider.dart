import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/auth/pin_authenticator.dart';
import '../../core/constants/field_status.dart';
import 'database_provider.dart';

final pinAuthenticatorProvider = Provider<PinAuthenticator>((ref) {
  final db = ref.watch(databaseProvider);
  return PinAuthenticator(db);
});

final userRoleProvider = StateProvider<UserRole>((ref) => UserRole.admin);

final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

