import 'package:flutter/material.dart';

/// Small animated level meter that gives the user visible confirmation the
/// microphone is actually picking up their voice while recording a speech
/// profile. Shared by the onboarding and Settings speech profile pages so
/// both flows show the same feedback.
class MicLevelIndicator extends StatelessWidget {
  final double level;

  const MicLevelIndicator({super.key, required this.level});

  static const _barWeights = [0.5, 0.8, 1.0, 0.8, 0.5];

  @override
  Widget build(BuildContext context) {
    final clamped = level.clamp(0.0, 1.0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final weight in _barWeights)
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            width: 4,
            height: 6 + (clamped * weight * 26),
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.3 + clamped * 0.7),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
      ],
    );
  }
}
