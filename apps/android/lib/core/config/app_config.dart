/// Public configuration only. The Supabase publishable key is designed to be embedded in clients.
/// No secret/service-role key may ever be placed in this app.
class AppConfig {
  const AppConfig._();
  static const supabaseUrl = 'https://dedjaugwvhipnxbwxaav.supabase.co';
  static const supabasePublishableKey =
      'sb_publishable_RamavXHPtMcVAwC6PswQWQ_wZPBdXol';
  static const defaultApiBase = 'https://moma-api.superaicore.indevs.in/v1';
}
