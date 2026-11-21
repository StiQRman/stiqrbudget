import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'pb_provider.dart';

class AuthState {
  final bool isAuthenticated;
  final String? email;
  final String? error;
  final bool isLoading;

  AuthState({
    this.isAuthenticated = false,
    this.email,
    this.error,
    this.isLoading = false,
  });

  AuthState copyWith({
    bool? isAuthenticated,
    String? email,
    String? error,
    bool? isLoading,
  }) {
    return AuthState(
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      email: email ?? this.email,
      error: error, // Pass null to clear error
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class AuthNotifier extends StateNotifier<AuthState> {
  final Ref _ref;

  AuthNotifier(this._ref) : super(AuthState()) {
    _checkInitialAuth();
  }

  void _checkInitialAuth() {
    final pbService = _ref.read(pbServiceProvider);
    if (pbService.isAuthenticated) {
      state = AuthState(
        isAuthenticated: true,
        email: pbService.currentUserEmail,
      );
    }
  }

  Future<bool> login(String email, String password) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final pbService = _ref.read(pbServiceProvider);
      await pbService.login(email, password);
      state = AuthState(
        isAuthenticated: true,
        email: pbService.currentUserEmail,
      );
      return true;
    } catch (e) {
      String errorMsg = e.toString().replaceFirst('Exception: ', '');
      if (errorMsg.contains('Failed to authenticate')) {
        errorMsg = 'Invalid email or password.';
      }
      state = state.copyWith(isLoading: false, error: errorMsg);
      return false;
    }
  }

  Future<bool> signUp(String email, String password) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final pbService = _ref.read(pbServiceProvider);
      await pbService.signUp(email, password);
      state = AuthState(
        isAuthenticated: true,
        email: pbService.currentUserEmail,
      );
      return true;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString().replaceFirst('Exception: ', ''),
      );
      return false;
    }
  }

  void logout() {
    final pbService = _ref.read(pbServiceProvider);
    pbService.logout();
    state = AuthState();
  }

  Future<void> deleteAccount() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final pbService = _ref.read(pbServiceProvider);
      await pbService.deleteAccount();
    } finally {
      state = AuthState();
    }
  }

  void clearError() {
    state = state.copyWith(error: null);
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(ref);
});
