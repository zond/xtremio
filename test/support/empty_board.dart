import 'package:xtremio/core/core.dart';

import 'fake_core_client.dart';

/// A `board` that is loaded but plans no catalogs, so Discover's rows
/// render their static empty state (a still-loading board spins forever,
/// which `pumpAndSettle` cannot wait out). A fresh map on every call.
Map<String, dynamic> emptyBoard() => {
  'selected': {'type': null, 'extra': <Object>[]},
  'catalogs': <Object>[],
  'catalogLabels': <Object>[],
};

/// A core with nothing in it but [emptyBoard].
FakeCoreClient emptyBoardCore() =>
    FakeCoreClient(state: {CoreField.board: emptyBoard()});
