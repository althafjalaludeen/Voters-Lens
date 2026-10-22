import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/theme/app_theme.dart';

enum DatabaseStartupErrorType {
  migrationRequired,
  keyNotFound,
  decryptionFailed,
  corrupted,
  other,
}

class DatabaseStartupError {
  final DatabaseStartupErrorType type;
  final String title;
  final String message;
  final String? recoveryHint;

  const DatabaseStartupError({
    required this.type,
    required this.title,
    required this.message,
    this.recoveryHint,
  });
}

/// Fallback application mounted when secure database initialization fails.
///
/// Prevents the application from entering database-dependent screens
/// and safely informs the operator without exposing sensitive keys or stack traces.
class DatabaseStartupErrorApp extends StatelessWidget {
  final DatabaseStartupError error;

  const DatabaseStartupErrorApp({
    super.key,
    required this.error,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VoterLens — Security Alert',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      debugShowCheckedModeBanner: false,
      home: DatabaseStartupErrorScreen(error: error),
    );
  }
}

class DatabaseStartupErrorScreen extends StatelessWidget {
  final DatabaseStartupError error;

  const DatabaseStartupErrorScreen({
    super.key,
    required this.error,
  });

  IconData _getIcon() {
    switch (error.type) {
      case DatabaseStartupErrorType.migrationRequired:
        return Icons.lock_clock_outlined;
      case DatabaseStartupErrorType.keyNotFound:
        return Icons.key_off_outlined;
      case DatabaseStartupErrorType.decryptionFailed:
        return Icons.gpp_bad_outlined;
      case DatabaseStartupErrorType.corrupted:
        return Icons.broken_image_outlined;
      case DatabaseStartupErrorType.other:
        return Icons.error_outline;
    }
  }

  Color _getIconColor() {
    switch (error.type) {
      case DatabaseStartupErrorType.migrationRequired:
        return AppColors.statusAway;
      case DatabaseStartupErrorType.keyNotFound:
      case DatabaseStartupErrorType.decryptionFailed:
      case DatabaseStartupErrorType.corrupted:
      case DatabaseStartupErrorType.other:
        return AppColors.statusDeceased;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Security & Storage Guard'),
        centerTitle: true,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: _getIconColor().withAlpha(25),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _getIcon(),
                    size: 64,
                    color: _getIconColor(),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  error.title,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  error.message,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.grey[700],
                        height: 1.5,
                      ),
                  textAlign: TextAlign.center,
                ),
                if (error.recoveryHint != null) ...[
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey[300]!),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.info_outline,
                          size: 20,
                          color: AppColors.primary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            error.recoveryHint!,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Colors.grey[800],
                                  height: 1.4,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
