import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/komnivo_theme.dart';

class CommunityLogo extends StatefulWidget {
  const CommunityLogo({
    super.key,
    required this.name,
    this.imagePath,
    this.size = 52,
  });

  final String name;
  final String? imagePath;
  final double size;

  @override
  State<CommunityLogo> createState() => _CommunityLogoState();
}

class _CommunityLogoState extends State<CommunityLogo> {
  Future<String>? _signedUrl;

  @override
  void initState() {
    super.initState();
    _prepareUrl();
  }

  @override
  void didUpdateWidget(covariant CommunityLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imagePath != widget.imagePath) _prepareUrl();
  }

  void _prepareUrl() {
    final path = widget.imagePath?.trim() ?? '';
    if (path.isEmpty) {
      _signedUrl = null;
      return;
    }

    final uri = Uri.tryParse(path);
    if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
      _signedUrl = Future<String>.value(path);
      return;
    }

    // community-media is private. Storage RLS only signs logos for a public
    // community or for a user who belongs to that community.
    _signedUrl = Supabase.instance.client.storage
        .from('community-media')
        .createSignedUrl(path, 3600);
  }

  Widget _fallback() {
    final initial = widget.name.trim().isEmpty
        ? 'K'
        : widget.name.trim().characters.first.toUpperCase();
    return Container(
      width: widget.size,
      height: widget.size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: KomnivoTheme.surfaceRaised,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            KomnivoTheme.accent.withValues(alpha: .23),
            KomnivoTheme.cyan.withValues(alpha: .13),
            KomnivoTheme.surfaceRaised,
          ],
        ),
        borderRadius: BorderRadius.circular(widget.size * .27),
        border: Border.all(color: KomnivoTheme.accent.withValues(alpha: .45)),
      ),
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: widget.size * .42,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  Widget _image(String url) {
    return Container(
      width: widget.size,
      height: widget.size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: KomnivoTheme.surfaceRaised,
        borderRadius: BorderRadius.circular(widget.size * .27),
        border: Border.all(color: KomnivoTheme.line),
      ),
      child: Image.network(
        url,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _fallback(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_signedUrl == null) return _fallback();
    return FutureBuilder<String>(
      future: _signedUrl,
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data!.isNotEmpty) {
          return _image(snapshot.data!);
        }
        if (snapshot.hasError) return _fallback();
        return Container(
          width: widget.size,
          height: widget.size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: KomnivoTheme.surfaceRaised,
            borderRadius: BorderRadius.circular(widget.size * .27),
            border: Border.all(color: KomnivoTheme.line),
          ),
          child: SizedBox(
            width: widget.size * .28,
            height: widget.size * .28,
            child: const CircularProgressIndicator(strokeWidth: 1.8),
          ),
        );
      },
    );
  }
}

String communityLogoMimeType(String extension) {
  switch (extension.toLowerCase()) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'webp':
      return 'image/webp';
    default:
      throw ArgumentError.value(extension, 'extension', 'Unsupported community logo type.');
  }
}
