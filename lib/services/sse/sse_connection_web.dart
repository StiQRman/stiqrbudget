// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;
import 'sse_connection_interface.dart';

class SseConnectionWeb implements SseConnectionInterface {
  html.EventSource? _eventSource;
  StreamController<SseRawMessage>? _controller;
  final Set<String> _registeredTopics = {};
  final Set<String> _boundTopics = {};
  bool _isClosed = false;

  @override
  Stream<SseRawMessage> connect(Uri uri) {
    _isClosed = false;
    _boundTopics.clear();
    _controller = StreamController<SseRawMessage>.broadcast(
      onCancel: () {
        close();
      },
    );

    final es = html.EventSource(uri.toString());
    _eventSource = es;

    es.onMessage.listen((html.MessageEvent e) {
      if (!_isClosed && _controller != null && !_controller!.isClosed && e.data != null) {
        _controller!.add(SseRawMessage(
          event: 'message',
          data: e.data.toString(),
          id: e.lastEventId,
        ));
      }
    });

    es.addEventListener('PB_CONNECT', (html.Event e) {
      final msg = e as html.MessageEvent;
      if (!_isClosed && _controller != null && !_controller!.isClosed && msg.data != null) {
        _controller!.add(SseRawMessage(
          event: 'PB_CONNECT',
          data: msg.data.toString(),
          id: msg.lastEventId,
        ));
      }
    });

    // Attach listeners for all topics already registered prior to connect()
    for (final topic in _registeredTopics) {
      _bindTopicToEventSource(topic);
    }

    es.onError.listen((_) {});

    return _controller!.stream;
  }

  void _bindTopicToEventSource(String cleanTopic) {
    if (_eventSource == null || _boundTopics.contains(cleanTopic)) return;
    _boundTopics.add(cleanTopic);

    _eventSource!.addEventListener(cleanTopic, (html.Event e) {
      final msg = e as html.MessageEvent;
      if (!_isClosed && _controller != null && !_controller!.isClosed && msg.data != null) {
        _controller!.add(SseRawMessage(
          event: cleanTopic,
          data: msg.data.toString(),
          id: msg.lastEventId,
        ));
      }
    });
  }

  @override
  void subscribeTopic(String topic) {
    final cleanTopic = topic.trim();
    if (cleanTopic.isEmpty) return;
    _registeredTopics.add(cleanTopic);
    _bindTopicToEventSource(cleanTopic);
  }

  @override
  void close() {
    _isClosed = true;
    _boundTopics.clear();
    _eventSource?.close();
    _eventSource = null;
    if (_controller != null && !_controller!.isClosed) {
      _controller!.close();
    }
  }
}

SseConnectionInterface createSseConnection() => SseConnectionWeb();
