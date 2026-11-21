import 'dart:async';

class SseRawMessage {
  final String event;
  final String data;
  final String? id;

  const SseRawMessage({
    required this.event,
    required this.data,
    this.id,
  });
}

abstract class SseConnectionInterface {
  Stream<SseRawMessage> connect(Uri uri);
  void subscribeTopic(String topic);
  void close();
}
