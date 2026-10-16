import 'package:chantipoint/src/auth/authorized_user.dart';

const testEmployee = AuthorizedUser(
  profileId: 'profile-employee',
  companyId: 'company-jmservice',
  displayName: 'Marie Tremblay',
  email: 'marie@example.test',
  roles: {AuthorizedRole.employee},
);

const testAdministrator = AuthorizedUser(
  profileId: 'profile-admin',
  companyId: 'company-jmservice',
  displayName: 'Jamel Admin',
  email: 'jamel@example.test',
  roles: {AuthorizedRole.employee, AuthorizedRole.administrator},
);
