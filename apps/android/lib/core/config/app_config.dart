/// Public configuration only. The Supabase publishable key is designed to be embedded in clients.
/// No secret/service-role key may ever be placed in this app.
///
/// Values can be overridden at build time, e.g. for a staging backend:
/// `flutter build apk --dart-define=MOMA_API_BASE=https://staging.example/v1`
class AppConfig {
  const AppConfig._();
  static const supabaseUrl = String.fromEnvironment(
    'MOMA_SUPABASE_URL',
    defaultValue: 'https://dedjaugwvhipnxbwxaav.supabase.co',
  );
  static const supabasePublishableKey = String.fromEnvironment(
    'MOMA_SUPABASE_KEY',
    defaultValue: 'sb_publishable_RamavXHPtMcVAwC6PswQWQ_wZPBdXol',
  );
  static const defaultApiBase = String.fromEnvironment(
    'MOMA_API_BASE',
    defaultValue: 'https://moma-api.superaicore.indevs.in/v1',
  );
}
