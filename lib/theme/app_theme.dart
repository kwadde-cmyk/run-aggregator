import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Spacing, radii, and the width where the app switches to a navigation rail.
class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double radius = 16;
  static const double radiusSm = 12;
  static const double wideBreakpoint = 840;
  static const double contentMaxWidth = 880;
}

/// Start and finish markers stay recognizable in both themes.
class AppColors {
  static const Color start = Color(0xFF1E8E3E);
  static const Color finish = Color(0xFFD93025);
}

/// Chart series chosen for separation on both light and dark surfaces.
class AppChartColors extends ThemeExtension<AppChartColors> {
  const AppChartColors({
    required this.pace,
    required this.heartRate,
    required this.series,
  });

  final Color pace;
  final Color heartRate;
  final List<Color> series;

  static const dark = AppChartColors(
    pace: Color(0xFF8AB4F8),
    heartRate: Color(0xFFF28B82),
    series: [
      Color(0xFF8AB4F8),
      Color(0xFFF28B82),
      Color(0xFF81C995),
      Color(0xFFFDD663),
      Color(0xFFC58AF9),
      Color(0xFF78D9EC),
      Color(0xFFFFB4A2),
      Color(0xFFB7E1CD),
    ],
  );

  static const light = AppChartColors(
    pace: Color(0xFF1A73E8),
    heartRate: Color(0xFFD93025),
    series: [
      Color(0xFF1A73E8),
      Color(0xFFD93025),
      Color(0xFF188038),
      Color(0xFFE37400),
      Color(0xFF9334E6),
      Color(0xFF007B83),
      Color(0xFFC5221F),
      Color(0xFF0D904F),
    ],
  );

  @override
  AppChartColors copyWith({
    Color? pace,
    Color? heartRate,
    List<Color>? series,
  }) {
    return AppChartColors(
      pace: pace ?? this.pace,
      heartRate: heartRate ?? this.heartRate,
      series: series ?? this.series,
    );
  }

  @override
  AppChartColors lerp(ThemeExtension<AppChartColors>? other, double t) {
    if (other is! AppChartColors) return this;
    return AppChartColors(
      pace: Color.lerp(pace, other.pace, t)!,
      heartRate: Color.lerp(heartRate, other.heartRate, t)!,
      series: [
        for (var i = 0; i < series.length; i++)
          Color.lerp(series[i], other.series[i], t)!,
      ],
    );
  }
}

class AppTheme {
  static const Color seed = Color(0xFF0B57D0);

  static ThemeData light() => _build(Brightness.light, AppChartColors.light, 0);

  static ThemeData dark() => _build(Brightness.dark, AppChartColors.dark, 0.5);

  static ThemeData _build(Brightness brightness, AppChartColors charts, double contrastLevel) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      contrastLevel: contrastLevel,
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: scheme.surface,
    );
    final text = base.textTheme.apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
    );
    final fieldBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      borderSide: BorderSide(color: scheme.outlineVariant),
    );

    return base.copyWith(
      textTheme: text,
      primaryTextTheme: base.primaryTextTheme.apply(
        bodyColor: scheme.onPrimary,
        displayColor: scheme.onPrimary,
      ),
      extensions: [charts],
      appBarTheme: AppBarThemeData(
        centerTitle: false,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 2,
        titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainer,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radius),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.secondaryContainer,
        height: 72,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return text.labelMedium?.copyWith(
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.secondaryContainer,
        selectedIconTheme: IconThemeData(color: scheme.onSecondaryContainer),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 48),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
          shape: shape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 48),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
          shape: shape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
          shape: shape,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        extendedTextStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: fieldBorder,
        enabledBorder: fieldBorder,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        side: BorderSide(color: scheme.outlineVariant),
        selectedColor: scheme.secondaryContainer,
        labelStyle: text.labelLarge,
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          textStyle: WidgetStatePropertyAll(text.labelLarge),
          visualDensity: VisualDensity.standard,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(color: scheme.onInverseSurface),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1, thickness: 1),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        shape: shape,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
    );
  }
}

/// Remembers dark / light / system. Dark is the default.
class AppThemeController extends ChangeNotifier {
  AppThemeController._();

  static final AppThemeController instance = AppThemeController._();
  static const _key = 'theme_mode';

  ThemeMode mode = ThemeMode.dark;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      mode = _decode(prefs.getString(_key));
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setMode(ThemeMode value) async {
    mode = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, _encode(value));
    } catch (_) {}
  }

  static ThemeMode _decode(String? stored) {
    return switch (stored) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
  }

  static String _encode(ThemeMode value) {
    return switch (value) {
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
      ThemeMode.dark => 'dark',
    };
  }
}
