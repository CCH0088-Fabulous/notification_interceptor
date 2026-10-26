/// 跨语言调用失败时抛出的统一异常，UI 只处理这一种类型。
class InterceptorException implements Exception {
  const InterceptorException(this.code, this.message);

  final String code;
  final String message;

  bool get isPermissionDenied => code == 'PERMISSION_DENIED';
  bool get isServiceDisconnected => code == 'SERVICE_NOT_CONNECTED';

  @override
  String toString() => 'InterceptorException($code): $message';
}
