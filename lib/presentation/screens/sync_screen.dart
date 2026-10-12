import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/constants/app_colors.dart';
import '../../core/constants/field_status.dart';
import '../../domain/entities/sync_models.dart';
import '../providers/sync_provider.dart';
import '../providers/user_role_provider.dart';
import '../providers/database_provider.dart';
import '../providers/roll_providers.dart';

// ---------------------------------------------------------------------------
// SYNC SCREEN — Phase 4B: Encrypted Local .vlsync File Exchange
// ---------------------------------------------------------------------------

class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? AppColors.backgroundDark : AppColors.backgroundLight,
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.primary, Color(0xFF7C5CBF)],
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(CupertinoIcons.arrow_2_squarepath, size: 16, color: Colors.white),
            ),
            const SizedBox(width: 10),
            const Text(
              'Sync',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20),
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          unselectedLabelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          indicatorColor: AppColors.primary,
          tabs: const [
            Tab(text: 'Overview'),
            Tab(text: 'Import'),
            Tab(text: 'Conflicts'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          _OverviewTab(),
          _ImportTab(),
          _ConflictsTab(),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 1: Overview / Export
// ---------------------------------------------------------------------------

class _OverviewTab extends ConsumerStatefulWidget {
  const _OverviewTab();

  @override
  ConsumerState<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends ConsumerState<_OverviewTab> {
  final _passphraseCtrl = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _passphraseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final stats = ref.watch(syncStatsProvider);
    final packets = ref.watch(syncPacketsProvider);
    final exportState = ref.watch(syncExportProvider);
    final role = ref.watch(userRoleProvider);

    final canExport = role == UserRole.fieldUser || role == UserRole.manager || role == UserRole.admin;
    final deviceId = (stats['device_id'] as String?) ?? '—';
    final shortDeviceId = deviceId.length > 8 ? deviceId.substring(0, 8).toUpperCase() : deviceId.toUpperCase();
    final obsCount = stats['total_observations'] as int? ?? 0;
    final conflicts = stats['pending_conflicts'] as int? ?? 0;
    final lastImport = stats['last_import_at'] as String?;
    final lastExport = stats['last_export_at'] as String?;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Device Identity Card
        _buildCard(
          isDark: isDark,
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppColors.primary, Color(0xFF7C5CBF)],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(CupertinoIcons.device_phone_portrait, color: Colors.white, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'VoterLens Field Unit',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Device ID: $shortDeviceId…',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'OFFLINE',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF10B981),
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // Stats row
        Row(
          children: [
            Expanded(child: _buildStatCard(
              isDark: isDark,
              label: 'Observations',
              value: '$obsCount',
              icon: CupertinoIcons.doc_text,
              color: AppColors.primary,
            )),
            const SizedBox(width: 8),
            Expanded(child: _buildStatCard(
              isDark: isDark,
              label: 'Conflicts',
              value: '$conflicts',
              icon: CupertinoIcons.exclamationmark_triangle,
              color: conflicts > 0 ? AppColors.reviewNeedsReview : const Color(0xFF10B981),
            )),
            const SizedBox(width: 8),
            Expanded(child: _buildStatCard(
              isDark: isDark,
              label: 'Syncs',
              value: '${packets.length}',
              icon: CupertinoIcons.arrow_2_squarepath,
              color: const Color(0xFF3B82F6),
            )),
          ],
        ),

        const SizedBox(height: 16),

        // Last sync times
        _buildCard(
          isDark: isDark,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Sync Activity',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
                ),
              ),
              const SizedBox(height: 10),
              _buildActivityRow(
                isDark: isDark,
                icon: CupertinoIcons.arrow_up_circle_fill,
                label: 'Last Export',
                value: lastExport != null ? _formatDateTime(lastExport) : 'Never',
                color: AppColors.primary,
              ),
              const SizedBox(height: 8),
              _buildActivityRow(
                isDark: isDark,
                icon: CupertinoIcons.arrow_down_circle_fill,
                label: 'Last Import',
                value: lastImport != null ? _formatDateTime(lastImport) : 'Never',
                color: const Color(0xFF10B981),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Export Section
        if (canExport) ...[
          _buildSectionHeader(isDark: isDark, title: 'Export Field Observations', icon: CupertinoIcons.arrow_up_to_line),
          const SizedBox(height: 8),
          _buildCard(
            isDark: isDark,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Creates an AES-256-GCM encrypted .vlsync file from your local field observations for transfer to another device.',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                  ),
                ),
                const SizedBox(height: 14),
                // Passphrase field
                TextField(
                  controller: _passphraseCtrl,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: 'Transfer Passphrase',
                    hintText: 'Min. 8 characters',
                    prefixIcon: const Icon(CupertinoIcons.lock, size: 18),
                    suffixIcon: IconButton(
                      icon: Icon(_obscure ? CupertinoIcons.eye : CupertinoIcons.eye_slash, size: 18),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
                const SizedBox(height: 14),

                if (exportState.status == SyncOpStatus.success && exportState.exportedFilePath != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.4)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(CupertinoIcons.checkmark_circle_fill, color: Color(0xFF10B981), size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Export Successful!', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFF10B981))),
                                  const SizedBox(height: 2),
                                  Text(
                                    exportState.exportedFilePath!.split('/').last.split('\\').last,
                                    style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(CupertinoIcons.xmark, size: 16),
                              onPressed: () => ref.read(syncExportProvider.notifier).reset(),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            icon: const Icon(CupertinoIcons.share, size: 14),
                            label: const Text('Share / Send .vlsync File', style: TextStyle(fontSize: 12)),
                            onPressed: () {
                              SharePlus.instance.share(
                                ShareParams(
                                  files: [XFile(exportState.exportedFilePath!)],
                                  text: 'VoterLens Encrypted Sync File',
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                if (exportState.status == SyncOpStatus.error && exportState.errorMessage != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.reviewNeedsReview.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.reviewNeedsReview.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      children: [
                        const Icon(CupertinoIcons.xmark_circle_fill, color: AppColors.reviewNeedsReview, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            exportState.errorMessage!,
                            style: const TextStyle(fontSize: 12, color: AppColors.reviewNeedsReview),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: exportState.status == SyncOpStatus.loading
                        ? null
                        : () => _doExport(context),
                    icon: exportState.status == SyncOpStatus.loading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(CupertinoIcons.arrow_up_doc_fill, size: 16),
                    label: Text(
                      exportState.status == SyncOpStatus.loading ? 'Encrypting…' : 'Export .vlsync File',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        if (!canExport)
          _buildCard(
            isDark: isDark,
            child: Row(
              children: [
                const Icon(CupertinoIcons.lock_shield, size: 20, color: AppColors.reviewNeedsReview),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Export requires Field User, Manager, or Admin role.',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                    ),
                  ),
                ),
              ],
            ),
          ),

        const SizedBox(height: 16),

        // Sync History
        if (packets.isNotEmpty) ...[
          _buildSectionHeader(isDark: isDark, title: 'Sync History', icon: CupertinoIcons.clock),
          const SizedBox(height: 8),
          ...packets.take(10).map((pkt) => _buildPacketTile(isDark: isDark, pkt: pkt)),
        ],

        const SizedBox(height: 32),
      ],
    );
  }

  void _doExport(BuildContext context) {
    final passphrase = _passphraseCtrl.text.trim();
    if (passphrase.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Passphrase must be at least 8 characters.')),
      );
      return;
    }
    final role = ref.read(userRoleProvider);
    final username = role.name;
    ref.read(syncExportProvider.notifier).export(
      passphrase: passphrase,
      operatorUsername: username,
    );
  }

  Widget _buildActivityRow({
    required bool isDark,
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
          ),
        ),
      ],
    );
  }

  Widget _buildPacketTile({required bool isDark, required Map<String, dynamic> pkt}) {
    final dir = (pkt['direction'] as String? ?? 'EXPORT');
    final isImport = dir == 'IMPORT';
    final count = pkt['observation_count'] as int? ?? 0;
    final status = pkt['status'] as String? ?? '';
    final ts = pkt['processed_at'] as String? ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isDark ? AppColors.borderDark : AppColors.borderLight, width: 0.5),
      ),
      child: Row(
        children: [
          Icon(
            isImport ? CupertinoIcons.arrow_down_circle_fill : CupertinoIcons.arrow_up_circle_fill,
            size: 20,
            color: isImport ? const Color(0xFF10B981) : AppColors.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${isImport ? 'Import' : 'Export'} — $count observation${count != 1 ? 's' : ''}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                if (ts.isNotEmpty)
                  Text(
                    _formatDateTime(ts),
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                    ),
                  ),
              ],
            ),
          ),
          _buildStatusChip(status),
        ],
      ),
    );
  }

  Widget _buildStatusChip(String status) {
    Color color;
    switch (status) {
      case 'COMMITTED':
      case 'CREATED':
        color = const Color(0xFF10B981);
        break;
      case 'FAILED':
        color = AppColors.reviewNeedsReview;
        break;
      default:
        color = const Color(0xFF6B7280);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        status,
        style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }

  String _formatDateTime(String isoStr) {
    try {
      final dt = DateTime.parse(isoStr).toLocal();
      return DateFormat('dd MMM yyyy HH:mm').format(dt);
    } catch (_) {
      return isoStr;
    }
  }
}

// ---------------------------------------------------------------------------
// Tab 2: Import
// ---------------------------------------------------------------------------

class _ImportTab extends ConsumerStatefulWidget {
  const _ImportTab();

  @override
  ConsumerState<_ImportTab> createState() => _ImportTabState();
}

class _ImportTabState extends ConsumerState<_ImportTab> {
  final _filePathCtrl = TextEditingController();
  final _passphraseCtrl = TextEditingController();
  bool _obscure = true;

  int _importMode = 0; // 0 = Field Delta Sync, 1 = Gazette Snapshot
  final _gazetteFilePathCtrl = TextEditingController();
  final _gazettePassphraseCtrl = TextEditingController();
  bool _gazetteObscure = true;
  bool _allowReplaceActive = false;

  @override
  void initState() {
    super.initState();
    final activeRoll = ref.read(activeRollProvider);
    if (activeRoll == null) {
      _importMode = 1;
    }
  }

  @override
  void dispose() {
    _filePathCtrl.dispose();
    _passphraseCtrl.dispose();
    _gazetteFilePathCtrl.dispose();
    _gazettePassphraseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final importState = ref.watch(syncImportProvider);
    final gazetteState = ref.watch(gazetteBootstrapProvider);
    final role = ref.watch(userRoleProvider);
    final canImport = role == UserRole.manager || role == UserRole.admin;

    if (!canImport) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(CupertinoIcons.lock_shield, size: 48,
                color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight),
              const SizedBox(height: 16),
              Text(
                'Import requires Manager or Admin role.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () => _showEscalationDialog(context),
                icon: const Icon(CupertinoIcons.shield_lefthalf_fill, size: 16),
                label: const Text('Authenticate as Supervisor'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Mode Selector: Field Sync vs Gazette Snapshot
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 16),
          child: CupertinoSlidingSegmentedControl<int>(
            groupValue: _importMode,
            children: const {
              0: Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Text('Field Observations Sync', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
              1: Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Text('Gazette Roll Snapshot', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            },
            onValueChanged: (val) {
              if (val != null) {
                setState(() => _importMode = val);
              }
            },
          ),
        ),

        if (_importMode == 1) ...[
          // -----------------------------------------------------------------
          // GAZETTE SNAPSHOT BOOTSTRAP WORKFLOW
          // -----------------------------------------------------------------
          _buildGazetteStepIndicator(isDark: isDark, state: gazetteState),
          const SizedBox(height: 16),

          // Step 1: Select Gazette Snapshot .vlsync File & Passphrase
          _buildCard(
            isDark: isDark,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildStepLabel(isDark, '1', 'Select Gazette Snapshot & Passphrase'),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _gazetteFilePathCtrl,
                        decoration: InputDecoration(
                          labelText: 'Gazette Snapshot (.vlsync)',
                          hintText: 'Select statutory snapshot container',
                          prefixIcon: const Icon(CupertinoIcons.doc_text, size: 18),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton.icon(
                      onPressed: _pickGazetteFile,
                      icon: const Icon(CupertinoIcons.folder_open, size: 16),
                      label: const Text('Browse'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _gazettePassphraseCtrl,
                  obscureText: _gazetteObscure,
                  decoration: InputDecoration(
                    labelText: 'Transfer Passphrase',
                    prefixIcon: const Icon(CupertinoIcons.lock, size: 18),
                    suffixIcon: IconButton(
                      icon: Icon(_gazetteObscure ? CupertinoIcons.eye : CupertinoIcons.eye_slash, size: 18),
                      onPressed: () => setState(() => _gazetteObscure = !_gazetteObscure),
                    ),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: gazetteState.status == SyncOpStatus.loading
                        ? null
                        : () => _doGazettePreview(context),
                    icon: gazetteState.status == SyncOpStatus.loading && gazetteState.preview == null
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(CupertinoIcons.eye, size: 16),
                    label: const Text('Validate & Preview Snapshot'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF3B82F6),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Error box
          if (gazetteState.status == SyncOpStatus.error && gazetteState.errorMessage != null) ...[
            const SizedBox(height: 12),
            _buildErrorBox(isDark, gazetteState.errorMessage!),
          ],

          // Step 2: Manifest Preview & Active Roll Protection
          if (gazetteState.preview != null) ...[
            const SizedBox(height: 16),
            _buildCard(
              isDark: isDark,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildStepLabel(isDark, '2', 'Statutory Manifest & Validation Preview'),
                  const SizedBox(height: 14),
                  _buildGazetteManifestSummary(isDark, gazetteState.preview!),
                  const SizedBox(height: 14),

                  if (gazetteState.preview!.isReplacingExistingRoll) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.5)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(CupertinoIcons.exclamationmark_triangle_fill, color: Color(0xFFF59E0B), size: 18),
                              const SizedBox(width: 8),
                              const Text('Existing Active Roll Protection', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFFF59E0B))),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'An active roll "${gazetteState.preview!.existingActiveRollName}" is currently installed on this unit. '
                            'Bootstrapping this snapshot will mark the current roll as SUPERSEDED. '
                            'Existing field observations and audit logs will remain preserved.',
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Checkbox(
                                value: _allowReplaceActive,
                                onChanged: (val) {
                                  setState(() {
                                    _allowReplaceActive = val ?? false;
                                  });
                                },
                              ),
                              const Expanded(
                                child: Text(
                                  'Authorize replacement of active roll',
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],

                  if (gazetteState.preview!.rejectionReason != null &&
                      !gazetteState.preview!.isReplacingExistingRoll) ...[
                    _buildRejectionBox(isDark, gazetteState.preview!.rejectionReason!),
                    const SizedBox(height: 14),
                  ],

                  if (gazetteState.installResult == null)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: (gazetteState.status == SyncOpStatus.loading ||
                                (!gazetteState.preview!.isSafeToInstall &&
                                    (!gazetteState.preview!.isReplacingExistingRoll || !_allowReplaceActive)))
                            ? null
                            : () => _doGazetteInstall(),
                        icon: gazetteState.status == SyncOpStatus.loading
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(CupertinoIcons.checkmark_circle_fill, size: 16),
                        label: Text(
                          gazetteState.preview!.isReplacingExistingRoll
                              ? 'Authorize & Install Roll'
                              : 'Bootstrap Statutory Roll',
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],

          // Step 3: Install Result
          if (gazetteState.installResult != null) ...[
            const SizedBox(height: 16),
            _buildCard(
              isDark: isDark,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildStepLabel(isDark, '3', 'Roll Bootstrapped & Activated'),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(CupertinoIcons.checkmark_circle_fill, color: Color(0xFF10B981), size: 24),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${gazetteState.installResult!['voters_installed']} voters installed and verified',
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF10B981)),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Roll "${gazetteState.installResult!['roll_name']}" is now active.',
                              style: TextStyle(
                                fontSize: 11,
                                color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  TextButton.icon(
                    onPressed: () => ref.read(gazetteBootstrapProvider.notifier).reset(),
                    icon: const Icon(CupertinoIcons.refresh, size: 16),
                    label: const Text('Reset / Install Another Snapshot'),
                  ),
                ],
              ),
            ),
          ],
        ] else ...[
          _buildStepIndicator(isDark: isDark, importState: importState),
          const SizedBox(height: 16),

          _buildCard(
          isDark: isDark,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildStepLabel(isDark, '1', 'Select .vlsync File & Passphrase'),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _filePathCtrl,
                      decoration: InputDecoration(
                        labelText: '.vlsync File Path',
                        hintText: 'Select or paste .vlsync file path',
                        prefixIcon: const Icon(CupertinoIcons.doc, size: 18),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _pickVlsyncFile,
                    icon: const Icon(CupertinoIcons.folder_open, size: 16),
                    label: const Text('Browse'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passphraseCtrl,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Transfer Passphrase',
                  prefixIcon: const Icon(CupertinoIcons.lock, size: 18),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? CupertinoIcons.eye : CupertinoIcons.eye_slash, size: 18),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: importState.status == SyncOpStatus.loading
                      ? null
                      : () => _doPreview(context),
                  icon: importState.status == SyncOpStatus.loading && importState.preview == null
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(CupertinoIcons.eye, size: 16),
                  label: const Text('Preview Import'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF3B82F6),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
        ),

        // Error
        if (importState.status == SyncOpStatus.error && importState.errorMessage != null) ...[
          const SizedBox(height: 12),
          _buildErrorBox(isDark, importState.errorMessage!),
        ],

        // Step 2: Preview
        if (importState.preview != null) ...[
          const SizedBox(height: 16),
          _buildCard(
            isDark: isDark,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildStepLabel(isDark, '2', 'Preview — Verify Before Committing'),
                const SizedBox(height: 14),
                _buildPreviewSummary(isDark, importState.preview),
                const SizedBox(height: 14),
                if (importState.preview.canCommit == true &&
                    importState.commitResult == null)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: importState.status == SyncOpStatus.loading
                          ? null
                          : () => _doCommit(),
                      icon: importState.status == SyncOpStatus.loading
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(CupertinoIcons.checkmark_circle_fill, size: 16),
                      label: const Text('Commit Import'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF10B981),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                if (importState.preview.canCommit == false)
                  _buildRejectionBox(isDark, importState.preview.rejectionReason ?? 'Cannot commit this file.'),
              ],
            ),
          ),
          // Preview records
          if ((importState.preview.records as List).isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildPreviewRecords(isDark, importState.preview.records as List),
          ],
        ],

        // Step 3: Commit result
        if (importState.commitResult != null) ...[
          const SizedBox(height: 16),
          _buildCard(
            isDark: isDark,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildStepLabel(isDark, '3', 'Import Committed Successfully'),
                const SizedBox(height: 12),
                _buildCommitResult(isDark, importState.commitResult!),
                const SizedBox(height: 14),
                TextButton.icon(
                  onPressed: () => ref.read(syncImportProvider.notifier).reset(),
                  icon: const Icon(CupertinoIcons.refresh, size: 16),
                  label: const Text('Start New Import'),
                ),
              ],
            ),
          ),
        ],
      ],

        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildStepIndicator({required bool isDark, required SyncImportState importState}) {
    final step = importState.preview == null ? 1 : (importState.commitResult == null ? 2 : 3);
    return Row(
      children: [
        _stepDot(1, step, isDark),
        _stepLine(isDark),
        _stepDot(2, step, isDark),
        _stepLine(isDark),
        _stepDot(3, step, isDark),
      ],
    );
  }

  Widget _stepDot(int stepNum, int current, bool isDark) {
    final active = stepNum <= current;
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? AppColors.primary : (isDark ? AppColors.borderDark : AppColors.borderLight),
      ),
      child: Center(
        child: Text(
          '$stepNum',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: active ? Colors.white : (isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight),
          ),
        ),
      ),
    );
  }

  Widget _stepLine(bool isDark) => Expanded(
    child: Container(
      height: 2,
      color: isDark ? AppColors.borderDark : AppColors.borderLight,
    ),
  );

  void _doPreview(BuildContext context) {
    final filePath = _filePathCtrl.text.trim();
    final passphrase = _passphraseCtrl.text.trim();
    if (filePath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter the .vlsync file path.')));
      return;
    }
    if (passphrase.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter the transfer passphrase.')));
      return;
    }
    ref.read(syncImportProvider.notifier).preview(
      filePath: filePath,
      passphrase: passphrase,
    );
  }

  void _doCommit() {
    final role = ref.read(userRoleProvider);
    ref.read(syncImportProvider.notifier).commit(operatorUsername: role.name);
  }

  Widget _buildPreviewSummary(bool isDark, dynamic preview) {
    final items = [
      ('Total Records', '${preview.totalRecords}', const Color(0xFF6B7280)),
      ('New (Safe to Import)', '${preview.newRecords}', const Color(0xFF10B981)),
      ('Conflicts (Concurrent)', '${preview.concurrentConflicts}', AppColors.reviewNeedsReview),
      ('Stale', '${preview.staleRecords}', const Color(0xFFF59E0B)),
      ('Voter Not Found', '${preview.voterNotFoundRecords}', const Color(0xFFEF4444)),
      ('Duplicate', '${preview.duplicateRecords}', const Color(0xFF6B7280)),
    ];

    return Column(
      children: items.map((item) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(shape: BoxShape.circle, color: item.$3),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.$1,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                  ),
                ),
              ),
              Text(
                item.$2,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: item.$3,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildPreviewRecords(bool isDark, List records) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Preview Records (${records.length})',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
        ),
        const SizedBox(height: 8),
        ...records.take(20).map((r) => _buildPreviewRecord(isDark, r)),
        if (records.length > 20)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '…and ${records.length - 20} more records',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPreviewRecord(bool isDark, dynamic r) {
    final classification = r.classification as String;
    Color classColor;
    switch (classification) {
      case 'NEW':
        classColor = const Color(0xFF10B981);
        break;
      case 'CONCURRENT':
        classColor = AppColors.reviewNeedsReview;
        break;
      case 'STALE':
        classColor = const Color(0xFFF59E0B);
        break;
      case 'VOTER_NOT_FOUND':
        classColor = const Color(0xFFEF4444);
        break;
      default:
        classColor = const Color(0xFF6B7280);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isDark ? AppColors.borderDark : AppColors.borderLight, width: 0.5),
      ),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 40,
            decoration: BoxDecoration(
              color: classColor,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      r.voterEpic as String,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(width: 6),
                    if (r.voterName != null)
                      Text(
                        r.voterName as String,
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  r.message as String,
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: classColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              classification,
              style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: classColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRejectionBox(bool isDark, String reason) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFEF4444).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(CupertinoIcons.xmark_circle_fill, color: Color(0xFFEF4444), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(reason, style: const TextStyle(fontSize: 12, color: Color(0xFFEF4444))),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBox(bool isDark, String error) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.reviewNeedsReview.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.reviewNeedsReview.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(CupertinoIcons.exclamationmark_triangle_fill, color: AppColors.reviewNeedsReview, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(error, style: const TextStyle(fontSize: 12, color: AppColors.reviewNeedsReview)),
          ),
        ],
      ),
    );
  }

  Widget _buildCommitResult(bool isDark, Map<String, dynamic> result) {
    return Row(
      children: [
        const Icon(CupertinoIcons.checkmark_circle_fill, color: Color(0xFF10B981), size: 24),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${result['imported_count']} imported, ${result['conflict_count']} conflict(s), ${result['skipped_count']} skipped',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF10B981)),
              ),
              const SizedBox(height: 2),
              Text(
                'Observations are now in your local database.',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGazetteManifestSummary(bool isDark, GazetteSnapshotPreview preview) {
    final items = [
      ('Roll Name', preview.rollName, AppColors.primary),
      ('Constituency', preview.assemblyConstituency, const Color(0xFF3B82F6)),
      ('District & State', '${preview.district}, ${preview.state}', const Color(0xFF6B7280)),
      ('Roll Type', preview.rollType, const Color(0xFF6B7280)),
      ('Publication Date', preview.publicationDate ?? 'Not specified', const Color(0xFF6B7280)),
      ('Declared Record Count', '${preview.recordCount} voter(s)', const Color(0xFF10B981)),
      ('Container Voters', '${preview.voterRecordsInPayload} record(s)', const Color(0xFF10B981)),
      ('Checksum (SHA-256)', preview.rollChecksum, const Color(0xFF8B5CF6)),
    ];

    return Column(
      children: items.map((item) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 5),
                width: 7,
                height: 7,
                decoration: BoxDecoration(shape: BoxShape.circle, color: item.$3),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: Text(
                  item.$1,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                  ),
                ),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  item.$2,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontSize: item.$1.contains('Checksum') ? 10 : 12,
                    fontWeight: FontWeight.w700,
                    fontFamily: item.$1.contains('Checksum') ? 'monospace' : null,
                    color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildGazetteStepIndicator({required bool isDark, required GazetteBootstrapState state}) {
    final step = state.preview == null ? 1 : (state.installResult == null ? 2 : 3);
    return Row(
      children: [
        _stepDot(1, step, isDark),
        _stepLine(isDark),
        _stepDot(2, step, isDark),
        _stepLine(isDark),
        _stepDot(3, step, isDark),
      ],
    );
  }

  void _doGazettePreview(BuildContext context) {
    final filePath = _gazetteFilePathCtrl.text.trim();
    final passphrase = _gazettePassphraseCtrl.text.trim();
    if (filePath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please select or enter the Gazette Snapshot .vlsync file path.')));
      return;
    }
    if (passphrase.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter the transfer passphrase.')));
      return;
    }
    ref.read(gazetteBootstrapProvider.notifier).preview(
      filePath: filePath,
      passphrase: passphrase,
    );
  }

  void _doGazetteInstall() {
    final role = ref.read(userRoleProvider);
    ref.read(gazetteBootstrapProvider.notifier).install(
      operatorUsername: role.name,
      allowReplaceActive: _allowReplaceActive,
    );
  }

  Future<void> _pickGazetteFile() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.any);
      if (files.isNotEmpty && files.first.path != null) {
        setState(() {
          _gazetteFilePathCtrl.text = files.first.path!;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error selecting file: $e')));
      }
    }
  }

  Future<void> _pickVlsyncFile() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.any,
      );
      if (files.isNotEmpty && files.first.path != null) {
        setState(() {
          _filePathCtrl.text = files.first.path!;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error selecting file: $e')),
        );
      }
    }
  }

  Future<void> _showEscalationDialog(BuildContext context) async {
    final pinAuth = ref.read(pinAuthenticatorProvider);
    final isPinSet = pinAuth.isSupervisorPinEstablished();
    final currentRole = ref.read(userRoleProvider);

    if (!isPinSet) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No supervisor passcode configured. Please set up a passcode in Settings.')),
      );
      return;
    }

    final pinCtrl = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Supervisor Authentication', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter supervisor passcode to elevate to Manager role for importing.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: pinCtrl,
                obscureText: true,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Supervisor Passcode',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
              onPressed: () => Navigator.pop(ctx, pinCtrl.text.trim()),
              child: const Text('Unlock'),
            ),
          ],
        );
      },
    );

    if (pin == null || pin.isEmpty) return;

    try {
      final ok = await pinAuth.verifySupervisorPin(pin, performedBy: currentRole.name);
      if (ok) {
        ref.read(userRoleProvider.notifier).state = UserRole.manager;
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Elevated to Manager role. You can now import .vlsync files.'),
              backgroundColor: Color(0xFF10B981),
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

// ---------------------------------------------------------------------------
// Tab 3: Conflicts
// ---------------------------------------------------------------------------

class _ConflictsTab extends ConsumerWidget {
  const _ConflictsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final conflicts = ref.watch(pendingConflictsProvider);
    final role = ref.watch(userRoleProvider);
    final canResolve = role == UserRole.manager || role == UserRole.admin;

    if (conflicts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(CupertinoIcons.checkmark_seal, size: 48, color: const Color(0xFF10B981).withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            const Text('No pending conflicts', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              'All synchronisation conflicts have been resolved.',
              style: TextStyle(fontSize: 13, color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: conflicts.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final conflict = conflicts[index];
        return _ConflictCard(
          isDark: isDark,
          conflict: conflict,
          canResolve: canResolve,
          onResolve: (choice) => _resolveConflict(ref, context, conflict, choice),
        );
      },
    );
  }

  void _resolveConflict(
    WidgetRef ref,
    BuildContext context,
    Map<String, dynamic> conflict,
    String choice,
  ) {
    final db = ref.read(databaseProvider);
    final role = ref.read(userRoleProvider);
    try {
      db.resolveConflict(
        conflictId: conflict['id'] as String,
        choice: choice,
        resolvedBy: role.name,
      );
      // Invalidate providers so UI refreshes
      ref.invalidate(pendingConflictsProvider);
      ref.invalidate(syncStatsProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            choice == 'ACCEPT_A' ? 'Kept local status.' : 'Applied imported status.',
          ),
          backgroundColor: const Color(0xFF10B981),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to resolve: $e')),
      );
    }
  }
}

class _ConflictCard extends StatelessWidget {
  final bool isDark;
  final Map<String, dynamic> conflict;
  final bool canResolve;
  final void Function(String) onResolve;

  const _ConflictCard({
    required this.isDark,
    required this.conflict,
    required this.canResolve,
    required this.onResolve,
  });

  @override
  Widget build(BuildContext context) {
    final epic = conflict['voter_epic'] as String? ?? '—';
    final voterName = conflict['voter_name'] as String?;
    final localObsId = conflict['local_observation_id'] as String? ?? '—';
    final incomingObsId = conflict['incoming_observation_id'] as String? ?? '—';
    final createdAt = conflict['created_at'] as String? ?? '';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.reviewNeedsReview.withValues(alpha: 0.3), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              const Icon(CupertinoIcons.exclamationmark_triangle_fill, size: 16, color: AppColors.reviewNeedsReview),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$epic${voterName != null ? " — $voterName" : ""}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                'CONCURRENT',
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  color: AppColors.reviewNeedsReview,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Two-column comparison
          Row(
            children: [
              Expanded(
                child: _buildObsColumn(
                  isDark: isDark,
                  label: 'Local',
                  obsId: localObsId.length > 8 ? localObsId.substring(0, 8) : localObsId,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildObsColumn(
                  isDark: isDark,
                  label: 'Incoming',
                  obsId: incomingObsId.length > 8 ? incomingObsId.substring(0, 8) : incomingObsId,
                  color: const Color(0xFFF59E0B),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          if (createdAt.isNotEmpty)
            Text(
              'Detected: ${_fmtDate(createdAt)}',
              style: TextStyle(
                fontSize: 11,
                color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
              ),
            ),

          if (canResolve) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => onResolve('ACCEPT_A'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.primary,
                      side: const BorderSide(color: AppColors.primary),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    child: const Text('Keep Local', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => onResolve('ACCEPT_B'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFF59E0B),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    child: const Text('Accept Imported', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Manager or Admin required to resolve conflicts.',
                style: TextStyle(fontSize: 11, color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildObsColumn({
    required bool isDark,
    required String label,
    required String obsId,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: color),
          ),
          const SizedBox(height: 4),
          Text(
            'OBS: $obsId…',
            style: TextStyle(
              fontSize: 10,
              fontFamily: 'monospace',
              color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
            ),
          ),
        ],
      ),
    );
  }

  String _fmtDate(String isoStr) {
    try {
      return DateFormat('dd MMM yyyy HH:mm').format(DateTime.parse(isoStr).toLocal());
    } catch (_) {
      return isoStr;
    }
  }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

Widget _buildCard({required bool isDark, required Widget child}) {
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: isDark ? AppColors.borderDark : AppColors.borderLight, width: 0.8),
    ),
    child: child,
  );
}

Widget _buildStatCard({
  required bool isDark,
  required String label,
  required String value,
  required IconData icon,
  required Color color,
}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
    decoration: BoxDecoration(
      color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: isDark ? AppColors.borderDark : AppColors.borderLight, width: 0.8),
    ),
    child: Column(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(height: 6),
        Text(
          value,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 9,
            color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
          ),
        ),
      ],
    ),
  );
}

Widget _buildSectionHeader({required bool isDark, required String title, required IconData icon}) {
  return Row(
    children: [
      Icon(icon, size: 14, color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight),
      const SizedBox(width: 6),
      Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
          color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
        ),
      ),
    ],
  );
}

Widget _buildStepLabel(bool isDark, String step, String label) {
  return Row(
    children: [
      Container(
        width: 24,
        height: 24,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.primary,
        ),
        child: Center(
          child: Text(
            step,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.white),
          ),
        ),
      ),
      const SizedBox(width: 10),
      Text(
        label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
    ],
  );
}
