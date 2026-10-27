import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'screens/login_screen.dart';
import 'services/google_health_auth.dart';
import 'screens/home_screen.dart';
import 'theme/app_theme.dart';
import 'widgets/run_widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppThemeController.instance.load();
  runApp(const RunAggregatorApp());
}

class RunAggregatorApp extends StatefulWidget {
  const RunAggregatorApp({super.key});

  @override
  State<RunAggregatorApp> createState() => _RunAggregatorAppState();
}

class _RunAggregatorAppState extends State<RunAggregatorApp> {
  final _theme = AppThemeController.instance;

  @override
  void initState() {
    super.initState();
    _theme.addListener(_onTheme);
  }

  @override
  void dispose() {
    _theme.removeListener(_onTheme);
    super.dispose();
  }

  void _onTheme() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Run Aggregator',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _theme.mode,
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const _AuthGate(),
    );
  }
}

class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: GoogleHealthAuth.isLoggedIn(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: LoadingState(message: 'Anmeldung wird geprüft'),
          );
        }
        if (snapshot.data == true) {
          return const HomeScreen();
        }
        return const LoginScreen();
      },
    );
  }
}
