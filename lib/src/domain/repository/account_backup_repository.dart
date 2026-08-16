import '../backup/account_backup.dart';
import '../model/tasks.dart';

abstract interface class AccountBackupRepository {
  Future<AccountBackupSnapshot> readProjectedAccount(AccountId accountId);
}
