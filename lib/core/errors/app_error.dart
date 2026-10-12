class AppError implements Exception {
  final String message;
  final String? code;

  const AppError(this.message, {this.code});

  @override
  String toString() => 'AppError: $message (code: $code)';
}

class DatabaseError extends AppError {
  const DatabaseError(super.message, {super.code});
}

class PermissionDeniedError extends AppError {
  const PermissionDeniedError(super.message) : super(code: 'PERMISSION_DENIED');
}

class RollNotFoundError extends AppError {
  const RollNotFoundError(super.message) : super(code: 'ROLL_NOT_FOUND');
}
