import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/servers_screen.dart';
import 'state/session_controller.dart';
import 'state/settings_store.dart';
import 'state/texture_store.dart';
import 'widgets/mc_ui.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsStore()..load()),
        ChangeNotifierProvider(create: (_) => SessionController()),
        ChangeNotifierProvider(create: (_) => TextureStore()..load()),
      ],
      child: const McpeClientApp(),
    ),
  );
}

class McpeClientApp extends StatelessWidget {
  const McpeClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF4CAF50);
    return MaterialApp(
      title: 'MCPE 1.1.5 Client',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      builder: (context, child) => McDirtBackground(pack: context.watch<TextureStore>().pack, child: child!),
      home: const ServersScreen(),
    );
  }
}
