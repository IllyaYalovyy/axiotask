import 'package:axiotask/src/app/desktop_workspace.dart';
import 'package:axiotask/src/domain/model/preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'standard geometry clamps both panes and preserves a useful collection',
    () {
      final layout = DesktopWorkspaceLayout.resolve(
        availableWidth: 1024,
        textScale: 1,
        density: DensityPreference.standard,
        hasDetail: true,
        preferences: const DesktopWorkspacePreferences(
          navigationWidth: 999,
          detailWidth: 999,
        ),
      );

      expect(
        layout.navigationWidth,
        DesktopWorkspaceLayout.standardNavigationMax,
      );
      expect(
        layout.detailWidth,
        lessThan(DesktopWorkspaceLayout.standardDetailMax),
      );
      expect(
        layout.collectionWidth,
        greaterThanOrEqualTo(DesktopWorkspaceLayout.minimumCollectionWidth),
      );
    },
  );

  test(
    'compact defaults, text scale, and empty details retain useful space',
    () {
      final compact = DesktopWorkspaceLayout.resolve(
        availableWidth: 1355,
        textScale: 1,
        density: DensityPreference.compact,
        hasDetail: true,
        preferences: const DesktopWorkspacePreferences.defaults(),
      );
      final scaled = DesktopWorkspaceLayout.resolve(
        availableWidth: 1024,
        textScale: 2,
        density: DensityPreference.standard,
        hasDetail: true,
        preferences: const DesktopWorkspacePreferences.defaults(),
      );
      final empty = DesktopWorkspaceLayout.resolve(
        availableWidth: 1024,
        textScale: 1,
        density: DensityPreference.standard,
        hasDetail: false,
        preferences: const DesktopWorkspacePreferences.defaults(),
      );

      expect(
        compact.navigationWidth,
        DesktopWorkspaceLayout.compactNavigationPreferred,
      );
      expect(
        compact.detailWidth,
        DesktopWorkspaceLayout.compactDetailPreferred,
      );
      expect(scaled.collectionWidth, greaterThanOrEqualTo(400));
      expect(empty.hasDetail, isFalse);
      expect(empty.detailWidth, 0);
      expect(empty.collectionWidth, greaterThan(scaled.collectionWidth));
    },
  );

  test('drag and keyboard adjustments clamp in both directions', () {
    const preferences = DesktopWorkspacePreferences.defaults();

    expect(
      DesktopWorkspaceLayout.adjustNavigation(
        preferences: preferences,
        delta: -1000,
        density: DensityPreference.standard,
      ).navigationWidth,
      DesktopWorkspaceLayout.standardNavigationMin,
    );
    expect(
      DesktopWorkspaceLayout.adjustNavigation(
        preferences: preferences,
        delta: 1000,
        density: DensityPreference.standard,
      ).navigationWidth,
      DesktopWorkspaceLayout.standardNavigationMax,
    );
    expect(
      DesktopWorkspaceLayout.adjustDetail(
        preferences: preferences,
        delta: -1000,
        density: DensityPreference.compact,
      ).detailWidth,
      DesktopWorkspaceLayout.compactDetailMin,
    );
    expect(
      DesktopWorkspaceLayout.adjustDetail(
        preferences: preferences,
        delta: 1000,
        density: DensityPreference.compact,
      ).detailWidth,
      DesktopWorkspaceLayout.compactDetailMax,
    );
  });
}
