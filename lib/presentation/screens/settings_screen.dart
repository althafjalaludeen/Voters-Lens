import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/pin_authenticator.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/field_status.dart';
import '../providers/database_provider.dart';
import '../providers/roll_providers.dart';
import '../providers/user_role_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeRoll = ref.watch(activeRollProvider);
    final db = ref.watch(databaseProvider);
    final currentRole = ref.watch(userRoleProvider);
    final themeMode = ref.watch(themeModeProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings & Configuration', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // 1. Active Roll Information Card
          _buildCard(
            isDark: isDark,
            title: 'Active Electoral Roll',
            children: [
              _buildRow('Constituency', activeRoll?.assemblyConstituency ?? '111 - Thiruvalla', isDark),
              _buildRow('District / State', '${activeRoll?.district ?? "Pathanamthitta"}, ${activeRoll?.state ?? "Kerala"}', isDark),
              _buildRow('Roll Name', activeRoll?.rollName ?? 'Final Electoral Roll 2026', isDark),
              _buildRow('Record Count', '${activeRoll?.recordCount ?? 524} statutory records', isDark),
              _buildRow('Status', activeRoll?.status ?? 'ACTIVE (LOCKED)', isDark, highlight: true),
            ],
          ),
          const SizedBox(height: 16),

          // 2. Database & Storage Card
          _buildCard(
            isDark: isDark,
            title: 'Local Database Diagnostics',
            children: [
              _buildRow('Database File', db.path, isDark),
              _buildRow('Storage Mode', 'SQLite WAL (Write-Ahead Logging)', isDark),
              _buildRow('Network Connectivity', 'Strictly Zero (100% Offline)', isDark, highlight: true),
              _buildRow('Immutability Lock', 'Official Records Read-Only', isDark),
            ],
          ),
          const SizedBox(height: 16),

          // 3. Operator Role (RBAC Switcher)
          _buildCard(
            isDark: isDark,
            title: 'Active Operator Role (RBAC)',
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Switch roles below to verify service-layer permission boundaries:',
                  style: TextStyle(fontSize: 12, color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight),
                ),
              ),
              ...UserRole.values.map((r) {
                final isSelected = currentRole == r;
                return InkWell(
                  onTap: () => _handleRoleSelection(context, ref, r, currentRole),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                    child: Row(
                      children: [
                        Icon(
                          r.icon,
                          size: 20,
                          color: isSelected ? AppColors.primary : (isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                r.title,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                                  color: isSelected ? AppColors.primary : (isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _getRoleCapabilities(r),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: isDark ? AppColors.textTertiaryDark : AppColors.textSecondaryLight,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (isSelected)
                          const Icon(CupertinoIcons.checkmark_alt, size: 18, color: AppColors.primary),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
          const SizedBox(height: 16),

          // 4. Appearance (Light / Dark / System)
          _buildCard(
            isDark: isDark,
            title: 'Theme & Appearance',
            children: [
              Row(
                children: [
                  Expanded(
                    child: _buildThemeButton(
                      title: 'System',
                      icon: CupertinoIcons.circle_lefthalf_fill,
                      selected: themeMode == ThemeMode.system,
                      onTap: () => ref.read(themeModeProvider.notifier).state = ThemeMode.system,
                      isDark: isDark,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildThemeButton(
                      title: 'Light',
                      icon: CupertinoIcons.sun_max_fill,
                      selected: themeMode == ThemeMode.light,
                      onTap: () => ref.read(themeModeProvider.notifier).state = ThemeMode.light,
                      isDark: isDark,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildThemeButton(
                      title: 'Dark',
                      icon: CupertinoIcons.moon_fill,
                      selected: themeMode == ThemeMode.dark,
                      onTap: () => ref.read(themeModeProvider.notifier).state = ThemeMode.dark,
                      isDark: isDark,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 5. Data Privacy & Ethical Governance
          _buildCard(
            isDark: isDark,
            title: 'Privacy & Statutory Integrity',
            children: [
              const Text(
                '• Offline First: Normal operation never transmits voter data over the network.\n'
                '• Statutory Separation: Local field notes and statuses do not alter official electoral records.\n'
                '• Strict Non-Inference: Religion, caste, or political affiliations are strictly never inferred from names or localities.\n'
                '• Audit Trails: All field observations are recorded chronologically in local append-only history.',
                style: TextStyle(fontSize: 12, height: 1.5),
              ),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  String _getRoleCapabilities(UserRole r) {
    switch (r) {
      case UserRole.admin:
        return 'Full access: manage rolls, activate rolls, review queue, field observations.';
      case UserRole.manager:
        return 'Supervisory: review queue sign-off, field observations, audit history.';
      case UserRole.fieldUser:
        return 'Operational: search voters, submit verified field observations & notes.';
      case UserRole.viewer:
        return 'Read-only: search and view voter cards and profiles.';
    }
  }

  Widget _buildCard({
    required bool isDark,
    required String title,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isDark ? AppColors.borderDark : AppColors.borderLight, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          const Divider(),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  Widget _buildRow(String label, String value, bool isDark, {bool highlight = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: highlight ? AppColors.primary : (isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThemeButton({
    required String title,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
    required bool isDark,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.14)
              : (isDark ? AppColors.surfaceElevatedDark : AppColors.surfaceElevatedLight),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.primary : (isDark ? AppColors.borderDark : AppColors.borderLight),
            width: selected ? 1.2 : 0.8,
          ),
        ),
        child: Column(
          children: [
            Icon(icon, size: 18, color: selected ? AppColors.primary : null),
            const SizedBox(height: 4),
            Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? AppColors.primary : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleRoleSelection(
    BuildContext context,
    WidgetRef ref,
    UserRole targetRole,
    UserRole currentRole,
  ) async {
    if (targetRole == currentRole) return;

    // De-escalation to Field User or Viewer does not require authentication
    if (targetRole == UserRole.viewer || targetRole == UserRole.fieldUser) {
      ref.read(userRoleProvider.notifier).state = targetRole;
      final db = ref.read(databaseProvider);
      db.logAudit(
        action: 'ROLE_DEELEVATED',
        entityType: 'UserRole',
        entityId: targetRole.name,
        performedBy: currentRole.name,
        details: 'Switched from ${currentRole.title} to ${targetRole.title}',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Switched to ${targetRole.title}.')),
      );
      return;
    }

    // Role escalation to Manager or Admin requires authentication
    final pinAuth = ref.read(pinAuthenticatorProvider);
    final isPinSet = pinAuth.isSupervisorPinEstablished();

    if (!isPinSet) {
      // First-time setup
      final pin = await _showSetupPinDialog(context);
      if (pin == null || pin.isEmpty) return;
      try {
        await pinAuth.setupSupervisorPin(pin, performedBy: currentRole.name);
        ref.read(userRoleProvider.notifier).state = targetRole;
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Supervisor passcode configured. Elevated to ${targetRole.title}.'),
              backgroundColor: const Color(0xFF10B981),
            ),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Passcode setup failed: $e')),
          );
        }
      }
    } else {
      // Challenge
      final pin = await _showChallengePinDialog(context, targetRole);
      if (pin == null || pin.isEmpty) return;
      try {
        final verified = await pinAuth.verifySupervisorPin(pin, performedBy: currentRole.name);
        if (verified) {
          ref.read(userRoleProvider.notifier).state = targetRole;
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Passcode verified. Elevated to ${targetRole.title}.'),
                backgroundColor: const Color(0xFF10B981),
              ),
            );
          }
        } else {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Incorrect passcode.')),
            );
          }
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$e')),
          );
        }
      }
    }
  }

  Future<String?> _showSetupPinDialog(BuildContext context) async {
    final pinCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    String? errorMsg;

    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Setup Supervisor Passcode', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Administrative roles require a secure supervisor passcode (minimum 6 digits).',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: pinCtrl,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Passcode (6+ digits)',
                      prefixIcon: Icon(CupertinoIcons.lock),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: confirmCtrl,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Confirm Passcode',
                      prefixIcon: Icon(CupertinoIcons.lock_shield),
                    ),
                  ),
                  if (errorMsg != null) ...[
                    const SizedBox(height: 10),
                    Text(errorMsg!, style: const TextStyle(color: Colors.red, fontSize: 12)),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, null),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final p1 = pinCtrl.text.trim();
                    final p2 = confirmCtrl.text.trim();
                    if (p1.length < 6) {
                      setState(() => errorMsg = 'Passcode must be at least 6 digits.');
                      return;
                    }
                    if (p1 != p2) {
                      setState(() => errorMsg = 'Passcodes do not match.');
                      return;
                    }
                    try {
                      PinAuthenticator.validatePinPolicy(p1);
                    } catch (e) {
                      setState(() => errorMsg = e.toString());
                      return;
                    }
                    Navigator.pop(ctx, p1);
                  },
                  child: const Text('Save & Elevate'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<String?> _showChallengePinDialog(BuildContext context, UserRole targetRole) async {
    final pinCtrl = TextEditingController();

    return showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('Elevate to ${targetRole.title}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Enter the supervisor passcode to access ${targetRole.title} permissions.',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: pinCtrl,
                obscureText: true,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Supervisor Passcode',
                  prefixIcon: Icon(CupertinoIcons.lock),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx, pinCtrl.text.trim());
              },
              child: const Text('Authenticate'),
            ),
          ],
        );
      },
    );
  }
}
