import 'sse_connection_interface.dart';
import 'sse_connection_mobile.dart' if (dart.library.html) 'sse_connection_web.dart';

export 'sse_connection_interface.dart';

SseConnectionInterface getPlatformSseConnection() => createSseConnection();
