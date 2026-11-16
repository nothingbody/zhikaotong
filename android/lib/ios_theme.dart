import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const iosBlue = Color(0xFF505CA4);
const iosInk = Color(0xFF132B42);
const iosSecondary = Color(0xFF6C6D76);
const iosBackground = Color(0xFFFAF7F1);
const iosLine = Color(0xFFE9E3D9);
const iosAmber = Color(0xFFD89D48);
const iosTint = Color(0xFFF0EFF8);
const iosWarmTint = Color(0xFFF3E8D6);
const iosGreen = Color(0xFF248A3D);
const iosRed = Color(0xFFCC2F26);

const iosSystemOverlay = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
  systemNavigationBarColor: iosBackground,
  systemNavigationBarDividerColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.dark,
  systemNavigationBarContrastEnforced: false,
);

/// Density follows the usable viewport; long content still scrolls naturally.
class IOSLayout {
  final bool compact;
  final double horizontalPadding;
  final double sectionGap;
  final double cardPadding;
  final double headingSize;
  final int gridColumns;

  const IOSLayout._({
    required this.compact,
    required this.horizontalPadding,
    required this.sectionGap,
    required this.cardPadding,
    required this.headingSize,
    required this.gridColumns,
  });

  static IOSLayout of(BuildContext context, {Size? availableSize}) {
    final media = MediaQuery.of(context);
    final width =
        availableSize?.width ?? media.size.width - media.padding.horizontal;
    final height =
        availableSize?.height ??
        media.size.height - media.padding.vertical - media.viewInsets.bottom;
    // Body constraints already exclude Scaffold chrome. Other callers use the
    // safe window breakpoint, without assuming a fixed system navigation size.
    final compact = width < 360 || height < (availableSize == null ? 780 : 680);
    final horizontal = width >= 600
        ? 24.0
        : compact
        ? 16.0
        : 20.0;
    final largeText = media.textScaler.scale(14) > 19.6;
    final minTileWidth = largeText
        ? 180.0
        : compact
        ? 130.0
        : 146.0;
    final columns = ((width - horizontal * 2 + 10) / (minTileWidth + 10))
        .floor()
        .clamp(1, 4);
    return IOSLayout._(
      compact: compact,
      horizontalPadding: horizontal,
      sectionGap: compact ? 12 : 16,
      cardPadding: compact ? 14 : 18,
      headingSize: compact ? 24 : 28,
      gridColumns: columns,
    );
  }

  EdgeInsets get contentPadding => EdgeInsets.fromLTRB(
    horizontalPadding,
    compact ? 8 : 12,
    horizontalPadding,
    compact ? 16 : 24,
  );
}

TextStyle iosEditorialStyle({
  double fontSize = 28,
  Color color = iosInk,
  FontWeight fontWeight = FontWeight.w600,
  double height = 1.3,
}) => TextStyle(
  fontFamily: 'NotoSerifSC',
  fontSize: fontSize,
  fontWeight: fontWeight,
  fontVariations: [FontVariation('wght', fontWeight.value.toDouble())],
  color: color,
  height: height,
  letterSpacing: -.4,
);

ThemeData iosTheme() => ThemeData(
  useMaterial3: true,
  fontFamily: 'Roboto',
  platform: TargetPlatform.iOS,
  brightness: Brightness.light,
  scaffoldBackgroundColor: iosBackground,
  primaryColor: iosBlue,
  colorScheme: const ColorScheme.light(
    primary: iosBlue,
    onPrimary: Colors.white,
    secondary: iosBlue,
    surface: Colors.white,
    onSurface: iosInk,
    error: iosRed,
    outline: Color(0xFFC7C7CC),
  ),
  cupertinoOverrideTheme: const CupertinoThemeData(
    brightness: Brightness.light,
    primaryColor: iosBlue,
    scaffoldBackgroundColor: iosBackground,
    barBackgroundColor: iosBackground,
  ),
  textTheme: ThemeData.light().textTheme.copyWith(
    displaySmall: iosEditorialStyle(fontSize: 32),
    headlineMedium: iosEditorialStyle(),
    titleLarge: const TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w700,
      letterSpacing: -.4,
      color: iosInk,
    ),
    titleMedium: const TextStyle(
      fontSize: 17,
      fontWeight: FontWeight.w600,
      color: iosInk,
    ),
    bodyLarge: const TextStyle(fontSize: 17, height: 1.5, color: iosInk),
    bodyMedium: const TextStyle(fontSize: 15, height: 1.5, color: iosInk),
    bodySmall: const TextStyle(fontSize: 13, height: 1.4, color: iosSecondary),
    labelLarge: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
  ),
  appBarTheme: const AppBarTheme(
    centerTitle: true,
    toolbarHeight: 52,
    backgroundColor: iosBackground,
    foregroundColor: iosBlue,
    titleTextStyle: TextStyle(
      fontFamily: 'Roboto',
      fontSize: 17,
      fontWeight: FontWeight.w600,
      color: iosInk,
    ),
    elevation: 0,
    scrolledUnderElevation: 0,
    surfaceTintColor: Colors.transparent,
    systemOverlayStyle: iosSystemOverlay,
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: const Color(0xFFF4F1EB),
    labelStyle: const TextStyle(
      fontFamily: 'Roboto',
      color: iosSecondary,
      fontSize: 15,
    ),
    floatingLabelStyle: const TextStyle(fontFamily: 'Roboto', color: iosBlue),
    hintStyle: const TextStyle(
      fontFamily: 'Roboto',
      color: Color(0xFF8E8E93),
      fontSize: 15,
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: iosBlue, width: 1.2),
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      backgroundColor: iosBlue,
      foregroundColor: Colors.white,
      minimumSize: const Size(44, 50),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      textStyle: const TextStyle(
        fontFamily: 'Roboto',
        fontSize: 17,
        fontWeight: FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      foregroundColor: iosBlue,
      minimumSize: const Size(44, 48),
      backgroundColor: Colors.white,
      side: const BorderSide(color: iosLine),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
    ),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(
      foregroundColor: iosBlue,
      minimumSize: const Size(44, 44),
      textStyle: const TextStyle(
        fontFamily: 'Roboto',
        fontSize: 15,
        fontWeight: FontWeight.w500,
      ),
    ),
  ),
  iconButtonTheme: IconButtonThemeData(
    style: IconButton.styleFrom(
      foregroundColor: iosBlue,
      minimumSize: const Size(44, 44),
    ),
  ),
  chipTheme: ChipThemeData(
    backgroundColor: const Color(0xFFF2EDE5),
    selectedColor: iosTint,
    side: BorderSide.none,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    labelStyle: const TextStyle(
      fontFamily: 'Roboto',
      fontSize: 13,
      color: iosSecondary,
    ),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
  ),
  bottomSheetTheme: const BottomSheetThemeData(
    backgroundColor: iosBackground,
    surfaceTintColor: Colors.transparent,
    dragHandleColor: Color(0xFFC7C7CC),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
  ),
  dialogTheme: DialogThemeData(
    backgroundColor: const Color(0xFFFFFDFA),
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    titleTextStyle: const TextStyle(
      fontFamily: 'Roboto',
      color: iosInk,
      fontSize: 20,
      fontWeight: FontWeight.w600,
    ),
  ),
  listTileTheme: const ListTileThemeData(
    iconColor: iosBlue,
    textColor: iosInk,
    minVerticalPadding: 12,
    contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 2),
    titleTextStyle: TextStyle(
      fontFamily: 'Roboto',
      fontSize: 16,
      color: iosInk,
    ),
    subtitleTextStyle: TextStyle(
      fontFamily: 'Roboto',
      fontSize: 13,
      height: 1.4,
      color: iosSecondary,
    ),
  ),
  dividerTheme: const DividerThemeData(color: iosLine, thickness: .5, space: 1),
  progressIndicatorTheme: const ProgressIndicatorThemeData(
    color: iosBlue,
    linearTrackColor: iosLine,
  ),
  switchTheme: SwitchThemeData(
    thumbColor: WidgetStateProperty.resolveWith((states) => Colors.white),
    trackColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.selected) ? iosBlue : iosLine,
    ),
    trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
  ),
  snackBarTheme: SnackBarThemeData(
    backgroundColor: iosInk,
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
  ),
  pageTransitionsTheme: const PageTransitionsTheme(
    builders: {
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    },
  ),
);

class IOSGlass extends StatelessWidget {
  final Widget child;
  const IOSGlass({super.key, required this.child});
  @override
  Widget build(BuildContext context) => RepaintBoundary(
    // Fixed app chrome keeps its warm surface without sampling scrolling
    // content behind it. Keep clipping and all caller-owned safe-area padding.
    child: ClipRect(
      child: ColoredBox(color: iosBackground, child: child),
    ),
  );
}

class IOSGroupedSurface extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;
  final Color color;
  const IOSGroupedSurface({
    super.key,
    required this.child,
    this.margin,
    this.padding,
    this.color = Colors.white,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding:
        margin ?? EdgeInsets.only(bottom: IOSLayout.of(context).sectionGap),
    child: Material(
      color: color,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding ?? EdgeInsets.all(IOSLayout.of(context).cardPadding),
        child: child,
      ),
    ),
  );
}

class IOSSectionLabel extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const IOSSectionLabel(this.title, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      2,
      IOSLayout.of(context).compact ? 6 : 10,
      2,
      IOSLayout.of(context).compact ? 8 : 10,
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: iosEditorialStyle(
              fontSize: IOSLayout.of(context).compact ? 20 : 23,
            ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    ),
  );
}

class IOSIconTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  const IOSIconTile(
    this.icon, {
    super.key,
    this.color = iosBlue,
    this.size = 38,
  });
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color.withValues(alpha: .11),
      borderRadius: BorderRadius.circular(size * .27),
    ),
    child: Icon(icon, color: color, size: size * .55),
  );
}
