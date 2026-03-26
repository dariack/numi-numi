import 'package:flutter/material.dart';
import '../services/firestore_service.dart';

class PatternsScreen extends StatelessWidget {
  final FirestoreService service;
  const PatternsScreen({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('📊', style: TextStyle(fontSize: 48)),
              const SizedBox(height: 12),
              const Text('Patterns & Analytics', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('View detailed charts at:', style: TextStyle(color: Colors.grey.shade500)),
              const SizedBox(height: 4),
              Text('yuli-tracker.web.app/stats.html',
                style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              Text('In-app charts coming soon!', style: TextStyle(color: Colors.grey.shade500)),
            ],
          ),
        ),
      ),
    );
  }
}
