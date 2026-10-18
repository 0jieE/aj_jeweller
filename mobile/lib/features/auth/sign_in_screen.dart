import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_config.dart';
import '../../core/models/app_user.dart';
import '../../core/state/session_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';

/// Signing in: pick yourself from the shop's staff, then type your PIN.
///
/// This replaces the old person picker in the app bar. Picking a name no
/// longer makes you that person — the PIN does, and the server decides.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  late Future<List<AppUser>> _staff;
  AppUser? _picked;
  String _pin = '';
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _staff = context.read<SessionState>().staff();
  }

  void _reload() {
    setState(() {
      _error = null;
      _staff = context.read<SessionState>().staff();
    });
  }

  Future<void> _submit() async {
    final user = _picked;
    if (user == null || _pin.length < 4 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<SessionState>().signIn(userId: user.id, pin: _pin);
    } on ApiRefusal catch (error) {
      setState(() {
        _error = error.message;
        _pin = '';
      });
    } on ApiUnauthorized {
      setState(() {
        _error = 'That PIN is not right.';
        _pin = '';
      });
    } on ApiUnavailable catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primaryBlue,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: _picked == null ? _staffList() : _pinPad(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _staffList() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The shop's own mark, not a name in a font: staff recognise it
        // across a counter, and it says this is the right app before anyone
        // reads a word.
        Center(
          child: ClipOval(
            child: Image.asset('assets/icon/icon.png', width: 84, height: 84, fit: BoxFit.cover),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text('AJ Jeweler', textAlign: TextAlign.center, style: AppTextStyles.headlineLarge.copyWith(color: Colors.white)),
        const SizedBox(height: 2),
        Text(
          'Who is at the counter?',
          textAlign: TextAlign.center,
          style: AppTextStyles.bodyMedium.copyWith(color: Colors.white70),
        ),
        const SizedBox(height: AppSpacing.lg),
        Flexible(
          child: FutureBuilder<List<AppUser>>(
            future: _staff,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(AppSpacing.xl),
                  child: _WakingServer(),
                );
              }
              if (snapshot.hasError) return _cannotReach(snapshot.error!);
              final staff = snapshot.data ?? const <AppUser>[];
              if (staff.isEmpty) return _cannotReach('No staff have been set up on the server yet.');
              return Material(
                color: AppColors.cardSurface,
                borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
                clipBehavior: Clip.antiAlias,
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: staff.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final user = staff[i];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: AppColors.primaryBlue.withValues(alpha: 0.12),
                        child: Text(
                          user.initials,
                          style: AppTextStyles.labelSmall.copyWith(
                            color: AppColors.primaryBlue,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      title: Text(user.name, style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        '${user.role.label}${user.homeBranch == null ? ' · Both branches' : ' · ${user.homeBranch!.label}'}',
                        style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
                      ),
                      onTap: () => setState(() {
                        _picked = user;
                        _pin = '';
                        _error = null;
                      }),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _cannotReach(Object error) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded, size: 32, color: AppColors.textSecondary),
          const SizedBox(height: AppSpacing.sm),
          Text('Cannot reach the server', style: AppTextStyles.titleMedium),
          const SizedBox(height: 4),
          Text(
            "The shop's staff list comes from the server, so signing in needs a "
            "connection. Check the Wi-Fi, then try again.",
            textAlign: TextAlign.center,
            style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            ApiConfig.baseUrl,
            textAlign: TextAlign.center,
            style: AppTextStyles.caption.copyWith(color: AppColors.textDisabled),
          ),
          // The raw reason, for whoever is setting the phone up.
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            shape: const Border(),
            collapsedShape: const Border(),
            title: Text(
              'Details',
              style: AppTextStyles.caption.copyWith(color: AppColors.textDisabled),
            ),
            children: [
              Text(
                '$error',
                textAlign: TextAlign.center,
                style: AppTextStyles.caption.copyWith(color: AppColors.textDisabled),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          FilledButton.icon(
            onPressed: _reload,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }

  Widget _pinPad() {
    final user = _picked!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: 28,
          backgroundColor: Colors.white24,
          child: Text(
            user.initials,
            style: AppTextStyles.titleLarge.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(user.name, style: AppTextStyles.titleLarge.copyWith(color: Colors.white)),
        Text(user.role.label, style: AppTextStyles.bodyMedium.copyWith(color: Colors.white70)),
        const SizedBox(height: AppSpacing.lg),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < (_pin.length < 4 ? 4 : _pin.length); i++)
              Container(
                width: 14,
                height: 14,
                margin: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < _pin.length ? Colors.white : Colors.white24,
                ),
              ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: AppTextStyles.bodyMedium.copyWith(color: Colors.amberAccent),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        _Keypad(
          busy: _busy,
          onDigit: (digit) {
            if (_pin.length >= 6) return;
            setState(() => _pin += digit);
            // Sent with the arrow, not at a fixed length: a PIN may be
            // four digits or six, and guessing wrong would spend one of the
            // five tries before a lockout.
          },
          onBackspace: () {
            if (_pin.isEmpty) return;
            setState(() => _pin = _pin.substring(0, _pin.length - 1));
          },
          onSubmit: _submit,
        ),
        const SizedBox(height: AppSpacing.sm),
        TextButton(
          onPressed: _busy ? null : () => setState(() {
            _picked = null;
            _pin = '';
            _error = null;
          }),
          child: const Text('Someone else', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}

class _Keypad extends StatelessWidget {
  final bool busy;
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final VoidCallback onSubmit;

  const _Keypad({
    required this.busy,
    required this.onDigit,
    required this.onBackspace,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    Widget key(String label, {VoidCallback? onTap, IconData? icon}) {
      return Padding(
        padding: const EdgeInsets.all(6),
        child: SizedBox(
          width: 72,
          height: 58,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.16),
              foregroundColor: Colors.white,
            ),
            onPressed: busy ? null : (onTap ?? () => onDigit(label)),
            child: icon == null
                ? Text(label, style: AppTextStyles.titleLarge.copyWith(color: Colors.white))
                : Icon(icon),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (final d in row) key(d)]),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            key('', onTap: onBackspace, icon: Icons.backspace_outlined),
            key('0'),
            key('', onTap: onSubmit, icon: busy ? Icons.hourglass_top_rounded : Icons.arrow_forward_rounded),
          ],
        ),
      ],
    );
  }
}

/// Waiting for the staff list. A server that has been idle takes a while to
/// wake, and silence for that long reads as broken — so after a few seconds
/// it says what it is waiting for.
class _WakingServer extends StatefulWidget {
  const _WakingServer();

  @override
  State<_WakingServer> createState() => _WakingServerState();
}

class _WakingServerState extends State<_WakingServer> {
  bool _slow = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(color: Colors.white),
        if (_slow) ...[
          const SizedBox(height: AppSpacing.md),
          Text(
            "Waking the shop's server. The first time each day this can take "
            'up to a minute.',
            textAlign: TextAlign.center,
            style: AppTextStyles.bodyMedium.copyWith(color: Colors.white70),
          ),
        ],
      ],
    );
  }
}
