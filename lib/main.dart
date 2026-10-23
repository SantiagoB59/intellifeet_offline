import 'package:flutter/material.dart';

import 'features/autenticacion/login_page.dart';

void main() {
  runApp(const IntelliFeetApp());
}

class IntelliFeetApp extends StatelessWidget {
  const IntelliFeetApp({super.key});

  @override
  Widget build(BuildContext context) {
    const navy = Color(0xFF101B33);
    const gold = Color(0xFFE0B323);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'IntelliFeet',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: navy,
          primary: navy,
          secondary: gold,
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F6FA),
        appBarTheme: const AppBarTheme(
          backgroundColor: navy,
          foregroundColor: Colors.white,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      home: const LoginPage(),
    );
  }
}
