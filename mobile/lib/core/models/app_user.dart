import 'branch.dart';
import 'user_role.dart';

/// A member of staff — a named person, not just a role.
///
/// Roles decide what someone may do; the user is who actually did it. The
/// distinction is the whole point of an audit trail: "a Cashier released
/// ₱26,100" cannot be followed up, "Grace Ramos released ₱26,100" can.
class AppUser {
  final String id;
  final String name;
  final AppUserRole role;

  /// The branch this person works from. Null for staff who oversee both,
  /// which in this shop means Admin.
  final BranchId? homeBranch;

  final String? contactNumber;

  /// False once someone has left. They can no longer be picked to act as, but
  /// stay on file so every record they made still names them.
  final bool active;

  const AppUser({
    required this.id,
    required this.name,
    required this.role,
    this.homeBranch,
    this.contactNumber,
    this.active = true,
  });

  String get firstName => name.split(' ').first;

  /// Two-letter initials for avatars and compact attribution.
  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }

  /// "Grace Ramos (Cashier)" — how a person is named on a record.
  String get attribution => '$name (${role.label})';

  AppUser copyWith({
    String? name,
    AppUserRole? role,
    BranchId? homeBranch,
    bool clearHomeBranch = false,
    String? contactNumber,
    bool clearContactNumber = false,
    bool? active,
  }) {
    return AppUser(
      id: id,
      name: name ?? this.name,
      role: role ?? this.role,
      homeBranch: clearHomeBranch ? null : (homeBranch ?? this.homeBranch),
      contactNumber: clearContactNumber ? null : (contactNumber ?? this.contactNumber),
      active: active ?? this.active,
    );
  }
}
