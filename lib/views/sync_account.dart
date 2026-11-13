import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/form/form.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/sync.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/views/cloud/cloud_data.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SyncAccountView extends ConsumerWidget {
  const SyncAccountView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(syncProvider);
    final appLocalizations = context.appLocalizations;
    return Scaffold(
      title: appLocalizations.syncAndAccount,
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 20 + context.bottomInset,
        ),
        children: [
          if (state.session == null)
            const _SignInForm()
          else
            ..._accountSections(context, ref, state),
        ],
      ),
    );
  }

  List<Widget> _accountSections(
    BuildContext context,
    WidgetRef ref,
    SyncState state,
  ) {
    final appLocalizations = context.appLocalizations;
    final session = state.session!;
    final action = ref.read(syncProvider.notifier);
    return [
      if (state.error != null)
        ErrorBanner(message: _failureText(appLocalizations, state.error!)),
      generateSection(
        title: appLocalizations.cloudData,
        items: [
          for (final kind in const ['profile', 'rule', 'script'])
            ListItem.open(
              leading: GlyphIcon(cloudKindGlyph(kind)),
              title: Text(cloudKindLabel(appLocalizations, kind)),
              widget: CloudDataView(kind: kind),
            ),
        ],
      ),
      generateSection(
        items: [
          FormRow(
            title: appLocalizations.syncDevice,
            trailing: Text(
              session.deviceName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          FormRow(
            title: appLocalizations.syncLastUpload,
            trailing: Text(
              session.lastUploadAt == null
                  ? appLocalizations.syncNever
                  : _formatTime(session.lastUploadAt!),
            ),
          ),
        ],
      ),
      generateSection(
        items: [
          FormRow(
            leading: const GlyphIcon(AppGlyphs.account),
            title: appLocalizations.syncSignOut,
            titleStyle: TextStyle(color: context.colorScheme.error),
            onPressed: state.busy ? null : () => action.signOut(),
          ),
        ],
      ),
    ];
  }
}

class _SignInForm extends ConsumerStatefulWidget {
  const _SignInForm();

  @override
  ConsumerState<_SignInForm> createState() => _SignInFormState();
}

class _SignInFormState extends ConsumerState<_SignInForm> {
  final _serverController = TextEditingController();
  final _accountController = TextEditingController();
  final _passwordController = TextEditingController();
  String? _issue;

  @override
  void dispose() {
    _serverController.dispose();
    _accountController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    final appLocalizations = context.appLocalizations;
    final server = _serverController.text.trim();
    final account = _accountController.text.trim();
    final password = _passwordController.text;
    final issue = server.isEmpty
        ? appLocalizations.emptyTip(appLocalizations.syncServer)
        : account.isEmpty
        ? appLocalizations.emptyTip(appLocalizations.account)
        : password.isEmpty
        ? appLocalizations.emptyTip(appLocalizations.password)
        : null;
    if (issue != null) {
      setState(() => _issue = issue);
      return;
    }
    setState(() => _issue = null);
    unawaited(
      ref
          .read(syncProvider.notifier)
          .signIn(baseUrl: server, username: account, password: password),
    );
  }

  Future<void> _test() async {
    final server = _serverController.text.trim();
    final appLocalizations = context.appLocalizations;
    if (server.isEmpty) {
      setState(
        () => _issue = appLocalizations.emptyTip(appLocalizations.syncServer),
      );
      return;
    }
    final reachable = await ref
        .read(syncProvider.notifier)
        .testConnection(server);
    if (!mounted) return;
    unawaited(
      dialogs.showAlert(
        title: appLocalizations.syncTestConnection,
        message: TextSpan(
          text: reachable
              ? appLocalizations.syncReachable
              : appLocalizations.syncUnreachable,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final state = ref.watch(syncProvider);
    final busy = state.busy;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            appLocalizations.syncOptional,
            style: AppTextStyle.caption1.of(context).toLighter,
          ),
        ),
        ErrorBanner(
          message:
              _issue ??
              (state.error == null
                  ? null
                  : _failureText(appLocalizations, state.error!)),
        ),
        generateSection(
          items: [
            FormRow(
              title: appLocalizations.syncServer,
              invalid:
                  _issue ==
                  appLocalizations.emptyTip(appLocalizations.syncServer),
              trailing: FormRowTextField(
                controller: _serverController,
                hintText: 'https://sync.example.com',
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                inputFormatters: TextInputLimits.limit(TextInputLimits.uri),
              ),
            ),
            FormRow(
              title: appLocalizations.account,
              trailing: FormRowTextField(
                controller: _accountController,
                hintText: appLocalizations.required,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                inputFormatters: TextInputLimits.limit(
                  TextInputLimits.userName,
                ),
              ),
            ),
            FormRow(
              title: appLocalizations.password,
              trailing: FormRowSecretTextField(
                controller: _passwordController,
                hintText: appLocalizations.required,
                textInputAction: TextInputAction.done,
                inputFormatters: TextInputLimits.limit(
                  TextInputLimits.password,
                ),
                onFieldSubmitted: (_) => _submit(),
              ),
            ),
          ],
        ),
        generateSection(
          items: [
            FormRow(
              leading: const GlyphIcon(AppGlyphs.connections),
              title: appLocalizations.syncTestConnection,
              onPressed: busy ? null : _test,
            ),
            FormRow(
              leading: const GlyphIcon(AppGlyphs.cloudSync),
              title: appLocalizations.syncSignIn,
              onPressed: busy ? null : _submit,
            ),
          ],
        ),
      ],
    );
  }
}

String _failureText(AppLocalizations appLocalizations, String failure) {
  return switch (failure) {
    'offline' => appLocalizations.syncOffline,
    'unauthorized' || 'invalidCredentials' => appLocalizations.syncSignIn,
    _ => appLocalizations.error,
  };
}

String _formatTime(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}
