/// A platform connectivity observation, not proof of Google reachability.
enum ConnectivityHint { unknown, provenNoRoute, mayHaveReturned }

abstract interface class ConnectivityPort {
  ConnectivityHint get currentHint;

  Stream<ConnectivityHint> get hints;
}
