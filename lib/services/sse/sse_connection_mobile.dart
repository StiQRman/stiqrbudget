import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'sse_connection_interface.dart';

class SseConnectionMobile implements SseConnectionInterface {
  http.Client? _client;
  StreamSubscription? _streamSubscription;
  StreamController<SseRawMessage>? _controller;
  bool _isClosed = false;

  @override
  Stream<SseRawMessage> connect(Uri uri) {
    _isClosed = false;
    _controller = StreamController<SseRawMessage>.broadcast(
      onCancel: () {
        close();
      },
    );

    _client = http.Client();
    _connectInternal(uri);

    return _controller!.stream;
  }

  Future<void> _connectInternal(Uri uri) async {
    try {
      final request = http.Request('GET', uri);
      request.headers['Accept'] = 'text/event-stream';
      request.headers['Cache-Control'] = 'no-cache';

      final response = await _client!.send(request);
      if (response.statusCode != 200) {
        if (!_isClosed && _controller != null && !_controller!.isClosed) {
          _controller!.addError(
            'SSE HTTP connection failed with status: ${response.statusCode}',
          );
        }
        return;
      }

      String? currentEvent;
      String? currentId;
      final currentData = <String>[];

      _streamSubscription = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) {
            if (currentEvent != null || currentData.isNotEmpty) {
              final eventName = currentEvent ?? 'message';
              final fullData = currentData.join('\n');
              if (!_isClosed && _controller != null && !_controller!.isClosed) {
                _controller!.add(SseRawMessage(
                  event: eventName,
                  data: fullData,
                  id: currentId,
                ));
              }
              currentEvent = null;
              currentId = null;
              currentData.clear();
            }
            return;
          }

          if (trimmed.startsWith(':')) {
            return;
          }

          if (trimmed.startsWith('id:')) {
            currentId = trimmed.substring(3).trim();
          } else if (trimmed.startsWith('event:')) {
            currentEvent = trimmed.substring(6).trim();
          } else if (trimmed.startsWith('data:')) {
            currentData.add(trimmed.substring(5).trim());
          }
        },
        onError: (err) {
          if (!_isClosed && _controller != null && !_controller!.isClosed) {
            _controller!.addError(err);
          }
        },
        onDone: () {
          if (!_isClosed && _controller != null && !_controller!.isClosed) {
            _controller!.close();
          }
        },
        cancelOnError: false,
      );
    } catch (e) {
      if (!_isClosed && _controller != null && !_controller!.isClosed) {
        _controller!.addError(e);
      }
    }
  }

  @override
  void subscribeTopic(String topic) {}

  @override
  void close() {
    _isClosed = true;
    _streamSubscription?.cancel();
    _streamSubscription = null;
    _client?.close();
    _client = null;
    if (_controller != null && !_controller!.isClosed) {
      _controller!.close();
    }
  }
}

SseConnectionInterface createSseConnection() => SseConnectionMobile();
