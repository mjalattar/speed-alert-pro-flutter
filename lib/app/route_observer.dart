import 'package:flutter/material.dart';

/// Used so [HomeScreen] can drop the GoogleMap platform view while another route
/// (e.g. Settings) is on top — Android platform views often composite above Flutter UI.
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();
