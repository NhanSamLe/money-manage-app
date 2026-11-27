/// Home-screen widgets: data sync, settings page and the native entry points (quick-entry sheet, background
/// refresh). Importing this barrel from the app also keeps the entry points in the AOT build.
library;

export 'entrypoints.dart' show quickEntryMain, widgetRefreshMain;
export 'widget_settings_page.dart' show openWidgetSettings, WidgetSettingsPage;
export 'widget_sync.dart' show WidgetSync;
