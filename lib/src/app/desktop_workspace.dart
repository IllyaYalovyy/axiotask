import '../domain/model/preferences.dart';

/// Presentation-only geometry for the Fedora three-pane workspace.
final class DesktopWorkspaceLayout {
  const DesktopWorkspaceLayout._({
    required this.navigationWidth,
    required this.detailWidth,
    required this.collectionWidth,
    required this.hasDetail,
  });

  static const double splitterWidth = 12;
  static const double minimumCollectionWidth = 320;
  static const double standardNavigationMin = 180;
  static const double standardNavigationPreferred = 244;
  static const double standardNavigationMax = 360;
  static const double standardDetailMin = 240;
  static const double standardDetailPreferred = 360;
  static const double standardDetailMax = 480;
  static const double compactNavigationMin = 160;
  static const double compactNavigationPreferred = 220;
  static const double compactNavigationMax = 320;
  static const double compactDetailMin = 224;
  static const double compactDetailPreferred = 320;
  static const double compactDetailMax = 440;

  final double navigationWidth;
  final double detailWidth;
  final double collectionWidth;
  final bool hasDetail;

  static DesktopWorkspaceLayout resolve({
    required double availableWidth,
    required double textScale,
    required DensityPreference density,
    required bool hasDetail,
    required DesktopWorkspacePreferences preferences,
  }) {
    final limits = _limits(density);
    final preferredNavigation =
        preferences.navigationWidth ==
            const DesktopWorkspacePreferences.defaults().navigationWidth
        ? limits.navigationPreferred
        : preferences.navigationWidth;
    final navigation = preferredNavigation
        .clamp(limits.navigationMin, limits.navigationMax)
        .toDouble();
    if (!hasDetail) {
      return DesktopWorkspaceLayout._(
        navigationWidth: navigation,
        detailWidth: 0,
        collectionWidth: (availableWidth - navigation - splitterWidth)
            .clamp(0, double.infinity)
            .toDouble(),
        hasDetail: false,
      );
    }
    final minimumCollection = (minimumCollectionWidth * textScale)
        .clamp(minimumCollectionWidth, 400)
        .toDouble();
    final availableDetail =
        availableWidth - navigation - splitterWidth * 2 - minimumCollection;
    final preferredDetail =
        preferences.detailWidth ==
            const DesktopWorkspacePreferences.defaults().detailWidth
        ? limits.detailPreferred
        : preferences.detailWidth;
    final detail = preferredDetail
        .clamp(limits.detailMin, limits.detailMax)
        .clamp(0, availableDetail)
        .toDouble();
    return DesktopWorkspaceLayout._(
      navigationWidth: navigation,
      detailWidth: detail,
      collectionWidth:
          (availableWidth - navigation - detail - splitterWidth * 2)
              .clamp(0, double.infinity)
              .toDouble(),
      hasDetail: true,
    );
  }

  static DesktopWorkspacePreferences adjustNavigation({
    required DesktopWorkspacePreferences preferences,
    required double delta,
    required DensityPreference density,
  }) {
    final limits = _limits(density);
    return preferences.copyWith(
      navigationWidth: (preferences.navigationWidth + delta)
          .clamp(limits.navigationMin, limits.navigationMax)
          .toDouble(),
    );
  }

  static DesktopWorkspacePreferences adjustDetail({
    required DesktopWorkspacePreferences preferences,
    required double delta,
    required DensityPreference density,
  }) {
    final limits = _limits(density);
    return preferences.copyWith(
      detailWidth: (preferences.detailWidth + delta)
          .clamp(limits.detailMin, limits.detailMax)
          .toDouble(),
    );
  }

  static _WorkspaceLimits _limits(DensityPreference density) =>
      switch (density) {
        DensityPreference.standard => const _WorkspaceLimits(
          navigationMin: standardNavigationMin,
          navigationPreferred: standardNavigationPreferred,
          navigationMax: standardNavigationMax,
          detailMin: standardDetailMin,
          detailPreferred: standardDetailPreferred,
          detailMax: standardDetailMax,
        ),
        DensityPreference.compact => const _WorkspaceLimits(
          navigationMin: compactNavigationMin,
          navigationPreferred: compactNavigationPreferred,
          navigationMax: compactNavigationMax,
          detailMin: compactDetailMin,
          detailPreferred: compactDetailPreferred,
          detailMax: compactDetailMax,
        ),
      };
}

final class _WorkspaceLimits {
  const _WorkspaceLimits({
    required this.navigationMin,
    required this.navigationPreferred,
    required this.navigationMax,
    required this.detailMin,
    required this.detailPreferred,
    required this.detailMax,
  });

  final double navigationMin;
  final double navigationPreferred;
  final double navigationMax;
  final double detailMin;
  final double detailPreferred;
  final double detailMax;
}
