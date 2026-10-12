import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app.dart';
import 'core/database/app_database.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final docsDir = await getApplicationDocumentsDirectory();
    AppDatabase.setDefaultDirectory(docsDir.path);
  } catch (_) {
    // Non-fatal fallback for CLI or unsupported platform environments
  }

  runApp(
    const ProviderScope(
      child: VoterLensApp(),
    ),
  );
}
