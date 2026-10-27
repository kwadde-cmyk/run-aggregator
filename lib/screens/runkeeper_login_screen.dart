import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../services/runkeeper_service.dart';
import '../theme/app_theme.dart';

class RunkeeperLoginScreen extends StatefulWidget {
  const RunkeeperLoginScreen({super.key});

  @override
  State<RunkeeperLoginScreen> createState() => _RunkeeperLoginScreenState();
}

class _RunkeeperLoginScreenState extends State<RunkeeperLoginScreen> {
  InAppWebViewController? _controller;
  bool _done = false;

  Future<void> _captureCookies() async {
    if (_done || _controller == null) return;
    final cookies = await CookieManager.instance().getCookies(
      url: WebUri('https://runkeeper.com'),
    );
    if (cookies.isNotEmpty) {
      await RunkeeperService.saveCookies(cookies);
      _done = true;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Runkeeper-Login gespeichert')),
        );
        Navigator.of(context).pop(true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Runkeeper'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.md),
            child: FilledButton(
              onPressed: _captureCookies,
              child: const Text('Fertig'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Material(
            color: scheme.surfaceContainerHigh,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: scheme.primary),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      'Nach dem Login auf Fertig tippen. Die Sitzung wird gespeichert.',
                      style: text.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri('https://runkeeper.com/login'),
              ),
              onWebViewCreated: (c) => _controller = c,
              onLoadStop: (controller, url) async {
                // Auto-capture once we reach a logged-in page
                if (url != null && !url.toString().contains('/login')) {
                  await Future.delayed(const Duration(seconds: 1));
                  await _captureCookies();
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}
