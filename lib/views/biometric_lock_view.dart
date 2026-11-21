import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';

class StickerLogo extends StatelessWidget {
  final double size;

  const StickerLogo({super.key, this.size = 120});

  @override
  Widget build(BuildContext context) {
    final foldSize = size * 0.25;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          // Base Sticker
          Positioned.fill(
            child: ClipPath(
              clipper: _StickerClipper(foldSize),
              child: Container(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  border: Border.all(
                    color: const Color(0xFF334155),
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Center(
                  child: Text(
                    '\$',
                    style: GoogleFonts.outfit(
                      fontSize: size * 0.52,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF06B6D4), // Blue/Cyan $ sign
                    ),
                  ),
                ),
              ),
            ),
          ),
          
          // Peeled Corner (Folded part)
          Positioned(
            bottom: 0,
            right: 0,
            child: CustomPaint(
              size: Size(foldSize, foldSize),
              painter: _CornerFoldPainter(),
            ),
          ),
        ],
      ),
    );
  }
}

class _StickerClipper extends CustomClipper<Path> {
  final double foldSize;
  _StickerClipper(this.foldSize);

  @override
  Path getClip(Size size) {
    final path = Path();
    final r = 24.0; // corner radius
    path.moveTo(r, 0);
    path.lineTo(size.width - r, 0);
    path.quadraticBezierTo(size.width, 0, size.width, r);
    path.lineTo(size.width, size.height - foldSize);
    path.lineTo(size.width - foldSize, size.height);
    path.lineTo(r, size.height);
    path.quadraticBezierTo(0, size.height, 0, size.height - r);
    path.lineTo(0, r);
    path.quadraticBezierTo(0, 0, r, 0);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class _CornerFoldPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Background fold shadow
    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    final shadowPath = Path();
    shadowPath.moveTo(-2, size.height + 2);
    shadowPath.lineTo(size.width + 2, -2);
    shadowPath.lineTo(-2, -2);
    shadowPath.close();
    canvas.drawPath(shadowPath, shadowPaint);

    // Peeled corner fold
    final paint = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF94A3B8), Color(0xFFF1F5F9)],
        begin: Alignment.bottomLeft,
        end: Alignment.topRight,
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.fill;

    final path = Path();
    path.moveTo(0, size.height);
    path.lineTo(size.width, 0);
    path.lineTo(0, 0);
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class BiometricLockView extends ConsumerStatefulWidget {
  const BiometricLockView({super.key});

  @override
  ConsumerState<BiometricLockView> createState() => _BiometricLockViewState();
}

class _BiometricLockViewState extends ConsumerState<BiometricLockView> {
  @override
  void initState() {
    super.initState();
    // Auto-prompt on launch after screen is rendered
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(settingsProvider.notifier).authenticate();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Spacer(),
                const StickerLogo(size: 130),
                const SizedBox(height: 32),
                Text(
                  'StiqrBudget Locked',
                  style: GoogleFonts.outfit(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Verify identity using fingerprint or biometric lock to unlock the application.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: const Color(0xFF94A3B8),
                  ),
                ),
                const Spacer(),
                
                // Fingerprint Tap Target
                InkWell(
                  onTap: () {
                    ref.read(settingsProvider.notifier).authenticate();
                  },
                  borderRadius: BorderRadius.circular(40),
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0xFF06B6D4).withOpacity(0.08),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFF06B6D4).withOpacity(0.25),
                        width: 1.5,
                      ),
                    ),
                    child: const Icon(
                      Icons.fingerprint,
                      color: Color(0xFF06B6D4),
                      size: 44,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Tap to scan',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: const Color(0xFF06B6D4),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                
                // Use password fallback
                TextButton(
                  onPressed: () {
                    ref.read(authProvider.notifier).logout();
                  },
                  child: Text(
                    'Use Password Log In',
                    style: GoogleFonts.inter(
                      color: const Color(0xFF94A3B8),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
