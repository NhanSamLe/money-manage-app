import 'package:material_ui/material_ui.dart';

/// Maps the server-side icon keys of system categories to Material icons.
IconData categoryIcon(String? key) {
  switch (key) {
    case 'restaurant':
      return Icons.restaurant_rounded;
    case 'directions_car':
      return Icons.directions_car_rounded;
    case 'home':
      return Icons.home_rounded;
    case 'receipt_long':
      return Icons.receipt_long_rounded;
    case 'shopping_bag':
      return Icons.shopping_bag_rounded;
    case 'sports_esports':
      return Icons.sports_esports_rounded;
    case 'favorite':
      return Icons.favorite_rounded;
    case 'school':
      return Icons.school_rounded;
    case 'payments':
      return Icons.payments_rounded;
    case 'redeem':
      return Icons.redeem_rounded;
    case 'savings':
      return Icons.savings_rounded;
    case 'add_card':
      return Icons.add_card_rounded;
    default:
      return Icons.more_horiz_rounded;
  }
}

IconData accountIcon(String kind) {
  switch (kind) {
    case 'BANK':
      return Icons.account_balance_rounded;
    case 'WALLET':
      return Icons.account_balance_wallet_rounded;
    case 'CASH':
      return Icons.payments_rounded;
    case 'SAVINGS':
      return Icons.savings_rounded;
    case 'CREDIT_CARD':
      return Icons.credit_card_rounded;
    default:
      return Icons.wallet_rounded;
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
