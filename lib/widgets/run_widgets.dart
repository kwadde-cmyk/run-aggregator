import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class RunStat extends StatelessWidget {
  const RunStat({
    super.key,
    required this.value,
    required this.label,
    this.unit,
    this.expand = true,
  });

  final String value;
  final String label;
  final String? unit;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(
              text: value,
              style: text.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: -0.4,
                height: 1.05,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              children: [
                if (unit != null && unit!.isNotEmpty)
                  TextSpan(
                    text: ' $unit',
                    style: text.titleSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
    if (!expand) return column;
    return Expanded(child: column);
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.title,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
  });

  final String? title;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title!,
                      style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (trailing != null) trailing!,
                ],
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

class LoadingState extends StatelessWidget {
  const LoadingState({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: AppSpacing.lg),
          Text(
            message,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: scheme.primary),
            const SizedBox(height: AppSpacing.lg),
            Text(title, style: text.titleMedium, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                message!,
                style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AppSpacing.xl),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: scheme.error),
            const SizedBox(height: AppSpacing.lg),
            Text('Etwas ist schiefgelaufen', style: text.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.sm),
            Text(
              message,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Nochmal versuchen'),
            ),
          ],
        ),
      ),
    );
  }
}

class ThemeModeButton extends StatelessWidget {
  const ThemeModeButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppThemeController.instance,
      builder: (context, _) {
        final mode = AppThemeController.instance.mode;
        final icon = switch (mode) {
          ThemeMode.light => Icons.light_mode_outlined,
          ThemeMode.system => Icons.brightness_auto_outlined,
          ThemeMode.dark => Icons.dark_mode_outlined,
        };
        return PopupMenuButton<ThemeMode>(
          tooltip: 'Darstellung',
          icon: Icon(icon),
          onSelected: AppThemeController.instance.setMode,
          itemBuilder: (context) => const [
            PopupMenuItem(value: ThemeMode.dark, child: Text('Dunkel')),
            PopupMenuItem(value: ThemeMode.light, child: Text('Hell')),
            PopupMenuItem(value: ThemeMode.system, child: Text('System')),
          ],
        );
      },
    );
  }
}

/// Warmup/cooldown and pace-unit controls shared by detail and compare.
class EffortControls extends StatelessWidget {
  const EffortControls({
    super.key,
    required this.trimAuto,
    required this.trimManual,
    required this.trimByKm,
    required this.showKmh,
    required this.startController,
    required this.endController,
    required this.onModeChanged,
    required this.onTrimByKm,
    required this.onShowKmh,
    required this.onManualEdit,
  });

  final bool trimAuto;
  final bool trimManual;
  final bool trimByKm;
  final bool showKmh;
  final TextEditingController startController;
  final TextEditingController endController;
  final ValueChanged<String> onModeChanged;
  final ValueChanged<bool> onTrimByKm;
  final ValueChanged<bool> onShowKmh;
  final ValueChanged<String> onManualEdit;

  @override
  Widget build(BuildContext context) {
    final mode = trimAuto ? 'auto' : (trimManual ? 'manual' : 'off');
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Warmup / Cooldown',
          style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Blendet Ein- und Auslaufen aus den Kurven aus.',
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'off', label: Text('Aus')),
                ButtonSegment(value: 'auto', label: Text('Auto')),
                ButtonSegment(value: 'manual', label: Text('Manuell')),
              ],
              selected: {mode},
              onSelectionChanged: (selection) => onModeChanged(selection.first),
            ),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('min/km')),
                ButtonSegment(value: true, label: Text('km/h')),
              ],
              selected: {showKmh},
              onSelectionChanged: (selection) => onShowKmh(selection.first),
            ),
          ],
        ),
        if (trimManual) ...[
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('Zeit')),
                  ButtonSegment(value: true, label: Text('km')),
                ],
                selected: {trimByKm},
                onSelectionChanged: (selection) => onTrimByKm(selection.first),
              ),
              SizedBox(
                width: 108,
                child: TextField(
                  controller: startController,
                  decoration: InputDecoration(
                    labelText: 'Start',
                    isDense: true,
                    suffixText: trimByKm ? 'km' : 'min',
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: onManualEdit,
                ),
              ),
              SizedBox(
                width: 108,
                child: TextField(
                  controller: endController,
                  decoration: InputDecoration(
                    labelText: 'Ende',
                    isDense: true,
                    suffixText: trimByKm ? 'km' : 'min',
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: onManualEdit,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
