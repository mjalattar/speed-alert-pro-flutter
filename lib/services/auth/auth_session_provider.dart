import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final authSessionProvider = StreamProvider<Session?>((ref) {
  final client = Supabase.instance.client;

  final currentSession = client.auth.currentSession;
  debugPrint('[AUTH] authSessionProvider created, currentSession=${currentSession != null ? 'uid=${currentSession.user.id}' : 'null'}');

  final controller = StreamController<Session?>.broadcast();

  if (currentSession != null) {
    controller.add(currentSession);
  }

  final subscription = client.auth.onAuthStateChange.listen((data) {
    final event = data.event;
    final session = data.session;
    debugPrint('[AUTH] onAuthStateChange: event=$event, session=${session != null ? 'uid=${session.user.id}' : 'null'}');
    if (event == AuthChangeEvent.initialSession || 
        event == AuthChangeEvent.signedIn || 
        event == AuthChangeEvent.tokenRefreshed) {
      if (!controller.isClosed) controller.add(session);
    } else if (event == AuthChangeEvent.signedOut) {
      if (!controller.isClosed) controller.add(null);
    }
  });

  ref.onDispose(() {
    subscription.cancel();
    controller.close();
  });

  return controller.stream;
});