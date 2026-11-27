import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/moma_theme.dart';

/// Keeps the owner's profile photo on this device only (never uploaded).
///
/// The picked photo is already downscaled by the picker (max 512 px, JPEG quality 85, roughly 30-80 KB), so it
/// is kept as base64 in the Keystore-backed secure storage. `path_provider` is not a direct dependency of the
/// app, so there is no documents directory to write a file into without adding one.
class AvatarStore {
  AvatarStore([FlutterSecureStorage? storage])
    : _s = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  static const _key = 'owner_avatar_v1';

  Future<Uint8List?> load() async {
    final raw = await _s.read(key: _key);
    if (raw == null || raw.isEmpty) return null;
    try {
      return base64Decode(raw);
    } on FormatException {
      return null;
    }
  }

  Future<void> save(Uint8List bytes) =>
      _s.write(key: _key, value: base64Encode(bytes));

  Future<void> clear() => _s.delete(key: _key);
}

final avatarStoreProvider = Provider<AvatarStore>((_) => AvatarStore());

/// The owner's photo bytes, or null when none is set (callers then show initials).
class AvatarNotifier extends AsyncNotifier<Uint8List?> {
  @override
  Future<Uint8List?> build() => ref.read(avatarStoreProvider).load();

  /// Opens the camera or gallery; returns false when the person cancelled.
  Future<bool> pick(ImageSource source) async {
    final file = await ImagePicker().pickImage(
      source: source,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 85,
      preferredCameraDevice: CameraDevice.front,
    );
    if (file == null) return false;
    await set(await file.readAsBytes());
    return true;
  }

  Future<void> set(Uint8List bytes) async {
    await ref.read(avatarStoreProvider).save(bytes);
    state = AsyncData(bytes);
  }

  Future<void> remove() async {
    await ref.read(avatarStoreProvider).clear();
    state = const AsyncData(null);
  }
}

final avatarProvider = AsyncNotifierProvider<AvatarNotifier, Uint8List?>(
  AvatarNotifier.new,
);

/// Circular owner avatar: the saved photo, otherwise a person silhouette on a soft brand-tinted circle.
/// Deliberately no letter/initial avatars (owner decision).
class OwnerAvatar extends ConsumerWidget {
  const OwnerAvatar({super.key, this.size = 40, this.borderColor});
  final double size;
  final Color? borderColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photo = ref.watch(avatarProvider).value;
    final border = borderColor == null
        ? null
        : Border.all(color: borderColor!, width: size >= 64 ? 3 : 2);
    if (photo != null) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: border,
          image: DecorationImage(image: MemoryImage(photo), fit: BoxFit.cover),
        ),
      );
    }
    return Container(
      key: const ValueKey('avatar-placeholder'),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: border,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFEAF7EC), MomaColors.mint],
        ),
      ),
      child: ClipOval(
        // Head and shoulders: the icon sits low so the shoulders are cut by the circle edge.
        child: Transform.translate(
          offset: Offset(0, size * 0.12),
          child: Icon(
            Symbols.person_rounded,
            fill: 1,
            size: size * 0.86,
            color: MomaColors.emerald,
          ),
        ),
      ),
    );
  }
}
