import 'package:material_ui/material_ui.dart';
import 'package:material_symbols_icons/symbols.dart';

/// Maps the server-side icon keys of system categories to Material icons.
IconData categoryIcon(String? key) {
  switch (key) {
    case 'restaurant':
      return Symbols.restaurant_rounded;
    case 'directions_car':
      return Symbols.directions_car_rounded;
    case 'home':
      return Symbols.home_rounded;
    case 'receipt_long':
      return Symbols.receipt_long_rounded;
    case 'shopping_bag':
      return Symbols.shopping_bag_rounded;
    case 'sports_esports':
      return Symbols.sports_esports_rounded;
    case 'favorite':
      return Symbols.favorite_rounded;
    case 'school':
      return Symbols.school_rounded;
    case 'payments':
      return Symbols.payments_rounded;
    case 'redeem':
      return Symbols.redeem_rounded;
    case 'savings':
      return Symbols.savings_rounded;
    case 'add_card':
      return Symbols.add_card_rounded;
    default:
      return Symbols.more_horiz_rounded;
  }
}

IconData accountIcon(String kind) {
  switch (kind) {
    case 'BANK':
      return Symbols.account_balance_rounded;
    case 'WALLET':
      return Symbols.account_balance_wallet_rounded;
    case 'CASH':
      return Symbols.payments_rounded;
    case 'SAVINGS':
      return Symbols.savings_rounded;
    case 'CREDIT_CARD':
      return Symbols.credit_card_rounded;
    default:
      return Symbols.wallet_rounded;
  }
}

String accountKindLabel(String kind) {
  switch (kind) {
    case 'BANK':
      return 'Ngân hàng';
    case 'WALLET':
      return 'Ví điện tử';
    case 'CASH':
      return 'Tiền mặt';
    case 'SAVINGS':
      return 'Tiết kiệm';
    case 'CREDIT_CARD':
      return 'Thẻ tín dụng';
    default:
      return 'Khác';
  }
}
