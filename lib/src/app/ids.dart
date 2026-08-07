// Local id generation for rows created before their first push — the port of
// `uuid::Uuid::new_v4()` used throughout the reference's state/command layer.
//
// A locally-created list or task gets a v4 UUID as its id; the sync engine
// remaps it to Google's id on the first successful create push. Kept behind a
// single helper so every call site is consistent and can be overridden by tests
// (bootstrap and the command layer take an injectable `String Function()`).

import 'package:uuid/uuid.dart';

const Uuid _uuid = Uuid();

/// A fresh random (v4) local id.
String newLocalId() => _uuid.v4();
