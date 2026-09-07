import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/api_exception.dart';

/// 로그인 / 회원가입.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();

  bool _isRegistering = false;
  bool _obscurePassword = true;
  bool _submitting = false;
  String? _errorMessage;
  Map<String, String> _fieldErrors = const {};

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _submitting = true;
      _errorMessage = null;
      _fieldErrors = const {};
    });

    final auth = ref.read(authStateProvider.notifier);

    try {
      if (_isRegistering) {
        await auth.register(
          email: _emailController.text.trim(),
          password: _passwordController.text,
          displayName: _nameController.text.trim(),
        );
      } else {
        await auth.login(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
      }
      // 성공하면 라우터가 알아서 메인으로 보낸다.
    } on ApiException catch (error) {
      setState(() {
        _errorMessage = error.message;
        _fieldErrors = error.fieldErrors;
      });
      // 서버가 필드별 오류를 줬으면 폼에 반영한다.
      _formKey.currentState?.validate();
    } on Object catch (error) {
      setState(() => _errorMessage = '$error');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _Branding(),
                    const SizedBox(height: 40),

                    if (_errorMessage != null) ...[
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.error_outline_rounded,
                              color: theme.colorScheme.onErrorContainer,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: TextStyle(
                                  color: theme.colorScheme.onErrorContainer,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],

                    if (_isRegistering) ...[
                      TextFormField(
                        controller: _nameController,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.name],
                        decoration: InputDecoration(
                          labelText: '이름',
                          hintText: '앱에서 사용할 이름',
                          prefixIcon: const Icon(Icons.person_outline_rounded),
                          errorText: _fieldErrors['display_name'],
                        ),
                        validator: (value) =>
                            (value == null || value.trim().isEmpty)
                                ? '이름을 입력해 주세요.'
                                : null,
                      ),
                      const SizedBox(height: 16),
                    ],

                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.email],
                      decoration: InputDecoration(
                        labelText: '이메일',
                        prefixIcon: const Icon(Icons.mail_outline_rounded),
                        errorText: _fieldErrors['email'],
                      ),
                      validator: (value) {
                        final email = value?.trim() ?? '';
                        if (email.isEmpty) return '이메일을 입력해 주세요.';
                        if (!email.contains('@') || !email.contains('.')) {
                          return '올바른 이메일 형식이 아닙니다.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      autofillHints: [
                        if (_isRegistering)
                          AutofillHints.newPassword
                        else
                          AutofillHints.password,
                      ],
                      decoration: InputDecoration(
                        labelText: '비밀번호',
                        prefixIcon: const Icon(Icons.lock_outline_rounded),
                        errorText: _fieldErrors['password'],
                        helperText: _isRegistering ? '10자 이상' : null,
                        suffixIcon: IconButton(
                          onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword,
                          ),
                          tooltip: _obscurePassword ? '비밀번호 보기' : '비밀번호 숨기기',
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      validator: (value) {
                        final password = value ?? '';
                        if (password.isEmpty) return '비밀번호를 입력해 주세요.';
                        if (_isRegistering && password.length < 10) {
                          return '비밀번호는 10자 이상이어야 합니다.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 28),

                    FilledButton(
                      onPressed: _submitting ? null : _submit,
                      child: _submitting
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.5),
                            )
                          : Text(_isRegistering ? '가입하고 시작하기' : '로그인'),
                    ),
                    const SizedBox(height: 12),

                    TextButton(
                      onPressed: _submitting
                          ? null
                          : () => setState(() {
                                _isRegistering = !_isRegistering;
                                _errorMessage = null;
                                _fieldErrors = const {};
                              }),
                      child: Text(
                        _isRegistering
                            ? '이미 계정이 있어요 · 로그인'
                            : '처음이신가요? · 회원가입',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Branding extends StatelessWidget {
  const _Branding();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(26),
          ),
          child: Icon(
            Icons.hearing_rounded,
            size: 46,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'HearO',
          style: theme.textTheme.displaySmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '감정이 담긴 실시간 자막으로\n일상의 소통을 돕습니다',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}
